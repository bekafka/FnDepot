#!/usr/bin/env python3
"""从第三方 GitHub Release 的 .fpk 生成 FnDepot V2 条目。

引用别人的 release 地址时，下列字段必须来自安装包本体而不是猜：
  appname / version / platform / display_name / desc / maintainer /
  service_port / os_min_version / sha256 / size
本脚本下载指定资产、解开 manifest 并全部算好，输出可直接粘进 fnpack.json 的条目。

用法:
  python3 tools/new-entry.py <owner/repo> <tag> <asset> [-c 分类] [--write]

示例:
  python3 tools/new-entry.py gulugulupao/onekey-overclock v1.2.0 \\
      OneKey-OC-v1.2.0-lite.fpk -c 系统工具 --write

选项:
  -c/--categories  固定分类，逗号分隔；多个时第一个作主分类。省略则用 系统工具。
  --write          直接并入仓库根目录 fnpack.json（会先写 fnpack.json.bak 备份）。
  --changelog-max  changelog 截断长度，默认 400 字符，0 表示不截断。

需要访问 GitHub：国内直连失败时先导出代理，例如
  export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tarfile
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VALID_CATEGORIES = [
    "影音娱乐", "系统工具", "编程开发", "AI赋能", "生活服务",
    "智能智控", "教育学习", "游戏地带", "硬件驱动",
]


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "fndepot-source-builder"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(dest, "wb") as fh:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            fh.write(chunk)


def read_manifest(fp_path):
    """fpk 是 tar.gz：manifest 是 'key = value' 文本，config/privilege 是 JSON。"""
    with tarfile.open(fp_path, "r:gz") as tar:
        raw = tar.extractfile(tar.getmember("manifest")).read().decode("utf-8", "replace")
        fields = {}
        for line in raw.splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, _, value = line.partition("=")
            fields[key.strip()] = value.strip()
        # 运行身份只写在 config/privilege 里，manifest 查不到
        try:
            priv = json.loads(tar.extractfile(tar.getmember("config/privilege")).read().decode("utf-8"))
            fields["_run_as"] = (priv.get("defaults") or {}).get("run-as", "")
        except (KeyError, ValueError):
            fields["_run_as"] = ""
    return fields


def truncate(text, limit):
    text = (text or "").strip()
    if limit and len(text) > limit:
        return text[:limit].rstrip() + "…"
    return text


def build_entry(fields, sha256, size, download_url, categories, changelog_max, install_type=""):
    appname = fields.get("appname")
    if not appname:
        sys.exit("错误：manifest 里没有 appname，无法确定 FnDepot 应用键名")

    platform = fields.get("platform", "").strip().lower()
    arch = platform if platform in ("x86", "arm") else "all"

    entry = {
        "display_name": fields.get("display_name", appname),
        "desc": fields.get("desc", ""),
        "platform": [arch],
        "categories": categories,
        "icon_url": f"assets/icons/{appname}.png",
        "run_as": "root" if fields.get("_run_as") == "root" else "package",
        "install_type": install_type,
        "is_docker": fields.get("source", "") == "docker",
        "releases": {
            fields.get("version", "1.0.0"): {
                "packages": {
                    arch: {
                        "download_url": download_url,
                        "sha256": sha256,
                        "size": size,
                    }
                }
            }
        },
    }

    # 可选字段：有就带上
    if fields.get("maintainer"):
        entry["maintainer"] = fields["maintainer"]
    if fields.get("maintainer_url"):
        entry["maintainer_url"] = fields["maintainer_url"]
    if fields.get("distributor") and fields["distributor"] != fields.get("maintainer"):
        entry["distributor"] = fields["distributor"]
        if fields.get("distributor_url"):
            entry["distributor_url"] = fields["distributor_url"]
    if fields.get("service_port"):
        entry["service_port"] = fields["service_port"]

    rel = entry["releases"][fields.get("version", "1.0.0")]
    if fields.get("changelog"):
        rel["changelog"] = truncate(fields["changelog"], changelog_max)
    if fields.get("os_min_version") or fields.get("os_min_ver"):
        rel["os_min_version"] = fields.get("os_min_version") or fields.get("os_min_ver")

    return appname, entry


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("repo", help="owner/repo")
    ap.add_argument("tag", help="release tag，例如 v1.2.0")
    ap.add_argument("asset", help="资产文件名，例如 OneKey-OC-v1.2.0-lite.fpk")
    ap.add_argument("-c", "--categories", default="系统工具")
    ap.add_argument("--install-type", default="", choices=["", "root"],
                    help='安装空间：""=存储空间（默认），root=系统空间（写 /boot、注册 systemd 的应用选它）')
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--changelog-max", type=int, default=400)
    args = ap.parse_args()

    categories = [c.strip() for c in args.categories.split(",") if c.strip()]
    bad = [c for c in categories if c not in VALID_CATEGORIES]
    if bad:
        sys.exit(f"错误：分类 {bad} 不在固定分类表内：{'、'.join(VALID_CATEGORIES)}")

    url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{args.asset}"
    print(f"下载 {url}", file=sys.stderr)

    with tempfile.TemporaryDirectory() as tmp:
        fp_path = os.path.join(tmp, "pkg.fpk")
        download(url, fp_path)
        size = os.path.getsize(fp_path)
        sha256 = hashlib.sha256(open(fp_path, "rb").read()).hexdigest()
        fields = read_manifest(fp_path)

    appname, entry = build_entry(fields, sha256, size, url, categories, args.changelog_max, args.install_type)
    version = list(entry["releases"])[0]
    print(f"appname={appname} version={version} arch={entry['platform'][0]} "
          f"run_as={entry['run_as']} size={size}B sha256={sha256[:12]}…", file=sys.stderr)

    blob = json.dumps(entry, ensure_ascii=False, indent=2)

    if not args.write:
        print(f'"{appname}": {blob}')
        return

    index_path = os.path.join(ROOT, "fnpack.json")
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as fh:
            index = json.load(fh)
        with open(index_path + ".bak", "w", encoding="utf-8") as fh:
            json.dump(index, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
    else:
        index = {"schema_version": "2", "source_info": {"name": "FnDepot 源", "author": ""}, "apps": {}}

    index.setdefault("apps", {})[appname] = entry
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"已写入 {index_path}（应用 {appname}）", file=sys.stderr)


if __name__ == "__main__":
    main()
