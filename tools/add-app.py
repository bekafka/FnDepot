#!/usr/bin/env python3
"""向 FnDepot 索引里「上架」一个新应用（只写应用级元数据，不写版本）。

为什么必须单独有这一步：
    发布流水线只做 `.apps[K].releases[V] = {...}`。如果 K 还不存在，jq 会
    建出一个**只含 releases 的空壳**，缺 display_name / categories / platform
    / icon_url / run_as / install_type / is_docker 中的任何一个，
    客户端就会**静默跳过该应用**（索引看起来完全正常）。所以先上架、再发版。

三个作者（规范：FnFactory/specs/authorship.md）：
    开发者  maintainer       = bekafka（自建应用） / 上游打包者（第三方收录）
    发布者  distributor      = bekafka / https://github.com/bekafka/FnDepot（本源固定）
    源作者  source_author    = 上游项目最初的创造者与权利源头（必填，不是打包者）

用法（默认 dry-run，加 --write 才落盘）：
    python3 tools/add-app.py \
        --key Motrix \
        --display-name "Motrix" \
        --desc "一句话描述" \
        --categories 系统工具 \
        --platform x86 arm \
        --repo bekafka/FnDepot \
        --source-author agalwood \
        --source-author-url https://github.com/agalwood/Motrix \
        --run-as package \
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
# 源作者：上游项目主页，必须是 https://github.com/<owner>/<repo>（不带子路径）
SOURCE_URL_RE = re.compile(r"^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$")

AUTHOR_FIELDS = ("maintainer", "maintainer_url", "distributor", "distributor_url",
                 "source_author", "source_author_url")


def load_json(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
        return json.load(fh)


def parse_manifest(path):
    """读 fnOS manifest 的键值（够校验作者字段即可）。"""
    fields = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            val = val.strip()
            if len(val) >= 2 and val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            fields[key.strip()] = val
    return fields


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True,
                    help="应用键名，必须逐字等于包内 manifest 的 appname")
    ap.add_argument("--display-name", required=True)
    ap.add_argument("--desc", required=True)
    ap.add_argument("--categories", required=True, nargs="+")
    ap.add_argument("--platform", required=True, nargs="+", choices=["x86", "arm", "all"])
    ap.add_argument("--repo", required=True,
                    help="承载 Release 的仓库 owner/repo：自建应用填 bekafka/FnDepot，"
                         "第三方收录填上游打包仓库（决定开发者身份与主页）")
    ap.add_argument("--source-author", required=True,
                    help="源作者：上游项目最初的创造者/组织（GitHub owner，例：agalwood）")
    ap.add_argument("--source-author-url", required=True,
                    help="源作者项目主页：https://github.com/<owner>/<repo>（不带 /releases）")
    ap.add_argument("--run-as", default="package", choices=["package", "root"])
    ap.add_argument("--install-type", default="",
                    help='"" = 存储空间（默认）；"root" = 系统空间，需物证（cmd/install_callback 碰 /boot 或注册 systemd）')
    ap.add_argument("--is-docker", action="store_true")
    ap.add_argument("--icon", default=DEFAULT_ICON,
                    help=f"本地相对路径（默认 {DEFAULT_ICON}）或绝对 https 地址")
    ap.add_argument("--service-port", default=None)
    ap.add_argument("--readme", action="store_true",
                    help="额外写 readme_url：自建应用指向 assets/<App>/README.md，"
                         "第三方收录走 jsDelivr CDN")
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

    # ── 源作者：必须是上游项目主页，且 owner 与 --source-author 一致 ──────────
    src_url = args.source_author_url.strip().rstrip("/")
    m = SOURCE_URL_RE.match(src_url)
    if not m:
        sys.exit("--source-author-url 必须是上游项目主页 https://github.com/<owner>/<repo>"
                 "（不带 /releases、/tree、/issues 等子路径）")
    url_owner, url_repo = m.group(1), m.group(2)
    if args.source_author.strip() != url_owner:
        sys.exit(f"--source-author（{args.source_author!r}）与项目页 owner（{url_owner!r}）不一致；"
                 "源作者一律取上游 GitHub owner")
    source_author, source_author_url = url_owner, f"https://github.com/{url_owner}/{url_repo}"

    # ── 开发者 / 发布者 ────────────────────────────────────────────────────
    # 自建应用：开发者 = bekafka，主页就是本仓库 https://github.com/bekafka/FnDepot；
    # 第三方收录：开发者 = 上游打包者 + 项目页（沿用 fndepot 口径）。
    owner = args.repo.split("/")[0]
    maintainer = owner
    maintainer_url = f"https://github.com/{args.repo}"

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
        "maintainer": maintainer,
        "maintainer_url": maintainer_url,
        "source_author": source_author,
        "source_author_url": source_author_url,
        "releases": {},
    }

    # 自建应用：索引必须与 apps/<App>/package/manifest 的作者字段逐字一致
    pkg_manifest = os.path.join(ROOT, "apps", args.key, "package", "manifest")
    if owner == DISTRIBUTOR and os.path.isfile(pkg_manifest):
        mf = parse_manifest(pkg_manifest)
        diff = [(f, node[f], mf.get(f)) for f in AUTHOR_FIELDS if mf.get(f) != node[f]]
        if diff:
            sys.exit("索引与 apps/%s/package/manifest 的作者字段不一致（specs/authorship.md）：\n"
                     % args.key
                     + "\n".join(f"  {f}: 索引={a!r} manifest={b!r}" for f, a, b in diff))

    if args.service_port:
        node["service_port"] = args.service_port
    if args.readme:
        if owner == DISTRIBUTOR:
            rel = f"assets/{args.key}/README.md"
            if not os.path.isfile(os.path.join(ROOT, rel)):
                sys.exit(f"--readme：自建应用的应用页应放在 {rel}（先写应用页，再上架）")
            node["readme_url"] = rel
        else:
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
    print("\nREADME 应用列表「原作者」列（verify.py 会校验链接与索引一致）：")
    print(f"  [{source_author}/{url_repo}]({source_author_url})")
    print("\n下一步：")
    print("  1) python3 tools/verify.py --no-net     # 会报『没有 releases』，这是预期的")
    print("  2) 触发应用的发布流水线，让它写入第一个版本节点")
    print("  3) 再跑一次 verify.py，应当通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
