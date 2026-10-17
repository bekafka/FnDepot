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

# ── 作者口径（FnFactory/specs/authorship.md）──────────────────────────────
AUTHOR_FIELDS = ("maintainer", "maintainer_url", "distributor", "distributor_url",
                 "source_author", "source_author_url")
FIXED_PUBLISHER = "bekafka"
FIXED_PUBLISHER_URL = "https://github.com/bekafka/FnDepot"
SOURCE_URL_RE = re.compile(
    r"^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$")
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")

_stats = collections.Counter()
_abort = False


def parse_manifest(path):
    """读 fnOS manifest 的键值（校验作者字段用；够用即可）。"""
    fields = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            fields[k.strip()] = v
    return fields


def load_readme():
    """解析 README 的「应用列表」表，返回 (列名→下标, 键名→行)。

    只认第一张带「键名」表头的表；遇到表后的空行就停，避免把后面的
    「兼容性」等表格误当应用行。
    """
    path = os.path.join(ROOT, "README.md")
    if not os.path.isfile(path):
        return {}, {}
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    header, rows = {}, {}
    for lineno, line in enumerate(lines, 1):
        s = line.strip()
        if not s.startswith("|"):
            if header:
                break
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if not header:
            if any(c.strip("`") == "键名" for c in cells):
                header = {c.strip("`"): i for i, c in enumerate(cells)}
            continue
        if all(re.fullmatch(r":?-{3,}:?", c) for c in cells if c):
            continue
        idx = header.get("键名")
        if idx is None or idx >= len(cells):
            continue
        key = cells[idx].strip("`")
        if key:
            rows[key] = {"cells": cells, "line_no": lineno, "line": s}
    return header, rows


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

    # ── README 应用列表（原作者列）──────────────────────────────────────
    readme_header, readme_rows = load_readme()
    if "键名" not in readme_header:
        problems.append("README 应用列表找不到「键名」列（README 结构被改了？）")
    if "原作者" not in readme_header:
        problems.append("README 应用列表缺少「原作者」列（FnFactory/specs/authorship.md）")

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

        # ── 作者口径（FnFactory/specs/authorship.md）────────────────────
        dist = app.get("distributor")
        dist_url = app.get("distributor_url")
        if dist != FIXED_PUBLISHER:
            problems.append(
                f"{key}：distributor 应为 {FIXED_PUBLISHER}（发布者固定本源），现在是 {dist!r}")
        if dist_url != FIXED_PUBLISHER_URL:
            problems.append(
                f"{key}：distributor_url 应为 {FIXED_PUBLISHER_URL}，现在是 {dist_url!r}")

        src = (app.get("source_author") or "").strip()
        src_url = (app.get("source_author_url") or "").strip()
        if not src:
            problems.append(f"{key}：缺 source_author（源作者＝上游项目最初的创造者/组织）")
        m = SOURCE_URL_RE.match(src_url)
        if not m:
            problems.append(
                f"{key}：source_author_url 必须是上游项目主页 "
                f"https://github.com/<owner>/<repo>，现在是 {src_url!r}")
        else:
            url_owner, url_repo = m.group(1), m.group(2)
            if src and src != url_owner:
                problems.append(
                    f"{key}：source_author（{src}）与项目页 owner（{url_owner}）不一致")
            if src_url.rstrip("/") != f"https://github.com/{url_owner}/{url_repo}":
                problems.append(f"{key}：source_author_url 不要带多余路径/斜杠：{src_url!r}")

        pkg_manifest = os.path.join(ROOT, "apps", key, "package", "manifest")
        row = readme_rows.get(key)
        if os.path.isfile(pkg_manifest):
            mf = parse_manifest(pkg_manifest)
            for f in AUTHOR_FIELDS:
                if mf.get(f) != app.get(f):
                    problems.append(
                        f"{key}：索引 {f}={app.get(f)!r} 与 "
                        f"apps/{key}/package/manifest 的 {mf.get(f)!r} 不一致")
            if src_url and src_url not in (mf.get("desc") or ""):
                problems.append(
                    f"{key}：apps/{key}/package/manifest 的 desc 里没有源作者链接 {src_url}")
            if not row:
                problems.append(
                    f"{key}：README 应用列表少了这一行（自建应用必须列出并带「原作者」链接）")
        elif not row:
            print(f"ℹ️  {key}：README 应用列表未列出（第三方收录可选）")

        if row:
            cells = row["cells"]

            app_idx = readme_header.get("应用", 1)
            if app_idx < len(cells):
                links = MD_LINK_RE.findall(cells[app_idx])
                if links:
                    href = links[0][1].strip()
                    if not href.startswith(("http://", "https://")) \
                            and not os.path.isfile(os.path.join(ROOT, href)):
                        problems.append(f"{key}：README 里的应用链接指向不存在的文件：{href}")

            author_idx = readme_header.get("原作者")
            if author_idx is None:
                pass  # 缺列已在表头统一报过
            elif author_idx >= len(cells):
                problems.append(f"{key}：README 这一行少了「原作者」单元格")
            else:
                alinks = MD_LINK_RE.findall(cells[author_idx])
                if not alinks:
                    problems.append(
                        f"{key}：README「原作者」列必须是 Markdown 链接，现在是 {cells[author_idx]!r}")
                else:
                    got = alinks[0][1].strip().rstrip("/")
                    if src_url and got != src_url.rstrip("/"):
                        problems.append(
                            f"{key}：README「原作者」链接 {got!r} 与索引 "
                            f"source_author_url {src_url!r} 不一致")

            ver_idx = readme_header.get("版本")
            if ver_idx is not None and ver_idx < len(cells) and releases:
                want = max(releases)
                if cells[ver_idx].strip() != want:
                    problems.append(
                        f"{key}：README 版本 {cells[ver_idx].strip()!r} ≠ 索引最新版本 {want!r}"
                        "（发版流水线会同步，别手改错）")

            arch_idx = readme_header.get("架构")
            if arch_idx is not None and arch_idx < len(cells) and plats \
                    and all(p in VALID_PLATFORMS for p in plats):
                want_arch = "all" if plats == ["all"] else " / ".join(sorted(plats))
                if cells[arch_idx].strip() != want_arch:
                    problems.append(
                        f"{key}：README 架构 {cells[arch_idx].strip()!r} ≠ "
                        f"索引 platform 显示 {want_arch!r}")

    # ── README 里出现索引没有的键名 ─────────────────────────────────────
    for key in readme_rows:
        if key not in apps:
            problems.append(f"README 应用列表里的 `{key}` 不在索引中（键名写错/已删？）")

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
