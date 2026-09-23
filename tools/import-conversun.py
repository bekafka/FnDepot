#!/usr/bin/env python3
"""把 conversun/fnos-apps 的 apps.json 批量转换成 FnDepot 条目。

用户定的口径（这批导入专用，2026-09）：
  · 不下载发布包、不逐个爬取：只用他们 apps.json 的字段，下载地址由字段拼出来
  · **不写 sha256/size**（可选字段）——即这批条目没有客户端强校验
  · `run_as` 一律 `package`、`install_type` 一律 `""`（不读他们仓库里的 manifest）
  · 图标用他们仓库里的真实图标（`icon_url` 原样搬）
  · **不加进 README 收录表**，README 里只记一条这个合集
  · `maintainer`/`maintainer_url` 仍按本源口径：该合集仓库的 owner

下载地址规律（已用 release 元数据核对过 3 个应用，含 tag 目录名与 file_prefix 不一致的 nginxserver）：
  https://github.com/conversun/fnos-apps/releases/download/<release_tag>/<file_prefix>_<fpk_version>_<arch>.fpk
  例：.../download/1panel/v1.10.34-lts-r8/1panel_1.10.34-lts-r8_arm.fpk
  注意 release_tag 里带斜杠（`1panel/v1.10.34-lts-r8`），且一个 tag 可能同时含多个应用的资产。

用途（用户定的维护规则）：**只在用户明确说"更新 conversun 的应用"时才跑**，
逻辑就是读它这份 apps.json 做差异核对——新增的加进来、有新版本的追加版本节点、字段变了的同步、
没变的报"无变化"。别在其他时候顺手跑，也别去爬别的东西。

用法:
  python3 tools/import-conversun.py                    # dry-run：打印差异核对结果与样例
  python3 tools/import-conversun.py --write            # 应用差异（新增条目 / 追加版本 / 同步字段）
  python3 tools/import-conversun.py --from-file x.json # 用本地已下载的 apps.json（离线）
"""

import argparse
import collections
import json
import os
import re
import sys

import importlib.util

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# add-app.py 文件名带横杠，按路径加载（复用它的 sanity_check 与固定口径常量）
_spec = importlib.util.spec_from_file_location(
    "add_app", os.path.join(os.path.dirname(os.path.abspath(__file__)), "add-app.py"))
add_app = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(add_app)
sanity_check = add_app.sanity_check

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_URL = "https://raw.githubusercontent.com/conversun/fnos-apps/main/apps.json"
REPO = "conversun/fnos-apps"
ARCHES = {"x86": "x86", "arm": "arm"}

# 他们的英文分类 → 本源九个固定分类（依据：逐个看过各分类下的应用，automation 那 11 个全是 *arr 媒体自动化）
CATEGORY_MAP = {
    "system": "系统工具",
    "network": "系统工具",
    "download": "系统工具",
    "browser": "系统工具",
    "store": "系统工具",
    "": "系统工具",
    "media": "影音娱乐",
    "automation": "影音娱乐",
    "content": "生活服务",
    "ai": "AI赋能",
}


def load_source(path):
    if path:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    import urllib.request
    req = urllib.request.Request(SRC_URL, headers={"User-Agent": "fndepot-import"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def is_from_collection(entry):
    """这条目是不是从 conversun 合集导入的（靠下载地址判定）。"""
    for rel in (entry.get("releases") or {}).values():
        for pk in (rel.get("packages") or {}).values():
            if f"github.com/{REPO}/releases/download/" in (pk.get("download_url") or ""):
                return True
    return False


def entry_of(app):
    """apps.json 的一条 → FnDepot 条目。"""
    plats = sorted({ARCHES[p] for p in app.get("platforms") or [] if p in ARCHES},
                   key=lambda x: ("x86", "arm").index(x))
    if not plats:
        return None, "platforms 为空或不认识"
    pkgs = {}
    for arch in plats:
        asset = f"{app['file_prefix']}_{app['fpk_version']}_{arch}.fpk"
        pkgs[arch] = {
            "download_url": f"https://github.com/{REPO}/releases/download/"
                            f"{app['release_tag']}/{asset}",
        }
    ver = app["fpk_version"]
    rel = {"packages": pkgs}
    if app.get("updated_at"):
        rel["updated_at"] = app["updated_at"]
    entry = {
        "display_name": app["display_name"],
        "desc": app["description"] or app["display_name"],
        "platform": plats,
        "categories": [CATEGORY_MAP.get(app.get("category", ""), "系统工具")],
        "icon_url": app["icon_url"],          # 用户定：用他们仓库里的真实图标
        "run_as": "package",                  # 用户定：一律 package
        "install_type": "",                   # 用户定：一律存储空间
        "is_docker": app.get("app_type") == "docker",
        "distributor": "bekafka",
        "distributor_url": "https://github.com/bekafka/FnDepot",
        "maintainer": REPO.split("/")[0],
        "maintainer_url": f"https://github.com/{REPO}",
        "readme_url": "https://cdn.jsdelivr.net/gh/conversun/fnos-apps@latest/README.md",
        "releases": {ver: rel},
    }
    if app.get("service_port"):
        entry["service_port"] = str(app["service_port"])
    return entry, ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-file", default="", help="本地 apps.json（离线用）")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    data = load_source(args.from_file)
    apps = data["apps"]
    print(f"来源 {data.get('source', {}).get('url', SRC_URL)}｜generated_at {data.get('generated_at')}｜{len(apps)} 个应用")

    index_path = os.path.join(ROOT, "fnpack.json")
    with open(index_path, encoding="utf-8") as fh:
        index = json.load(fh)
    existing = index["apps"]

    new_apps, updates, unchanged, conflicts, skipped = {}, {}, [], [], []
    for app in apps:
        key = app["appname"]
        want, why = entry_of(app)
        if want is None:
            skipped.append(f"{key}（{why}）")
            continue
        try:
            sanity_check(key, want, relaxed=True)
        except Exception as exc:  # noqa: BLE001
            skipped.append(f"{key}（{exc}）")
            continue

        cur = existing.get(key)
        if cur is None:
            new_apps[key] = want
            continue
        if not is_from_collection(cur):
            conflicts.append(key)          # 本源手工收录的同名条目，不许被这批覆盖
            continue

        changes = []
        ver = app["fpk_version"]
        if ver not in (cur.get("releases") or {}):
            changes.append(f"新版本 {ver}（已收录 {sorted(cur.get('releases') or {})}）")
        for f in ("display_name", "desc", "platform", "categories", "icon_url",
                  "is_docker", "service_port"):
            if cur.get(f) != want.get(f):
                changes.append(f"{f}: {cur.get(f)!r} → {want.get(f)!r}")
        if changes:
            merged = dict(cur)
            # 版本节点只追加、不替换（旧版本留着回滚）
            merged["releases"] = {**(cur.get("releases") or {}), **want["releases"]}
            for f in ("display_name", "desc", "platform", "categories", "icon_url", "is_docker",
                      "distributor", "distributor_url", "maintainer", "maintainer_url", "readme_url"):
                if f in want:
                    merged[f] = want[f]
            if want.get("service_port"):
                merged["service_port"] = want["service_port"]
            updates[key] = (merged, changes)
        else:
            unchanged.append(key)

    theirs = {a["appname"] for a in apps}
    dropped = [k for k, v in existing.items() if is_from_collection(v) and k not in theirs]

    by_cat = collections.Counter(e["categories"][0] for e in new_apps.values())
    print(f"\n差异核对：新增 {len(new_apps)}｜版本/字段更新 {len(updates)}｜无变化 {len(unchanged)}"
          f"｜撞键跳过 {len(conflicts)}｜转换失败 {len(skipped)}")
    if by_cat:
        print(f"  新增条目的分类分布: {dict(by_cat)}")
    if updates:
        print("  更新的条目:")
        for k, (_, ch) in sorted(updates.items())[:12]:
            print(f"    {k}: {'；'.join(ch)[:140]}")
    if conflicts:
        print(f"  撞键（本源手工收录，保持不动）: {conflicts}")
    if skipped:
        print("  转换失败:")
        for x in skipped:
            print("    -", x)
    if dropped:
        print(f"  他们的 apps.json 里已没有、本源仍保留: {dropped}")

    built = {**new_apps, **{k: v[0] for k, v in updates.items()}}
    if built:
        key = sorted(built)[0]
        print(f"\n样例 {key}:")
        print(json.dumps(built[key], ensure_ascii=False, indent=1))
    else:
        print("\n（没有新增或更新，无需写入）")

    if not args.write:
        print("\n（dry-run；加 --write 才写入 fnpack.json）")
        return 0
    if not built:
        print("\n无变化，未改动 fnpack.json")
        return 0

    for key in sorted(new_apps):
        existing[key] = new_apps[key]
    for key, (merged, _) in updates.items():
        existing[key] = merged
    with open(index_path + ".bak", "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"\n已写入：新增 {len(new_apps)} 个、更新 {len(updates)} 个；fnpack.json 现在共 {len(existing)} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
