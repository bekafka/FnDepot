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

import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gh import gh_token  # noqa: E402  （token 查找见 tools/_gh.py）

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UA = {"User-Agent": "fndepot-source-checker"}
_token_warned = []


def http(url, method="GET", timeout=45):
    headers = dict(UA)
    token = gh_token()
    if token and "api.github.com" in url:
        headers["Authorization"] = f"Bearer {token}"
        headers["Accept"] = "application/vnd.github+json"
    try:
        req = urllib.request.Request(url, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if method == "HEAD":
                cl = resp.headers.get("Content-Length")
                return int(cl) if cl and cl.isdigit() else None
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        if exc.code == 401 and "api.github.com" in url and not _token_warned:
            _token_warned.append(1)
            print("  ！GitHub token 被拒（401 Bad credentials）：检查 .gh_token 是否正确或已过期",
                  file=sys.stderr)
        return None
    except Exception:
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
    atom = http(f"https://github.com/{repo}/releases.atom")
    if not atom:
        return None, {}, "atom 取不到（网络/代理？）"
    tags = re.findall(r"releases/tag/([^\"<]+)", atom)
    if not tags:
        return None, {}, "该仓库没有 release"
    tag = tags[0]
    html = http(f"https://github.com/{repo}/releases/expanded_assets/{tag}") or ""
    return tag, parse_assets(html), "html"


def asset_regex(our_name, our_version):
    """把资产名里的版本号变成通配，用来匹配上游新版本的同类资产（保留 -arm/-x86 等区分）。"""
    pattern = re.escape(our_name).replace(re.escape(our_version), r"[\d.]+")
    return re.compile(pattern + "$")


def norm(tag):
    return tag.lstrip("vV")


def main():
    with open(os.path.join(ROOT, "fnpack.json"), encoding="utf-8") as fh:
        index = json.load(fh)
    only = set(sys.argv[1:])
    todo, failed, busy = [], [], []
    for app, entry in sorted(index.get("apps", {}).items()):
        if only and app not in only:
            continue
        versions = sorted(entry.get("releases", {}))
        if not versions:
            continue
        our_ver = versions[-1]
        pkgs = entry["releases"][our_ver].get("packages", {})
        for arch, pkg in pkgs.items():
            m = re.match(r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/(.+)$",
                         pkg.get("download_url", ""))
            if not m:
                failed.append(f"{app}/{arch}: 下载地址不是 GitHub release 形式")
                continue
            repo, our_tag, our_asset = m.group(1), m.group(2), m.group(3)
            tag, assets, src = upstream(repo)
            if tag is None:
                failed.append(f"{app}/{arch}: {src}"); continue

            rx = asset_regex(our_asset, our_ver)
            match = next((n for n in assets if rx.match(n)), None)
            if norm(tag) != norm(our_ver):
                busy.append(f"{app}/{arch}: 有新版本 {our_ver} → {norm(tag)}"
                            f"（新资产 {match or '命名变了，需人工看'}）")
            elif match is None:
                busy.append(f"{app}/{arch}: 版本未变但上游资产名对不上（原有 {our_asset}）")
            else:
                up_digest = assets.get(match) or ""
                if up_digest and up_digest != pkg.get("sha256"):
                    busy.append(f"{app}/{arch}: 同版本资产被重传！我们钉的 sha256 已失效"
                                f"（我们 {pkg.get('sha256','')[:12]}… / 上游 {up_digest[:12]}…）")
                else:
                    up_size = http(f"https://github.com/{repo}/releases/download/{tag}/{match}", "HEAD")
                    if up_size and up_size != pkg.get("size"):
                        busy.append(f"{app}/{arch}: 同版本资产大小变了（{pkg.get('size')} → {up_size}）")
                    else:
                        print(f"  最新  {app}/{arch}  {our_ver}（{src}）")

    print()
    if busy:
        print("需要处理：")
        for line in busy:
            print("  ! " + line)
    if failed:
        print("查询失败：")
        for line in failed:
            print("  ? " + line)
    if not busy and not failed:
        print("全部已是最新 ✓")
        return 0
    return 2 if failed else 1


if __name__ == "__main__":
    sys.exit(main())
