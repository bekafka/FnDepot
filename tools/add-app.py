#!/usr/bin/env python3
"""丢一个仓库链接，自动收录成 V2 条目（全程不下载安装包）。

按约定执行：
  · 只填「必填项」；非必填项只在仓库 manifest 里免费拿得到时才带上
  · icon_url 统一为 assets/icons/fnapp.png
  · download_url / sha256 / size 全部由脚本从上游 release 取（不手写）
  · 元数据优先读作者仓库里提交的 manifest / config/privilege（版本与 tag 一致才用），
    读不到就退回 README + 资产名推导，并在输出里标出哪些字段是猜的

用法:
  python3 tools/add-app.py <仓库链接> [-c 分类] [--arch arm|x86|all] [--write]
  python3 tools/add-app.py https://github.com/Contribuv/fn-hosts -c 系统工具 --write

不加 --write 只打印将要写入的条目（dry-run）。
"""

import argparse
import html
import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gh import gh_token  # noqa: E402  （token 查找见 tools/_gh.py）

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ICON = "assets/icons/fnapp.png"
VALID_CATEGORIES = ["影音娱乐", "系统工具", "编程开发", "AI赋能", "生活服务",
                    "智能智控", "教育学习", "游戏地带", "硬件驱动"]
MANIFEST_CANDIDATES = ["manifest", "fpk/manifest", "package/manifest", "src/manifest",
                       "app/manifest", "build/manifest", "fnos/manifest", "fpk/fnos/manifest",
                       "fnpack/manifest", "packaging/manifest"]


def http(url, method="GET", timeout=50):
    headers = {"User-Agent": "Mozilla/5.0 fndepot-add"}
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
        if exc.code == 401:
            print("  ！GitHub token 被拒（401），将退回不耗配额的路径", file=sys.stderr)
        return None
    except Exception:
        return None


def strip_md(text):
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("`", "").replace("**", "").replace("*", "")
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def first_prose(readme):
    for block in re.split(r"\n\s*\n", readme or ""):
        line = block.strip()
        if not line or line[0] in "#>|<-*" or line.startswith("[![") or line.startswith("```") \
                or re.match(r"^\|", line) or "http" in line[:40]:
            continue
        clean = strip_md(line)
        if len(clean) >= 24:
            return clean[:400]
    return ""


def parse_manifest(txt):
    fields = {}
    for line in txt.splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, _, v = line.partition("=")
            fields[k.strip()] = v.strip().strip('"')
    return fields


def release_info(repo):
    """→ (tag, {资产名: sha256}, {资产名: size}, 来源)"""
    data = http(f"https://api.github.com/repos/{repo}/releases/latest")
    if data:
        try:
            js = json.loads(data)
            if js.get("tag_name") and js.get("assets"):
                return (js["tag_name"],
                        {a["name"]: (a.get("digest") or "").replace("sha256:", "") for a in js["assets"]},
                        {a["name"]: a.get("size") for a in js["assets"]}, "api")
        except ValueError:
            pass
    atom = http(f"https://github.com/{repo}/releases.atom")
    if not atom:
        return None, {}, {}, "取不到 releases（网络/代理？）"
    tags = re.findall(r"releases/tag/([^\"<]+)", atom)
    if not tags:
        return None, {}, {}, "该仓库没有 release"
    tag = tags[0]
    page = http(f"https://github.com/{repo}/releases/expanded_assets/{tag}") or ""
    toks = re.findall(r"releases/download/[^\"]+/([^\"?#]+)|\b(sha256:[0-9a-f]{64})\b", page)
    digests, cur = {}, None
    for name, dig in toks:
        if name:
            cur = name
        elif dig and cur:
            digests[cur] = dig.split(":", 1)[1]
            cur = None
    return tag, digests, {}, "html"


def repo_metadata(repo, tag, appname_hint):
    """读仓库里提交的 manifest / config/privilege；版本必须与 tag 一致。"""
    names = [n for n in {appname_hint, appname_hint.replace("-", "_"),
                         appname_hint.replace("_", "-")} if n]
    cands = list(MANIFEST_CANDIDATES)
    for n in names:
        cands += [f"{n}/manifest", f"fpk/{n}/manifest"]
    for path in cands:
        txt = http(f"https://raw.githubusercontent.com/{repo}/HEAD/{path}")
        if not txt or "appname" not in txt:
            continue
        fields = parse_manifest(txt)
        if (fields.get("version") or "").lstrip("vV") != tag.lstrip("vV"):
            print(f"  · 仓库内 {path} 的版本 {fields.get('version')} 与 tag {tag} 不一致，跳过它",
                  file=sys.stderr)
            continue
        base = path.rsplit("/", 1)[0] if "/" in path else ""
        priv = http(f"https://raw.githubusercontent.com/{repo}/HEAD/"
                    f"{base + '/' if base else ''}config/privilege")
        if priv and "run-as" in priv:
            m = re.search(r'"run-as"\s*:\s*"([^"]+)"', priv)
            if m:
                fields["_run_as"] = m.group(1)
        print(f"  · 元数据来自仓库内 {path}（作者真值）", file=sys.stderr)
        return fields
    return {}


def classify_asset(name):
    low = name.lower()
    if re.search(r"[-_.](arm|arm64|aarch64)", low):
        return "arm"
    if re.search(r"[-_.](x86|x86_64|amd64)", low):
        return "x86"
    return "all"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", help="仓库链接或 owner/repo")
    ap.add_argument("-c", "--categories", default="系统工具")
    ap.add_argument("--arch", choices=["auto", "arm", "x86", "all"], default="auto")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    m = re.search(r"github\.com/([^/\s]+/[^/\s#?]+)", args.repo)
    repo = (m.group(1) if m else args.repo).removesuffix(".git").strip("/")
    cats = [c.strip() for c in args.categories.split(",") if c.strip()]
    bad = [c for c in cats if c not in VALID_CATEGORIES]
    if bad:
        sys.exit(f"错误：分类 {bad} 不在固定分类表内：{'、'.join(VALID_CATEGORIES)}")

    print(f"仓库 {repo}")
    tag, digests, sizes, src = release_info(repo)
    if not tag:
        sys.exit(f"错误：{src}")
    fpks = [n for n in digests if n.endswith(".fpk")]
    if not fpks:
        sys.exit(f"错误：{tag} 里没有 .fpk 资产，无法收录")
    print(f"  最新 tag {tag}；.fpk 资产：{', '.join(fpks)}（来源 {src}）")

    readme = ""
    for br in ("HEAD", "main", "master"):
        readme = http(f"https://raw.githubusercontent.com/{repo}/{br}/README.md") or ""
        if readme:
            break
    hint = re.sub(r"[-_]?v?\d[\d.]*$", "", fpks[0][:-4])
    fields = repo_metadata(repo, tag, hint)
    if not fields:
        print("  · 仓库未提交可用 manifest → 元数据按 README / 资产名推导（下列字段是猜的）",
              file=sys.stderr)

    appname = fields.get("appname") or hint.replace("_", "-")
    if fields.get("platform"):
        plats = [p.strip() for p in re.split(r"[,\s]+", fields["platform"]) if p.strip()]
        psrc = "作者 manifest"
    elif args.arch != "auto":
        plats, psrc = [args.arch], "--arch 指定"
    elif all(classify_asset(n) != "all" for n in fpks):
        plats, psrc = sorted({classify_asset(n) for n in fpks}), "资产名里的架构标记"
    else:
        plats, psrc = ["all"], "无依据，默认 all（猜）"

    packages = {}
    for name in fpks:
        arch = classify_asset(name)
        if plats == ["all"] or arch in plats or arch == "all":
            url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
            size = sizes.get(name) or http(url, method="HEAD")
            dig = digests.get(name) or ""
            if not dig:
                print(f"  ！{name} 没有官方 digest，跳过（请改用 new-entry.py --local 下载后采集）",
                      file=sys.stderr)
                continue
            packages[arch] = {"download_url": url, "sha256": dig, "size": size}
    if not packages:
        sys.exit("错误：没有可用的安装包分支")

    ver = tag.lstrip("vV")
    entry = {
        "display_name": fields.get("display_name") or (re.search(r"^#\s+(.+)$", readme, re.M).group(1).strip()
                                                       if re.search(r"^#\s+(.+)$", readme, re.M) else appname),
        "desc": strip_md(fields.get("desc") or "") or first_prose(readme) or appname,
        "platform": plats,
        "categories": cats,
        "icon_url": DEFAULT_ICON,
        "run_as": fields.get("_run_as") if fields.get("_run_as") in ("root", "package") else "package",
        "install_type": "",
        "is_docker": fields.get("_is_docker", False),
        "releases": {ver: {"packages": packages}},
    }
    for k, v in (("service_port", fields.get("service_port")),
                 ("maintainer", fields.get("maintainer")),
                 ("maintainer_url", fields.get("maintainer_url"))):
        if v:
            entry[k] = v
    entry.setdefault("maintainer_url", f"https://github.com/{repo}")
    if fields.get("changelog"):
        cl = re.sub(r"<br\s*/?>", " ", fields["changelog"])
        entry["releases"][ver]["changelog"] = strip_md(cl)[:400]
    if fields.get("os_min_version") or fields.get("os_min_ver"):
        entry["releases"][ver]["os_min_version"] = fields.get("os_min_version") or fields.get("os_min_ver")

    print(f"  appname={appname} | platform={plats}（{psrc}） | run_as={entry['run_as']} | "
          f"包={list(packages)} | size={[p['size'] for p in packages.values()]}")
    print()
    print(f'"{appname}": ' + json.dumps(entry, ensure_ascii=False, indent=2))

    if not args.write:
        print("\n（dry-run；加 --write 才会写入 fnpack.json）")
        return

    path = os.path.join(ROOT, "fnpack.json")
    with open(path, encoding="utf-8") as fh:
        index = json.load(fh)
    with open(path + ".bak", "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
    old = index["apps"].get(appname)
    if old:
        for k in ("icon_url",):
            entry[k] = old.get(k, entry[k])
        if old.get("install_type"):
            entry["install_type"] = old["install_type"]
        old_versions = old.get("releases", {})
        if ver in old_versions:
            packages = {**old_versions[ver].get("packages", {}), **packages}
            entry["releases"][ver]["packages"] = packages
            plats = sorted(set(old.get("platform", [])) | set(plats))
            entry["platform"] = [p for p in ("x86", "arm", "all") if p in plats]
            print(f"  · 同版本合并架构：{sorted(packages)}", file=sys.stderr)
        elif old_versions:
            print(f"  · 跟版：新增 {ver}，保留已收录版本 {sorted(old_versions)}", file=sys.stderr)
        # 无论同版本合并还是跟版，都保留已收录过的版本节点
        entry["releases"] = {**old_versions, **entry["releases"]}
    index["apps"][appname] = entry
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"\n已写入 fnpack.json（应用 {appname}）")


if __name__ == "__main__":
    main()
