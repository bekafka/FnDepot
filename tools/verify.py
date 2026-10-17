#!/usr/bin/env python3
"""FnDepot 索引校验器。

只做一件事：把「客户端会静默跳过 / 静默装不上」的坑，在本地就变成一条红色报错。

用法：
    python3 tools/verify.py --no-net     # 秒级，只查结构与一致性（推荐先跑这个）
    python3 tools/verify.py              # 全量，额外核对每个外链的 Content-Length

退出码：
    0  结构通过且外链全部核对通过
    1  结构或一致性问题（必须修）
    2  结构没问题，但有外链取不到（多半是网络，不是索引坏了）
"""

import argparse
import collections
import concurrent.futures
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REQUIRED_APP_FIELDS = [
    "display_name", "desc", "platform", "categories",
    "icon_url", "run_as", "install_type", "is_docker", "releases",
]
VALID_PLATFORMS = ("x86", "arm", "all")
VALID_RUN_AS = ("package", "root")
VALID_INSTALL_TYPE = ("", "root")

DL_URL_RE = re.compile(
    r"^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/.+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

_stats = collections.Counter()
_abort = False


def load_categories():
    path = os.path.join(ROOT, "categories.json")
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return set(data.get("categories") or [])


def head_size(url, timeout=12):
    """只取响应头，返回 (content-length 或 None, 错误说明)。"""
    global _abort
    req = urllib.request.Request(url, method="HEAD",
                                 headers={"User-Agent": "FnDepot-verify/1.0"})
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                cl = resp.headers.get("Content-Length")
                return (int(cl) if cl is not None else None), ""
        except urllib.error.HTTPError as exc:
            return None, f"HTTP {exc.code}"
        except Exception as exc:                      # noqa: BLE001
            if attempt == 2:
                _abort = True
                return None, type(exc).__name__
    return None, "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-net", action="store_true",
                    help="跳过外链 Content-Length 核对")
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    problems, net_fail = [], []

    with open(os.path.join(ROOT, "fnpack.json"), encoding="utf-8") as fh:
        index = json.load(fh)

    valid_categories = load_categories()

    # ── 源级 ────────────────────────────────────────────────────────────
    if index.get("schema_version") != "2":
        problems.append(f'schema_version 必须是字符串 "2"，现在是 {index.get("schema_version")!r}')
    info = index.get("source_info") or {}
    for k in ("name", "author"):
        if not info.get(k):
            problems.append(f"source_info.{k} 缺失（缺了整个源同步失败）")

    apps = index.get("apps") or {}
    if not apps:
        print("ℹ️  apps 为空（新仓库尚未收录任何应用）")

    # ── 应用级与版本级 ──────────────────────────────────────────────────
    tasks = []          # (label, size, url)；size=None 表示只查可达性

    for key, app in apps.items():
        for f in REQUIRED_APP_FIELDS:
            if f not in app:
                problems.append(f"{key}：缺必填字段 {f}")

        if app.get("run_as") not in VALID_RUN_AS:
            problems.append(f"{key}：run_as={app.get('run_as')!r} 只能是 {VALID_RUN_AS}")
        if app.get("install_type") not in VALID_INSTALL_TYPE:
            problems.append(f'{key}：install_type={app.get("install_type")!r} 只能是 "" 或 "root"')
        if not isinstance(app.get("is_docker"), bool):
            problems.append(f"{key}：is_docker 必须是布尔")

        # icon：允许本地相对路径（必须存在）或绝对 https 地址
        icon = app.get("icon_url") or ""
        if icon.startswith("https://"):
            tasks.append((f"{key} icon_url", None, icon))
        elif not icon:
            problems.append(f"{key}：icon_url 不能为空")
        elif not os.path.isfile(os.path.join(ROOT, icon)):
            problems.append(f"{key}：icon_url 指向的本地文件不存在：{icon}")

        # platform
        plats = app.get("platform")
        if not isinstance(plats, list):
            problems.append(f"{key}：platform 必须是数组，现在是 {plats!r}（客户端会跳过该应用）")
            plats = []
        for p in plats:
            if p not in VALID_PLATFORMS:
                problems.append(f"{key}：platform 里 {p!r} 非法，只能是 {VALID_PLATFORMS}")

        # categories
        cats = app.get("categories")
        if not isinstance(cats, list):
            problems.append(f"{key}：categories 必须是数组，现在是 {cats!r}（客户端会跳过该应用）")
            cats = []
        for c in cats:
            if c not in valid_categories:
                problems.append(f"{key}：分类 {c!r} 不在固定分类表内（见 categories.json）")

        # releases
        releases = app.get("releases")
        if not isinstance(releases, dict) or not releases:
            problems.append(f"{key}：没有 releases")

        for ver, rel in (releases or {}).items():
            pkgs = (rel or {}).get("packages") or {}
            if not pkgs:
                problems.append(
                    f"{key} {ver}：packages 为空"
                    "（常见原因：jq 把 packages 平铺进了 release 节点，而不是嵌套）")
            for arch, pk in pkgs.items():
                pk = pk or {}
                if arch not in VALID_PLATFORMS:
                    problems.append(f"{key} {ver}：包键名 {arch!r} 非法")
                if plats != ["all"] and arch not in plats:
                    problems.append(
                        f"{key} {ver}：包键名 {arch} 不在 platform {plats} 里"
                        "（该架构的设备会看不到这个应用）")

                url = pk.get("download_url") or ""
                if not DL_URL_RE.match(url):
                    problems.append(f"{key} {ver}/{arch}：download_url 不是带 tag 的 release 地址：{url!r}")
                if "latest/download" in url:
                    problems.append(f"{key} {ver}/{arch}：不许用 latest/download（上游一发包旧地址就 404）")

                sha = pk.get("sha256")
                if sha is None:
                    _stats["no_sha"] += 1
                elif not SHA256_RE.match(str(sha)):
                    problems.append(f"{key} {ver}/{arch}：sha256 不是 64 位小写十六进制：{sha!r}")
                else:
                    _stats["has_sha"] += 1

                size = pk.get("size")
                if size is None:
                    _stats["no_size"] += 1
                elif not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                    problems.append(f"{key} {ver}/{arch}：size 必须是正整数，现在是 {size!r}")
                else:
                    tasks.append((f"{key}/{arch}", size, url))

    # ── 外链核对 ────────────────────────────────────────────────────────
    ok = 0
    if not args.no_net and tasks:
        jobs = max(1, args.jobs)
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            for start in range(0, len(tasks), jobs):
                if _abort:
                    break
                chunk = tasks[start:start + jobs]
                futs = {pool.submit(head_size, url): (label, size) for label, size, url in chunk}
                for fut in concurrent.futures.as_completed(futs):
                    label, size = futs[fut]
                    remote, err = fut.result()
                    if err:
                        if size is None and err.startswith("HTTP 4"):
                            problems.append(f"{label}：{err} —— 链接写错了？")
                        else:
                            net_fail.append(f"{label}：{err}")
                    elif size is not None and remote is not None and remote != size:
                        problems.append(
                            f"{label}：索引 size={size} ≠ 远端 Content-Length={remote}"
                            "（上游重传过？哈希已失效，需重算）")
                    else:
                        ok += 1

    # ── 汇总 ────────────────────────────────────────────────────────────
    for p in problems:
        print(f"✗ {p}")
    for n in net_fail:
        print(f"? {n}（网络查询失败，未核对该包）")

    if net_fail and ok == 0:
        print("\n！外链全部取不到 —— 大概率是网络不通，而不是索引有问题。")

    head = (f"\n应用 {len(apps)} 个；结构/一致性 "
            + ("通过" if not problems else f"有 {len(problems)} 个问题")
            + f"；有 sha256 的包 {_stats['has_sha']}、无 {_stats['no_sha']}")
    print(head + ("（--no-net 跳过外链核对）"
                  if args.no_net else f"；外链核对通过 {ok}/{len(tasks)}"
                  + (f"，取不到 {len(net_fail)}" if net_fail else "")))

    if problems:
        return 1
    return 2 if net_fail else 0


if __name__ == "__main__":
    sys.exit(main())
