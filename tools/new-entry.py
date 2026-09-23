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
  --install-type   安装空间：""=存储空间（默认），root=系统空间（写 /boot、注册 systemd 的应用）。
  --write          直接并入仓库根目录 fnpack.json（会先写 fnpack.json.bak 备份）。
  --local <FPK>    用本地已下载的包，跳过下载（大包或弱网时先用 curl -C - 续传再传进来）。
  --light          不下整包：元数据读仓库里提交的 manifest/config/privilege，size/sha256 读 GitHub
                   官方 digest。前提是仓库版 manifest 的 version 与 release tag 一致，否则报错要求改走下载。
                   走 API 会消耗配额（未认证 60 次/小时，设 GITHUB_TOKEN 可到 5000），结果缓存于 tools/.cache/。
  --refresh        忽略 API 缓存强制重查（上游刚发新版时用）。
  --changelog-max  changelog 截断长度，默认 400 字符，0 表示不截断。

下载会校验 Content-Length，截断即重试，不会把残缺包装进索引。
同一应用重复采集时按版本合并：同版本不同架构并进 packages，发新版则替换旧版本节点。

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
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gh import gh_token  # noqa: E402  （token 查找见 tools/_gh.py）

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VALID_CATEGORIES = [
    "影音娱乐", "系统工具", "编程开发", "AI赋能", "生活服务",
    "智能智控", "教育学习", "游戏地带", "硬件驱动",
]


def download(url, dest, attempts=3):
    """下载并校验完整性——截断的包会算出错误 sha256，必须拦住。"""
    last = None
    for i in range(1, attempts + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "fndepot-source-builder"})
            with urllib.request.urlopen(req, timeout=600) as resp, open(dest, "wb") as fh:
                raw_len = resp.headers.get("Content-Length")
                expected = int(raw_len) if raw_len and raw_len.isdigit() else None
                got = 0
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)
                    got += len(chunk)
            if expected is not None and got != expected:
                raise IOError(f"下载不完整：收到 {got} 字节，Content-Length={expected}")
            return got
        except Exception as exc:  # noqa: BLE001 - 弱网下各种异常都值得重试
            last = exc
            print(f"下载失败（第 {i}/{attempts} 次）：{exc}", file=sys.stderr)
            time.sleep(2)
    sys.exit(f"下载失败，已放弃：{last}")


def parse_manifest_text(raw):
    """manifest 是 'key = value' 文本。"""
    fields = {}
    for line in raw.splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def read_manifest(fp_path):
    """fpk 是 tar.gz：manifest 是 'key = value' 文本，config/privilege 是 JSON。"""
    with tarfile.open(fp_path, "r:gz") as tar:
        raw = tar.extractfile(tar.getmember("manifest")).read().decode("utf-8", "replace")
        fields = parse_manifest_text(raw)
        # 运行身份只写在 config/privilege 里，manifest 查不到
        try:
            priv = json.loads(tar.extractfile(tar.getmember("config/privilege")).read().decode("utf-8"))
            fields["_run_as"] = (priv.get("defaults") or {}).get("run-as", "")
        except (KeyError, ValueError):
            fields["_run_as"] = ""
    return fields


def fetch_text(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": "fndepot-source-builder"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


CACHE_DIR = os.path.join(ROOT, "tools", ".cache")


def gh_json(url, cache_key, refresh=False):
    """GitHub API 未认证只有 60 次/小时（且按出口 IP 算），故带 token 支持 + 本地缓存。"""
    cache_path = os.path.join(CACHE_DIR, cache_key + ".json")
    if not refresh and os.path.exists(cache_path):
        with open(cache_path, encoding="utf-8") as fh:
            return json.load(fh)

    headers = {"User-Agent": "fndepot-source-builder", "Accept": "application/vnd.github+json"}
    token = gh_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            sys.exit("错误：GitHub token 被拒（401 Bad credentials），请检查 .gh_token 是否正确或已过期。")
        if exc.code == 403:
            sys.exit("错误：GitHub API 配额用尽（未认证 60 次/小时，按出口 IP 计）。\n"
                     "  解法一：把 token 放到 .gh_token（或设 GITHUB_TOKEN）→ 5000 次/小时；\n"
                     "  解法二：等配额重置，或改用不耗配额的路径（--local 下载 / 巡检脚本的降级路径）。")
        raise
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cache_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    return data


def api_asset_digest(repo, tag, asset, refresh=False):
    """GitHub 在上传时就算好 sha256 digest，无需下载整包即可拿到哈希与大小。"""
    data = gh_json(f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
                   f"release__{repo.replace('/', '__')}__{tag}", refresh)
    for item in data.get("assets", []):
        if item.get("name") == asset:
            digest = item.get("digest") or ""
            sha = digest.split(":", 1)[1] if digest.startswith("sha256:") else None
            return item.get("size"), sha, data.get("published_at")
    names = ", ".join(a.get("name", "?") for a in data.get("assets", [])) or "（无资产）"
    sys.exit(f"错误：release {tag} 里没有资产 {asset}；实际有：{names}")


def light_metadata(repo, tag, refresh=False):
    """不下整包：从仓库已提交的 manifest / config/privilege 读元数据（几 KB）。
    必须要求仓库版 manifest 的 version 与 release tag 一致，否则视为版本错位、拒绝使用。"""
    norm = tag.lstrip("vV")
    tree = gh_json(f"https://api.github.com/repos/{repo}/git/trees/HEAD?recursive=1",
                   f"tree__{repo.replace('/', '__')}", refresh)
    blobs = {t["path"] for t in tree.get("tree", []) if t.get("type") == "blob"}
    candidates = sorted(p for p in blobs if p == "manifest" or p.endswith("/manifest"))
    if not candidates:
        sys.exit(f"错误：{repo} 仓库里没有提交 manifest，请改用常规下载模式")

    for path in candidates:
        raw = fetch_text(f"https://raw.githubusercontent.com/{repo}/HEAD/{path}")
        fields = parse_manifest_text(raw)
        if (fields.get("version") or "").lstrip("vV") == norm:
            base = path.rsplit("/", 1)[0] if "/" in path else ""
            priv_path = f"{base}/config/privilege" if base else "config/privilege"
            if priv_path in blobs:
                priv = json.loads(fetch_text(f"https://raw.githubusercontent.com/{repo}/HEAD/{priv_path}"))
                fields["_run_as"] = (priv.get("defaults") or {}).get("run-as", "")
            print(f"轻量模式：仓库版 {path} 的 version={fields.get('version')} 与 tag {tag} 一致", file=sys.stderr)
            return fields

    found = ", ".join(candidates)
    sys.exit(f"错误：{repo} 仓库里的 manifest（{found}）版本与 tag {tag} 不一致；"
             f"仓库文件可能落后于发布，请改用常规下载模式")


def strip_html(text):
    """changelog 纯文本化：客户端对 changelog 是否渲染 HTML 无明确规定，纯文本最稳。
    容忍上游写残的实体（如缺分号的 &gt）。"""
    entities = {"nbsp": " ", "gt": ">", "lt": "<", "quot": '"', "amp": "&", "#39": "'"}
    text = re.sub(r"<br\s*/?>", "\n", text or "", flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"&(#39|nbsp|gt|lt|quot|amp);?", lambda m: entities[m.group(1)], text)
    return re.sub(r"[ \t]+", " ", text).strip()


def truncate(text, limit):
    text = (text or "").strip()
    if limit and len(text) > limit:
        cut = text[:limit]
        # 不要切在 HTML 实体或标签中间
        amp = cut.rfind("&")
        if amp != -1 and ";" not in cut[amp:]:
            cut = cut[:amp]
        lt = cut.rfind("<")
        if lt != -1 and ">" not in cut[lt:]:
            cut = cut[:lt]
        return cut.rstrip() + "…"
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
        "icon_url": "assets/icons/fnapp.png",  # 统一图标，见 README
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
        rel["changelog"] = truncate(strip_html(fields["changelog"]), changelog_max)
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
    ap.add_argument("--local", metavar="FPK路径",
                    help="用本地已下载的包（跳过下载；大包或弱网时先用 curl -C - 续传）")
    ap.add_argument("--light", action="store_true",
                    help="不下整包：元数据取自仓库已提交的 manifest/config/privilege，"
                         "size/sha256 取自 GitHub 官方 digest（要求仓库版版本与 tag 一致）")
    ap.add_argument("--refresh", action="store_true", help="忽略本地 API 缓存，强制重新查询 GitHub")
    ap.add_argument("--changelog-max", type=int, default=400)
    args = ap.parse_args()

    categories = [c.strip() for c in args.categories.split(",") if c.strip()]
    bad = [c for c in categories if c not in VALID_CATEGORIES]
    if bad:
        sys.exit(f"错误：分类 {bad} 不在固定分类表内：{'、'.join(VALID_CATEGORIES)}")

    url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{args.asset}"

    def measure(fp_path):
        return os.path.getsize(fp_path), hashlib.sha256(open(fp_path, "rb").read()).hexdigest()

    published_at = None
    if args.light:
        fields = light_metadata(args.repo, args.tag, args.refresh)
        size, sha256, published_at = api_asset_digest(args.repo, args.tag, args.asset, args.refresh)
        if not sha256:
            sys.exit("错误：该资产没有 sha256 digest（可能是较早上传的），请改用常规下载模式")
        print(f"轻量模式：size 与 sha256 取自 GitHub 官方 digest（{size}B / {sha256[:12]}…），未下载整包",
              file=sys.stderr)
    elif args.local:
        fp_path = args.local
        if not os.path.isfile(fp_path):
            sys.exit(f"错误：本地包不存在 {fp_path}")
        print(f"使用本地包 {fp_path}（下载地址仍记为 {url}）", file=sys.stderr)
        size, sha256 = measure(fp_path)
        fields = read_manifest(fp_path)
    else:
        print(f"下载 {url}", file=sys.stderr)
        with tempfile.TemporaryDirectory() as tmp:
            fp_path = os.path.join(tmp, "pkg.fpk")
            download(url, fp_path)
            size, sha256 = measure(fp_path)
            fields = read_manifest(fp_path)

    appname, entry = build_entry(fields, sha256, size, url, categories, args.changelog_max, args.install_type)
    version = list(entry["releases"])[0]
    if published_at:
        entry["releases"][version]["updated_at"] = published_at
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

    apps = index.setdefault("apps", {})
    old = apps.get(appname)
    if old:
        # 人工维护的字段以仓库现有为准，避免再次采集时被冲掉
        for key in ("icon_url", "maintainer_url", "bug_report_url"):
            if old.get(key):
                entry[key] = old[key]
        # --install-type 未显式给出时，沿用现有条目的安装空间，防止退回“存储空间”
        if not args.install_type and old.get("install_type"):
            entry["install_type"] = old["install_type"]

        old_rel = old.get("releases", {}).get(version, {})
        if old_rel:
            # 同版本的另一个架构：并进 packages，platform 取并集
            pkgs = dict(old_rel.get("packages", {}))
            pkgs.update(entry["releases"][version]["packages"])
            entry["releases"][version]["packages"] = pkgs
            plats = set(old.get("platform", [])) | set(entry["platform"])
            entry["platform"] = [p for p in ("x86", "arm", "all") if p in plats]
            print(f"合并架构：{appname} {version} 现有 branches = {sorted(pkgs)}", file=sys.stderr)
        else:
            # 跟版：追加新版本（自首次收录起累积，不回溯补历史）
            kept = list(old.get("releases", {}))
            if kept:
                print(f"跟版：新增 {version}，保留已收录版本 {kept}", file=sys.stderr)
        # 无论同版本合并还是跟版，都保留已收录过的版本节点
        entry["releases"] = {**old.get("releases", {}), **entry["releases"]}

    apps[appname] = entry
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"已写入 {index_path}（应用 {appname}）", file=sys.stderr)


if __name__ == "__main__":
    main()
