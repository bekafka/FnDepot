#!/usr/bin/env python3
"""向 FnDepot 索引里「上架」一个新应用（只写应用级元数据，不写版本）。

为什么必须单独有这一步：
    发布流水线只做 `.apps[K].releases[V] = {...}`。如果 K 还不存在，jq 会
    建出一个**只含 releases 的空壳**，缺 display_name / categories / platform
    / icon_url / run_as / install_type / is_docker 中的任何一个，
    客户端就会**静默跳过该应用**（索引看起来完全正常）。所以先上架、再发版。

用法（默认 dry-run，加 --write 才落盘）：
    python3 tools/add-app.py \
        --key MyApp \
        --display-name "我的应用" \
        --desc "一句话描述" \
        --categories 系统工具 \
        --platform x86 arm \
        --repo bekafka/myapp \
        --run-as root \
        --install-type "" \
        --write
"""

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISTRIBUTOR = "bekafka"
DISTRIBUTOR_URL = "https://github.com/bekafka/FnDepot"
DEFAULT_ICON = "assets/icons/fnapp.png"

REPO_RE = re.compile(r"^[^/\s]+/[^/\s]+$")


def load_json(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
        return json.load(fh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True,
                    help="应用键名，必须逐字等于包内 manifest 的 appname")
    ap.add_argument("--display-name", required=True)
    ap.add_argument("--desc", required=True)
    ap.add_argument("--categories", required=True, nargs="+")
    ap.add_argument("--platform", required=True, nargs="+", choices=["x86", "arm", "all"])
    ap.add_argument("--repo", required=True,
                    help="承载 Release 的仓库 owner/repo（决定 maintainer_url）")
    ap.add_argument("--run-as", default="package", choices=["package", "root"])
    ap.add_argument("--install-type", default="",
                    help='"" = 存储空间（默认）；"root" = 系统空间，需物证（cmd/install_callback 碰 /boot 或注册 systemd）')
    ap.add_argument("--is-docker", action="store_true")
    ap.add_argument("--icon", default=DEFAULT_ICON,
                    help=f"本地相对路径（默认 {DEFAULT_ICON}）或绝对 https 地址")
    ap.add_argument("--service-port", default=None)
    ap.add_argument("--readme", action="store_true",
                    help="额外写 readme_url（走 jsDelivr CDN）")
    ap.add_argument("--write", action="store_true", help="真正落盘（默认只预览）")
    args = ap.parse_args()

    if not REPO_RE.match(args.repo):
        sys.exit(f"--repo 必须是 owner/repo 形式，现在是 {args.repo!r}")

    valid_categories = set(load_json("categories.json").get("categories") or [])
    bad = [c for c in args.categories if c not in valid_categories]
    if bad:
        sys.exit(f"分类 {bad} 不在固定分类表内。可用：{sorted(valid_categories)}")

    index = load_json("fnpack.json")
    apps = index.setdefault("apps", {})

    if args.key in apps:
        sys.exit(f"应用键 {args.key!r} 已存在。跟版请直接跑发布流水线，不要重复上架。")

    if args.platform == ["all"] and len(args.platform) > 1:
        sys.exit('platform "all" 不能与其他值同时出现')

    if not args.icon.startswith("https://"):
        if not os.path.isfile(os.path.join(ROOT, args.icon)):
            sys.exit(f"图标文件不存在：{args.icon}（放一张进去，或用 --icon https://... 指定外链）")

    owner = args.repo.split("/")[0]
    node = {
        "display_name": args.display_name,
        "desc": args.desc,
        "platform": args.platform,
        "categories": args.categories,
        "icon_url": args.icon,
        "run_as": args.run_as,
        "install_type": args.install_type,
        "is_docker": bool(args.is_docker),
        "distributor": DISTRIBUTOR,
        "distributor_url": DISTRIBUTOR_URL,
        "maintainer": owner,
        "maintainer_url": f"https://github.com/{args.repo}",
        "releases": {},
    }
    if args.service_port:
        node["service_port"] = args.service_port
    if args.readme:
        node["readme_url"] = f"https://cdn.jsdelivr.net/gh/{args.repo}@latest/README.md"

    print(f"将要写入 .apps[{args.key!r}]：")
    print(json.dumps(node, ensure_ascii=False, indent=2))

    if not args.write:
        print("\n（dry-run，未落盘。确认无误后加 --write）")
        return 0

    apps[args.key] = node
    path = os.path.join(ROOT, "fnpack.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(f"\n✓ 已写入 {path}")
    print("下一步：")
    print("  1) python3 tools/verify.py --no-net     # 会报『没有 releases』，这是预期的")
    print("  2) 触发应用的发布流水线，让它写入第一个版本节点")
    print("  3) 再跑一次 verify.py，应当通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
