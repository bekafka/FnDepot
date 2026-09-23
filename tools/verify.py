#!/usr/bin/env python3
"""发布前校验 FnDepot 索引：结构自检 + 外链 size 并行核对 + README 表与索引一致性。

替代以前手敲的那段「jq + while read curl」：那版是串行 curl，17 个包要 60s+；这里并发 HEAD，几秒完成。

检查项：
  1. JSON 可解析；schema_version / source_info 必填
  2. 每个应用的必填字段、取值域（run_as / install_type / platform / 固定分类 / is_docker 布尔）
  3. icon_url 必须是 assets/icons/fnapp.png 且文件存在
  4. 每个包：download_url 是带 tag 的 GitHub release 地址（**不许 latest/download**）、sha256 64 位十六进制、
     size 为正整数、包键名（架构）与 platform 自洽
  5. README 收录表里的**键名与版本**必须与索引一致（键名写错=客户端装不上，曾把 ignis 写成 obsidian）
  6. 外链的 Content-Length 必须等于索引里的 size（--no-net 可跳过）

用法:
  python3 tools/verify.py [--no-net] [--jobs 8]
退出码: 0 全部通过 | 1 有结构/一致性问题 | 2 有外链查询失败
"""

import argparse
import collections
import concurrent.futures
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ICON = "assets/icons/fnapp.png"
# 固定口径：本源 distributor / 上游项目作者与项目页 / 项目 README（readme_url 走 jsDelivr CDN）
DISTRIBUTOR = "bekafka"
DISTRIBUTOR_URL = "https://github.com/bekafka/FnDepot"
VALID_CATEGORIES = ["影音娱乐", "系统工具", "编程开发", "AI赋能", "生活服务",
                    "智能智控", "教育学习", "游戏地带", "硬件驱动"]
REQUIRED = ["display_name", "desc", "platform", "categories", "icon_url", "run_as",
            "install_type", "is_docker", "releases"]
UA = {"User-Agent": "Mozilla/5.0 fndepot-verify"}


_abort = threading.Event()
_stats = {"fail": 0, "ok": 0, "done": 0}
_stats_lock = threading.Lock()


def head_size(url, timeout=12):
    """→ (content-length 或 None, 错误说明)。外链域名直连常抖，失败重试一次；
    但若前面的外链全都取不到（多半是网络不通），直接熔断，不再逐个耗时间。"""
    if _abort.is_set():
        return None, "已熔断（前面的外链全部取不到）"
    last = ""
    for attempt in range(2):
        try:
            # URL 可能含非 ASCII（中文文件名等），不转义会抛 UnicodeEncodeError 被误判成网络失败
            req = urllib.request.Request(urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%~"),
                                        method="HEAD", headers=UA)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                cl = resp.headers.get("Content-Length")
                return (int(cl) if cl and cl.isdigit() else None), ""
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}"
            if exc.code < 500:
                break
        except Exception as exc:  # noqa: BLE001
            last = type(exc).__name__
        if attempt == 0 and not _abort.is_set():
            time.sleep(1.0)
    return None, last


def _record(ok):
    with _stats_lock:
        _stats["ok" if ok else "fail"] += 1
        _stats["done"] += 1
        if not ok and _stats["ok"] == 0 and _stats["fail"] >= 3:
            _abort.set()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-net", action="store_true", help="跳过外链 Content-Length 核对")
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    problems, net_fail = [], []
    with open(os.path.join(ROOT, "fnpack.json"), encoding="utf-8") as fh:
        index = json.load(fh)

    if index.get("schema_version") != "2":
        problems.append(f'schema_version 必须是字符串 "2"，现在是 {index.get("schema_version")!r}')
    info = index.get("source_info") or {}
    for k in ("name", "author"):
        if not info.get(k):
            problems.append(f"source_info.{k} 缺失（缺了整个源同步失败）")
    if not os.path.exists(os.path.join(ROOT, DEFAULT_ICON)):
        problems.append(f"图标文件不存在：{DEFAULT_ICON}")

    apps = index.get("apps") or {}
    if not apps:
        problems.append("apps 为空")

    tasks = []           # (app, arch, size, url)；size=None 表示只查可达性（readme_url）
    seen_readme = set()  # 批量导入的条目共用同一个 README 地址，只查一次
    stats = collections.Counter()
    for key, app in apps.items():
        for f in REQUIRED:
            if f not in app:
                problems.append(f"{key}：缺必填字段 {f}")
        if app.get("run_as") not in ("package", "root"):
            problems.append(f"{key}：run_as={app.get('run_as')!r} 只能是 package/root")
        if app.get("install_type") not in ("", "root"):
            problems.append(f"{key}：install_type={app.get('install_type')!r} 只能是 \"\"/root")
        if not isinstance(app.get("is_docker"), bool):
            problems.append(f"{key}：is_docker 必须是布尔")
        icon = app.get("icon_url") or ""
        if icon != DEFAULT_ICON and not icon.startswith("https://"):
            problems.append(f"{key}：icon_url 必须是 {DEFAULT_ICON} 或绝对 https 地址，现在是 {icon!r}")
        if app.get("distributor") != DISTRIBUTOR or app.get("distributor_url") != DISTRIBUTOR_URL:
            problems.append(f"{key}：distributor 必须是 {DISTRIBUTOR} / {DISTRIBUTOR_URL}，现在是 "
                            f"{app.get('distributor')!r} / {app.get('distributor_url')!r}")
        repos = {m.group(1) for m in
                 (re.match(r"https://github\.com/([^/]+/[^/]+)/releases/download/",
                           pk.get("download_url") or "")
                  for rel in (app.get("releases") or {}).values()
                  for pk in (rel.get("packages") or {}).values()) if m}
        if len(repos) == 1:
            repos_holder = repos.pop()
            project = f"https://github.com/{repos_holder}"
            if app.get("maintainer_url") != project:
                problems.append(f"{key}：maintainer_url 必须是项目页 {project}，现在是 {app.get('maintainer_url')!r}")
            if not app.get("maintainer"):
                problems.append(f"{key}：maintainer 不能为空（上游项目作者）")
            ru = app.get("readme_url")
            if ru and not ru.startswith(f"https://cdn.jsdelivr.net/gh/{repos_holder}@"):
                problems.append(f"{key}：readme_url 必须用 jsDelivr CDN 地址，现在是 {ru!r}")
        plats = app.get("platform") or []
        if not isinstance(plats, list):
            problems.append(f"{key}：platform 必须是数组，现在是 {plats!r}（客户端会跳过该应用）")
            plats = []
        for p in plats:
            if p not in ("x86", "arm", "all"):
                problems.append(f"{key}：platform 里 {p!r} 非法")
        cats = app.get("categories") or []
        if not isinstance(cats, list):
            problems.append(f"{key}：categories 必须是数组，现在是 {cats!r}（客户端会跳过该应用）")
            cats = []
        for c in cats:
            if c not in VALID_CATEGORIES:
                problems.append(f"{key}：分类 {c!r} 不在固定分类表内")
        if not app.get("releases"):
            problems.append(f"{key}：没有 releases")
        for ver, rel in (app.get("releases") or {}).items():
            pkgs = rel.get("packages") or {}
            if not pkgs:
                problems.append(f"{key} {ver}：packages 为空")
            for arch, pk in pkgs.items():
                if arch not in ("x86", "arm", "all"):
                    problems.append(f"{key} {ver}：包键名 {arch!r} 非法")
                if plats != ["all"] and arch not in plats:
                    problems.append(f"{key} {ver}：包键名 {arch} 不在 platform {plats} 里")
                url = pk.get("download_url") or ""
                if not re.match(r"^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/.+$", url):
                    problems.append(f"{key} {ver}/{arch}：download_url 不是带 tag 的 GitHub release 地址：{url}")
                if "latest/download" in url:
                    problems.append(f"{key} {ver}/{arch}：不许用 latest/download 地址")
                sha = pk.get("sha256")
                if sha is None:
                    stats["no_sha"] += 1          # 批量导入的条目按口径不写；见 README 说明
                elif not re.fullmatch(r"[0-9a-f]{64}", sha):
                    problems.append(f"{key} {ver}/{arch}：sha256 不是 64 位十六进制：{sha!r}")
                else:
                    stats["has_sha"] += 1
                size = pk.get("size")
                if size is None:
                    stats["no_size"] += 1
                elif not isinstance(size, int) or size <= 0:
                    problems.append(f"{key} {ver}/{arch}：size 必须是正整数，现在是 {size!r}")
                else:
                    tasks.append((f"{key}/{arch}", size, url))
        ru = app.get("readme_url")
        if ru:
            if ru not in seen_readme:
                seen_readme.add(ru)
                tasks.append((f"{key} readme_url", None, ru))
            else:
                stats["readme_dedup"] += 1

    # README 收录表 ↔ 索引
    readme_path = os.path.join(ROOT, "README.md")
    if os.path.isfile(readme_path):
        with open(readme_path, encoding="utf-8") as fh:
            readme = fh.read()
        rows = re.findall(r"^\|\s*([^|]+?)\s*\|\s*`([^`]+)`\s*\|\s*([0-9][^|\s]*)\s*\|", readme, re.M)
        if not rows:
            problems.append("README 收录表里没解析到任何行（表头或格式变了？）")
        for shown_name, key, ver in rows:
            app = apps.get(key)
            if not app:
                problems.append(f"README 表里写了 `{key}`，但索引里没有这个应用键名（键名写错=客户端装不上）")
                continue
            versions = app.get("releases") or {}
            if ver not in versions:
                problems.append(f"README 表里 {key} 写 {ver}，索引里是 {sorted(versions)}")
            elif versions and ver != max(versions):
                problems.append(f"README 表里 {key} 写 {ver}，索引里最新是 {max(versions)}（收录/跟版后要同步表里的版本号）")
        listed = {k for _, k, _ in rows}
        stats["not_listed"] = sum(1 for key in apps if key not in listed)

    if not args.no_net and tasks:
        # 分批提交：一整批都失败时立刻熔断，剩下的不再发（网络不通时别逐个耗 30s）
        jobs = max(1, args.jobs)
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            for start in range(0, len(tasks), jobs):
                if _abort.is_set():
                    break
                chunk = tasks[start:start + jobs]
                futs = {pool.submit(head_size, url): (label, size) for label, size, url in chunk}
                for fut in concurrent.futures.as_completed(futs):
                    label, size = futs[fut]
                    remote, err = fut.result()
                    _record(err == "")
                    if err:
                        # readme_url 是网页，4xx 说明链接写错（不是网络问题）；包是文件，4xx 也只当查询失败记着
                        if size is None and err.startswith("HTTP 4"):
                            problems.append(f"{label}：{err} —— 链接写错了？")
                        else:
                            net_fail.append(f"{label}：{err}")
                    elif size is not None and remote != size:
                        problems.append(f"{label}：索引 size={size} ≠ 远端 Content-Length={remote}（上游重传过？）")
                    # size 为 None（readme_url）只要求请求成功：网页没有 Content-Length，不能拿它判失败

    for p in problems:
        print(f"✗ {p}")
    for n in net_fail:
        print(f"? {n}（网络查询失败，未核对该包）")
    ok = _stats["ok"]
    skipped = len(tasks) - _stats["done"]
    if net_fail and ok == 0:
        print("\n！外链全部取不到 —— 大概率是直连不通，而不是索引有问题。先试：\n"
              "    export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890")
    head = (f"\n应用 {len(apps)} 个；结构/一致性 {'通过' if not problems else '有问题'}"
            f"；有 sha256 的包 {stats['has_sha']}、无 {stats['no_sha']}"
            + (f"；README 表未列出 {stats['not_listed']} 个（批量收录）" if stats["not_listed"] else ""))
    if args.no_net:
        print(head + "（--no-net 跳过外链核对）")
    else:
        print(f"{head}；外链核对通过 {ok}/{len(tasks)}"
              + (f"，取不到 {len(net_fail)}" if net_fail else "")
              + (f"，熔断跳过 {skipped}" if skipped > 0 else ""))
    if problems:
        return 1
    return 2 if net_fail else 0


if __name__ == "__main__":
    sys.exit(main())
