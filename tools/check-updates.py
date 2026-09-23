#!/usr/bin/env python3
"""巡检已收录应用的上游是否有新版——只查元数据，不下载安装包。

两种取数路径，自动选择：
  1. GitHub API /releases/latest：一次请求拿到 tag、资产名、size、sha256 digest（消耗配额，未认证按 IP 算 60 次/小时）
  2. 降级路径（不耗配额）：releases.atom 取最新 tag + release 页面的官方 digest + HEAD 取 content-length

会报出三类情况：
  · 上游发了新版本（tag 变了）
  · 同版本但资产被重传（digest/size 变了）—— 这时我们钉在 fnpack.json 里的 sha256 已失效，客户端会拒装
  · 上游资产命名变了，匹配不到

用法:
  python3 tools/check-updates.py [appname ...]     # 默认检查全部已收录应用
退出码: 0 全部最新 | 1 有需要处理的 | 2 有应用查询失败
"""

import argparse
import concurrent.futures
import json
import os
import re
import sys
import threading
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gh import gh_token  # noqa: E402  （token 查找见 tools/_gh.py）

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UA = {"User-Agent": "fndepot-source-checker"}
_token_warned = []
_tls = threading.local()   # 线程各自的「最近一次失败原因」——并发跑时不能共用一个全局
_TOKEN = [None]


def token():
    """token 只解析一次（每次调用都要读 .env，并发下没必要反复读盘）。"""
    if _TOKEN[0] is None:
        _TOKEN[0] = gh_token() or ""
    return _TOKEN[0]


def http(url, method="GET", timeout=30):
    headers = dict(UA)
    tok = token()
    if tok and "api.github.com" in url:
        headers["Authorization"] = f"Bearer {tok}"
        headers["Accept"] = "application/vnd.github+json"
    try:
        req = urllib.request.Request(url, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if method == "HEAD":
                cl = resp.headers.get("Content-Length")
                return int(cl) if cl and cl.isdigit() else None
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        _tls.last_error = f"HTTP {exc.code}"
        if exc.code == 401 and "api.github.com" in url and not _token_warned:
            _token_warned.append(1)
            print("  ！GitHub token 被拒（401 Bad credentials）：检查 token 是否正确或已过期",
                  file=sys.stderr)
        return None
    except Exception as exc:
        _tls.last_error = type(exc).__name__
        return None


def parse_assets(html_text):
    """从 release 页面 HTML 里按文档顺序配对「资产名 → 官方 sha256」。"""
    toks = re.findall(r"releases/download/[^\"]+/([^\"?#]+)|\b(sha256:[0-9a-f]{64})\b", html_text)
    assets, cur = {}, None
    for name, dig in toks:
        if name:
            cur = name
        elif dig and cur:
            assets[cur] = dig.split(":", 1)[1]
            cur = None
    return assets


def upstream(repo):
    """→ (tag, {资产名: sha256}, 数据来源) ；失败返回 (None, {}, 原因)"""
    _tls.last_error = None
    data = http(f"https://api.github.com/repos/{repo}/releases/latest")
    if data:
        try:
            js = json.loads(data)
            if js.get("tag_name"):
                return js["tag_name"], {a["name"]: (a.get("digest") or "").replace("sha256:", "")
                                        for a in js.get("assets", [])}, "api"
        except ValueError:
            pass
    # 降级：不耗配额
    note = f"（api 失败：{_tls.last_error}）" if _tls.last_error else ""
    atom = http(f"https://github.com/{repo}/releases.atom")
    if not atom:
        return None, {}, f"atom 也取不到（网络/代理？{_tls.last_error or ''}）"
    tags = re.findall(r"releases/tag/([^\"<]+)", atom)
    if not tags:
        return None, {}, "该仓库没有 release"
    tag = tags[0]
    html = http(f"https://github.com/{repo}/releases/expanded_assets/{tag}") or ""
    return tag, parse_assets(html), "html" + note


def asset_regex(our_name, our_version):
    """把资产名里的版本号变成通配，用来匹配上游新版本的同类资产（保留 -arm/-x86 等区分）。

    版本号可能带非数字片段（如 0.6.0-beta.25），只替换成 [\\d.]+ 会连自己都匹配不上，
    导致误报「资产名对不上」——这里先用宽松的 [\\w.+-]+ 兜住，始终把原名放进去比对。
    """
    esc_ver = re.escape(our_version)
    if esc_ver and esc_ver in re.escape(our_name):
        pattern = re.escape(our_name).replace(esc_ver, r"[\w.+-]+")
    else:
        pattern = re.escape(our_name)
    return re.compile(pattern + r"$|" + re.escape(our_name) + r"$")


def norm(tag):
    return tag.lstrip("vV")


def main():
    ap = argparse.ArgumentParser(description="巡检已收录应用的上游是否发新版 / 资产被重传")
    ap.add_argument("apps", nargs="*", help="只查这些应用键名，省略则全查")
    ap.add_argument("--jobs", type=int, default=8, help="并发查询数，默认 8")
    args = ap.parse_args()
    only = set(args.apps)

    with open(os.path.join(ROOT, "fnpack.json"), encoding="utf-8") as fh:
        index = json.load(fh)
    failed, busy = [], []

    # README 收录表里的版本号是否与索引同步（表容易忘改）
    readme_path = os.path.join(ROOT, "README.md")
    if os.path.isfile(readme_path):
        with open(readme_path, encoding="utf-8") as fh:
            readme = fh.read()
        for key, shown in re.findall(r"^\|\s*[^|]+\|\s*`([^`]+)`\s*\|\s*([0-9][^|\s]*)\s*\|", readme, re.M):
            entry = index.get("apps", {}).get(key)
            if not entry:
                continue
            versions = entry.get("releases", {})
            if shown not in versions:
                busy.append(f"{key}: README 表里写 {shown}，索引里是 {sorted(versions)}（表未同步）")
            elif versions and shown != max(versions):
                busy.append(f"{key}: README 表里写 {shown}，索引里最新是 {max(versions)}（表未同步）")

    # 摊平成待查清单，再按仓库并发取上游（同一仓库的多个架构只查一次）
    items = []
    for app, entry in sorted(index.get("apps", {}).items()):
        if only and app not in only:
            continue
        versions = sorted(entry.get("releases", {}))
        if not versions:
            continue
        our_ver = versions[-1]
        for arch, pkg in entry["releases"][our_ver].get("packages", {}).items():
            m = re.match(r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/(.+)$",
                         pkg.get("download_url", ""))
            if not m:
                failed.append(f"{app}/{arch}: 下载地址不是 GitHub release 形式")
                continue
            items.append({"app": app, "arch": arch, "ver": our_ver, "pkg": pkg,
                          "repo": m.group(1), "tag": m.group(2), "asset": m.group(3)})

    ups = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futs = {pool.submit(upstream, r): r for r in {i["repo"] for i in items}}
        for fut in concurrent.futures.as_completed(futs):
            repo = futs[fut]
            try:
                ups[repo] = fut.result()
            except Exception as exc:  # noqa: BLE001
                ups[repo] = (None, {}, f"查询异常：{exc}")

    heads = []          # 需要核对 size 的包（仅在没有官方 digest 时），第二轮并发
    checked = []
    for it in items:
        tag, assets, src = ups.get(it["repo"], (None, {}, "未查询"))
        if tag is None:
            failed.append(f"{it['app']}/{it['arch']}: {src}")
            continue
        rx = asset_regex(it["asset"], it["ver"])
        match = next((n for n in assets if rx.match(n)), None)
        if norm(tag) != norm(it["ver"]):
            busy.append(f"{it['app']}/{it['arch']}: 有新版本 {it['ver']} → {norm(tag)}"
                        f"（新资产 {match or '命名变了，需人工看'}）")
        elif match is None:
            busy.append(f"{it['app']}/{it['arch']}: 版本未变但上游资产名对不上（原有 {it['asset']}）")
        else:
            up_digest = assets.get(match) or ""
            if up_digest and up_digest != it["pkg"].get("sha256"):
                busy.append(f"{it['app']}/{it['arch']}: 同版本资产被重传！我们钉的 sha256 已失效"
                            f"（我们 {it['pkg'].get('sha256','')[:12]}… / 上游 {up_digest[:12]}…）")
            elif up_digest:
                # 官方 digest 一致 ⇒ 内容没变 ⇒ size 必然没变，不必再发 HEAD（省一轮请求）
                checked.append(f"  最新  {it['app']}/{it['arch']}  {it['ver']}（{src}）")
            else:
                heads.append((it, match, src))   # 上游没给 digest，只能靠 HEAD 核对 size

    if heads:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            futs = {pool.submit(http, f"https://github.com/{it['repo']}/releases/download/"
                                      f"{it['tag']}/{match}", "HEAD"): (it, match, src)
                    for it, match, src in heads}
            for fut in concurrent.futures.as_completed(futs):
                it, match, src = futs[fut]
                up_size = fut.result()
                if up_size and up_size != it["pkg"].get("size"):
                    busy.append(f"{it['app']}/{it['arch']}: 同版本资产大小变了"
                                f"（{it['pkg'].get('size')} → {up_size}）")
                else:
                    checked.append(f"  最新  {it['app']}/{it['arch']}  {it['ver']}（{src}）")
        for line in sorted(checked):
            print(line)

    print()
    if busy:
        print("需要处理：")
        for line in sorted(busy):
            print("  ! " + line)
    if failed:
        print("查询失败：")
        for line in sorted(failed):
            print("  ? " + line)
    if not busy and not failed:
        print("全部已是最新 ✓")
        return 0
    return 2 if failed else 1


if __name__ == "__main__":
    sys.exit(main())
