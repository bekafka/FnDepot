#!/usr/bin/env python3
"""丢一个仓库链接，自动收录成 V2 条目（全程不下载安装包）。

性能设计（v2）：
  · 一次 `git/trees?recursive=1` 拿到仓库全部路径，据此定位 manifest 与 config/privilege。
    旧版按 10 个固定路径盲探、再按猜的 appname 探 6 个，一个应用要发 ~20 个请求（实测 29s），现在 2~3 个。
  · 所有 API / 文件响应缓存到 tools/.cache（`--refresh` 强制重查），重复跑同一仓库近乎零网络。
  · 支持一次给多个仓库或 `--batch` 文件：抓取并发（`--jobs`，默认 4），写入串行合并。

字段来源（关键规则）：
  · `version` / `changelog` 只认 release tag；
  · `appname` / `platform` / `install_type` / `run_as` / `display_name` / `desc` / `service_port` /
    `os_min_version` 认仓库里提交的 manifest 与 config/privilege —— **manifest 版本与 tag 不一致也照用**，
    只打印告警。旧版「版本不一致就整体退回按文件名猜」是错的：作者常常先改仓库后发版（或发版后忘了同步仓库），
    那样会把 appname 猜错——曾把 ignis 猜成 obsidian，键名与包内 appname 不符，客户端直接装不上。
  · 都拿不到才退回 README + 资产名推导，并明确标出哪些字段是猜的。

用法:
  python3 tools/add-app.py <仓库链接> [-c 分类] [--arch arm|x86|all] [--asset 资产名] [--write] [--refresh]
  python3 tools/add-app.py <链接1> <链接2> ... -c 系统工具 --write    # 并发抓取，一次收录多个
  python3 tools/add-app.py --batch repos.txt -c 系统工具 --write      # 每行一个链接，可写成 "链接 分类"

不加 --write 只打印将要写入的条目（dry-run）。
"""

import argparse
import base64
import concurrent.futures
import html
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gh import gh_token  # noqa: E402  （token 查找见 tools/_gh.py）

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ICON = "assets/icons/fnapp.png"
# 固定口径（用户定死）：distributor 永远是本源；maintainer 是上游项目 owner（与项目页一一对应）
DISTRIBUTOR = "bekafka"
DISTRIBUTOR_URL = "https://github.com/bekafka/FnDepot"
CACHE_DIR = os.path.join(ROOT, "tools", ".cache")
VALID_CATEGORIES = ["影音娱乐", "系统工具", "编程开发", "AI赋能", "生活服务",
                    "智能智控", "教育学习", "游戏地带", "硬件驱动"]
TIMEOUT = 20
UA = "Mozilla/5.0 fndepot-add"
_print_lock = threading.Lock()


def say(msg, err=False):
    with _print_lock:
        print(msg, file=sys.stderr if err else sys.stdout)


# ---------------------------------------------------------------- 网络层（带缓存）

def _cache_path(key):
    return os.path.join(CACHE_DIR, key)


def _save(key, text):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(_cache_path(key), "w", encoding="utf-8") as fh:
        fh.write(text)


def api_json(url, cache_key, refresh=False):
    """带缓存的 GitHub API GET。404/失败 → None（404 会负缓存，避免反复探不存在的东西）。"""
    path = _cache_path(cache_key + ".json")
    if not refresh and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except ValueError:
            pass
    headers = {"User-Agent": UA, "Accept": "application/vnd.github+json"}
    token = gh_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            say("  ！GitHub token 被拒（401）：检查 $DSH_HOME/.env 里的 GITHUB_TOKEN", err=True)
        elif exc.code == 403:
            say("  ！GitHub API 配额用尽（403）：等配额重置，或配 token（5000 次/小时）", err=True)
        if exc.code == 404:
            with _print_lock:
                try:
                    _save(cache_key + ".json", "null")
                except OSError:
                    pass
        return None
    except Exception:
        return None
    _save(cache_key + ".json", json.dumps(data))
    return data


def _slug(text):
    return re.sub(r"[^A-Za-z0-9._-]", "_", text)


def fetch_text(repo, path, ref="HEAD", refresh=False):
    """读仓库里的文本文件：raw 优先（快），失败退回 API contents（带 token，直连更稳）。带缓存。

    确定 404 会负缓存（写空文件），免得每次都为不存在的路径重试。
    """
    key = "file__%s__%s" % (repo.replace("/", "__"), _slug(ref + "__" + path))
    cp = _cache_path(key)
    if not refresh and os.path.exists(cp):
        with open(cp, encoding="utf-8") as fh:
            return fh.read() or None
    txt, definitive_404 = None, False
    try:
        req = urllib.request.Request(f"https://raw.githubusercontent.com/{repo}/{ref}/{path}",
                                     headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            txt = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        definitive_404 = exc.code == 404
    except Exception:
        pass
    if txt is None and not definitive_404:
        data = api_json(f"https://api.github.com/repos/{repo}/contents/{path}?ref={ref}",
                        "contents__%s__%s" % (repo.replace("/", "__"), _slug(ref + "__" + path)), refresh)
        if isinstance(data, dict) and data.get("content"):
            txt = base64.b64decode(data["content"]).decode("utf-8", "replace")
        elif isinstance(data, dict) and data.get("sha"):
            pass
        else:
            definitive_404 = True
    if txt is not None:
        _save(key, txt)
    elif definitive_404:
        _save(key, "")          # 负缓存
    return txt


def repo_paths(repo, refresh=False):
    """仓库里全部 blob 路径（一次调用）。缓存键与 new-entry.py 共用。"""
    data = api_json(f"https://api.github.com/repos/{repo}/git/trees/HEAD?recursive=1",
                    f"tree__{repo.replace('/', '__')}", refresh)
    if not isinstance(data, dict):
        return None
    return [x["path"] for x in data.get("tree", []) if x.get("type") == "blob"]


def release_info(repo, refresh=False):
    """→ (tag, {资产名: sha256}, {资产名: size}, 来源)"""
    js = api_json(f"https://api.github.com/repos/{repo}/releases/latest",
                  f"release_latest__{repo.replace('/', '__')}", refresh)
    if isinstance(js, dict) and js.get("tag_name") and js.get("assets"):
        return (js["tag_name"],
                {a["name"]: (a.get("digest") or "").replace("sha256:", "") for a in js["assets"]},
                {a["name"]: a.get("size") for a in js["assets"]}, "api")
    # 降级：不耗配额（releases.atom 取 tag，release 页面取 digest）
    try:
        req = urllib.request.Request(f"https://github.com/{repo}/releases.atom", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            atom = resp.read().decode("utf-8", "replace")
    except Exception:
        return None, {}, {}, "取不到 releases（网络/代理？）"
    tags = re.findall(r"releases/tag/([^\"<]+)", atom)
    if not tags:
        return None, {}, {}, "该仓库没有 release"
    tag = tags[0]
    key = "assets_html__%s__%s" % (repo.replace("/", "__"), _slug(tag))
    page = None
    cp = _cache_path(key)
    if not refresh and os.path.exists(cp):
        with open(cp, encoding="utf-8") as fh:
            page = fh.read()
    if page is None:
        try:
            req = urllib.request.Request(f"https://github.com/{repo}/releases/expanded_assets/{tag}",
                                         headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                page = resp.read().decode("utf-8", "replace")
            _save(key, page)
        except Exception:
            page = ""
    toks = re.findall(r"releases/download/[^\"]+/([^\"?#]+)|\b(sha256:[0-9a-f]{64})\b", page)
    digests, cur = {}, None
    for name, dig in toks:
        if name:
            cur = name
        elif dig and cur:
            digests[cur] = dig.split(":", 1)[1]
            cur = None
    return tag, digests, {}, "html"


# ---------------------------------------------------------------- manifest

def find_readme(paths):
    """→ 仓库里 README 主文件的路径（优先根目录 README.md）。找不到返回 None。"""
    cands = [p for p in (paths or []) if re.fullmatch(r"(?:.*/)?readme[^/]*", p, re.I)]
    if not cands:
        return None
    return sorted(cands, key=lambda p: (p.lower() != "readme.md", p.count("/"), len(p)))[0]


def readme_cdn_url(repo, path, ref="latest"):
    """readme_url 一律用 jsDelivr CDN（用户定死：不要 GitHub 原始地址），ref 用 latest。

    比 blob/raw 原始地址好在：带 CORS 头、国内可达，客户端可直接抓正文渲染。
    latest 由 jsDelivr 解析成仓库最新的 semver tag（没有 tag 时退回默认分支）。
    """
    return f"https://cdn.jsdelivr.net/gh/{repo}@{ref}/{path}"


def cdn_ok(url, attempts=2):
    """探测 jsDelivr 地址是否真的可取到。

    jsDelivr 对单个版本有 50MB 上限、且仓库某版本可能压根没有 README，
    这两种情况都会返回 403/404——此时宁可不写 readme_url，也不要留一个死链
    （用户定的口径是"必须走 CDN"，所以不退回 GitHub 原始地址）。
    """
    for i in range(attempts):
        try:
            req = urllib.request.Request(urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%~"),
                                         method="HEAD", headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.status == 200, ""
        except urllib.error.HTTPError as exc:
            if exc.code in (403, 404):
                return False, f"HTTP {exc.code}"
        except Exception as exc:  # noqa: BLE001
            last = type(exc).__name__
        if i == 0:
            time.sleep(1.0)
    return False, "网络查询失败"


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
    """fnOS manifest：`key = value`；续行（不含 =）并入上一个键（desc 可能跨多行）。"""
    fields, last = {}, None
    for raw in (txt or "").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if "=" in raw:
            k, _, v = raw.partition("=")
            k = k.strip()
            if not k or " " in k:
                continue
            last = k
            fields[k] = v.strip().strip('"')
        elif last:
            fields[last] = (fields[last] + "<br>" + raw.strip())
    return fields


def norm_app(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def asset_hint(name):
    """从资产名推 appname 候选（去掉架构标记与版本尾巴）。只用于给 manifest 打分，不直接当键名。"""
    s = name[:-4] if name.lower().endswith(".fpk") else name
    s = re.sub(r"[-_.]?(aarch64|arm64|arm|x86_64|amd64|x86|i686|all)\b", "", s, flags=re.I)
    s = re.sub(r"[-_.]?v?\d[\d.]*(?:[-_.]?(?:beta|alpha|rc)\.?\d*)?$", "", s, flags=re.I)
    return re.sub(r"[-_.]+$", "", s)


def pick_manifest(repo, tag, paths, hints, refresh):
    """→ (path, fields, drift, 其它候选)
    优先 version 与 tag 一致的那份；都不一致时按 appname 与资产名的吻合度挑一份（drift=True）。"""
    cands = [p for p in paths if p == "manifest" or p.endswith("/manifest")]
    scored = []
    for p in cands:
        txt = fetch_text(repo, p, "HEAD", refresh)
        if not txt or "appname" not in txt:
            continue
        f = parse_manifest(txt)
        if not f.get("appname"):
            continue
        exact = (f.get("version") or "").lstrip("vV") == tag.lstrip("vV")
        na = norm_app(f["appname"])
        hit = max([3 if norm_app(h) == na else (2 if norm_app(h) and (na in norm_app(h) or norm_app(h).endswith(na)) else 0)
                   for h in hints] or [0])
        scored.append(((2 if exact else 0) + hit, len(p), p, f, exact))
    if not scored:
        return None, {}, False, []
    scored.sort(key=lambda x: (-x[0], x[1]))
    _, _, path, fields, exact = scored[0]
    return path, fields, (not exact), [p for _, _, p, _, _ in scored[1:]]


def read_privilege(repo, manifest_path, paths, refresh):
    """→ (run_as 或 None, 说明)"""
    base = manifest_path.rsplit("/", 1)[0] if "/" in manifest_path else ""
    cand = (base + "/config/privilege") if base else "config/privilege"
    if cand not in paths:
        return None, f"仓库里没有 {cand}"
    txt = fetch_text(repo, cand, "HEAD", refresh)
    if txt is None:
        return None, f"{cand} 存在但取不到内容（网络/代理？）——run_as 只能默认 package，请复核"
    m = re.search(r'"run-as"\s*:\s*"([^"]+)"', txt)
    return (m.group(1) if m else None), cand


# ---------------------------------------------------------------- 架构判定

def classify_asset(name):
    low = name.lower()
    if re.search(r"[-_.](aarch64|arm64|arm)", low):
        return "arm"
    if re.search(r"[-_.](x86_64|amd64|x86|i686)", low):
        return "x86"
    return "all"


def map_declared(value):
    v = (value or "").strip().lower()
    if v in ("x86", "x86_64", "amd64", "i686"):
        return "x86"
    if v in ("arm", "arm64", "aarch64"):
        return "arm"
    if v == "all":
        return "all"
    return ""


def package_key(name, plats):
    """资产名 → packages 里的键。

    资产名不带架构标记时（如 fpkconverter.fpk），若 manifest 只声明了一个具体架构，就用那个架构，
    否则单架构应用的包键会落成 "all" 与 platform 自相矛盾。
    """
    if plats == ["all"]:
        return "all"
    arch = classify_asset(name)
    if arch == "all":
        concrete = [p for p in plats if p != "all"]
        if len(concrete) == 1:
            return concrete[0]
        return "all" if "all" in plats else None
    return arch if arch in plats else None


def prefer_asset(new, old):
    """同架构多个包（如 -iframe / -url）时优先 iframe（内嵌桌面），其次无后缀，最后 url。"""
    def rank(n):
        low = n.lower()
        if "iframe" in low:
            return 0
        if "url" in low:
            return 2
        return 1
    return new if rank(new) < rank(old) else old


def plan_platform(declared, asset_arches, arch_flag, notes):
    """→ platform 列表。manifest 声明与实际发布的架构冲突时取并集并告警。"""
    if arch_flag != "auto":
        return [arch_flag]
    if declared == "all":
        if len(asset_arches) >= 2:
            notes.append(f"manifest 声明 platform=all，但 release 分别发了 "
                         f"{'、'.join(sorted(asset_arches))} 包 → 按资产取各自架构")
            return sorted(asset_arches)
        return ["all"]
    if declared in ("x86", "arm"):
        extra = sorted(a for a in asset_arches if a != declared)
        if extra:
            notes.append(f"manifest 声明 platform={declared}，但本次 release 同时发布了 {'、'.join(extra)} 包 "
                         f"→ platform 取并集（有的仓库 manifest 由打包脚本按架构替换，仓库里那份只是其中一个架构的快照）")
            return sorted({declared} | set(extra))
        return [declared]
    if asset_arches:
        notes.append(f"manifest 未声明 platform/arch，按资产名取 {'、'.join(sorted(asset_arches))}")
        return sorted(asset_arches)
    notes.append("manifest 未声明 platform 且资产名无架构标记 → 填 all（猜）")
    return ["all"]


# ---------------------------------------------------------------- 组条目

def build_entry(repo, cats, arch_flag, asset_flag, refresh):
    """→ (appname, entry, ver, notes, truth)。truth=True 表示元数据来自仓库 manifest（作者真值）。不写盘。"""
    notes = []
    tag, digests, sizes, src = release_info(repo, refresh)
    if not tag:
        raise RuntimeError(src)
    fpks = [n for n in digests if n.lower().endswith(".fpk")]
    if not fpks:
        raise RuntimeError(f"{tag} 里没有 .fpk 资产，无法收录")

    paths = repo_paths(repo, refresh)
    if paths is None:
        paths = []
        notes.append("取不到仓库文件树（网络/代理？）→ 只能按资产名推导")

    hints = [asset_hint(n) for n in fpks]
    mpath, fields, drift, others = pick_manifest(repo, tag, paths, hints, refresh)
    if mpath:
        if drift:
            notes.append(f"仓库内 {mpath} 的 version={fields.get('version')} 与 tag {tag} 不一致"
                         f"（作者先改仓库后发版 / 发版后忘了同步）→ 身份字段仍按它取，version 按 tag")
        if others:
            notes.append(f"仓库里还有其它 manifest（{'、'.join(others)}），用的是 {mpath}")
        say(f"  · 元数据来自仓库内 {mpath}（作者真值）")
    else:
        notes.append("仓库未提交可用 manifest → display_name/desc/appname 按 README 与资产名推导（猜）")

    run_as, priv_src = (None, "")
    if mpath:
        run_as, priv_src = read_privilege(repo, mpath, paths, refresh)
        if run_as is None and priv_src and "默认" in priv_src:
            notes.append(priv_src)
    if run_as not in ("root", "package"):
        if run_as:
            notes.append(f"config/privilege 的 run-as={run_as} 不是 root/package → 按 package 处理")
        run_as = "package"

    # README 主文件：按文件树定位（不猜文件名），拿它当 readme_url 与 desc 的兜底来源
    readme_path = find_readme(paths)
    readme = fetch_text(repo, readme_path, "HEAD", refresh) if readme_path else ""
    if not readme:
        for br in ("HEAD", "main", "master"):
            readme = fetch_text(repo, "README.md", br, refresh) or ""
            if readme:
                readme_path = readme_path or "README.md"
                break

    appname = fields.get("appname") or (hints[0].replace("_", "-") if hints else repo.split("/")[-1])
    declared = map_declared(fields.get("platform")) or map_declared(fields.get("arch"))
    asset_arches = sorted({a for a in (classify_asset(n) for n in fpks) if a != "all"})
    plats = plan_platform(declared, asset_arches, arch_flag, notes)
    plats = [p for p in ("x86", "arm", "all") if p in plats]   # 固定顺序，dry-run 与落盘一致

    # 同 key 多个包时明确挑一个（旧版是 dict 覆盖，静默留下最后一个）
    chosen, dropped = {}, []
    for name in fpks:
        key = package_key(name, plats)
        if not key:
            continue
        if key in chosen:
            winner = prefer_asset(name, chosen[key])
            dropped.append(name if winner == chosen[key] else chosen[key])
            chosen[key] = winner
        else:
            chosen[key] = name
    if asset_flag:
        key = package_key(asset_flag, plats)
        if not key:
            raise RuntimeError(f"--asset {asset_flag} 的架构与 platform {plats} 不匹配")
        if asset_flag in fpks:
            dropped = [v for v in chosen.values() if v != asset_flag] + dropped
            chosen[key] = asset_flag
        else:
            raise RuntimeError(f"--asset {asset_flag} 不在本次 release 的 .fpk 里：{', '.join(fpks)}")
    if dropped:
        notes.append(f"同架构有多个包，选了 {'、'.join(chosen.values())}，未收录 {'、'.join(dropped)}"
                     f"（可用 --asset 指定）")

    packages = {}
    for key, name in chosen.items():
        url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
        size = sizes.get(name)
        if not size:
            size = _head_size(url)
        dig = digests.get(name) or ""
        if not dig:
            notes.append(f"{name} 没有官方 digest → 跳过（请改用 new-entry.py --local 下载后采集）")
            continue
        packages[key] = {"download_url": url, "sha256": dig, "size": size}
    if not packages:
        raise RuntimeError("没有可用的安装包分支")

    ver = tag.lstrip("vV")
    desc = strip_md(fields.get("desc") or "") or first_prose(readme) or appname
    project_url = f"https://github.com/{repo}"
    entry = {
        "display_name": fields.get("display_name") or (_readme_title(readme) or appname),
        "desc": desc[:600] + ("…" if len(desc) > 600 else ""),
        "platform": plats,
        "categories": cats,
        "icon_url": DEFAULT_ICON,
        "run_as": run_as,
        "install_type": "root" if (fields.get("install_type") or "").strip().lower() == "root" else "",
        "is_docker": (fields.get("source") or "").strip().lower() == "docker",
        # 固定口径：distributor 是本源；maintainer 是上游项目作者与项目页；readme_url 指项目 README 主文件
        "distributor": DISTRIBUTOR,
        "distributor_url": DISTRIBUTOR_URL,
        # maintainer 按用户定的口径一律取仓库 owner（不取 manifest 里可能写着上游厂商的 maintainer）
        "maintainer": repo.split("/")[0],
        "maintainer_url": project_url,
        "readme_url": readme_cdn_url(repo, readme_path) if readme_path else "",  # 下面探测，不可达就删掉
        "releases": {ver: {"packages": packages}},
    }
    if not entry["readme_url"]:
        del entry["readme_url"]
        notes.append("取不到 README 路径 → 本次不写 readme_url")
    else:
        ok, why = cdn_ok(entry["readme_url"])
        if not ok:
            notes.append(f"jsDelivr 取不到 README（{why}；常见原因：仓库超 50MB 上限、或该版本没有 README）"
                         f"→ 本次不写 readme_url（不退回首 GitHub 原始地址）")
            del entry["readme_url"]
    if fields.get("service_port"):
        entry["service_port"] = fields["service_port"]
    if fields.get("changelog") and not drift:
        cl = re.sub(r"<br\s*/?>", " ", fields["changelog"])
        entry["releases"][ver]["changelog"] = strip_md(cl)[:400]
    osmin = fields.get("os_min_version") or fields.get("os_min_ver")
    if osmin:
        entry["releases"][ver]["os_min_version"] = osmin

    notes.insert(0, f"tag {tag}；.fpk 资产：{'、'.join(fpks)}（来源 {src}）")
    return appname, entry, ver, notes, (mpath is not None)


def _readme_title(readme):
    m = re.search(r"^#\s+(.+)$", readme or "", re.M)
    return m.group(1).strip() if m else ""


def _head_size(url):
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            cl = resp.headers.get("Content-Length")
            return int(cl) if cl and cl.isdigit() else None
    except Exception:
        return None


# ---------------------------------------------------------------- 落盘（串行）

def job_cats(value, default):
    """批处理行里的分类是字符串，必须切成列表——否则会写出 "categories": "系统工具" 这种非法条目。"""
    if not value:
        return list(default)
    return [c.strip() for c in value.split(",") if c.strip()]


def sanity_check(appname, entry, relaxed=False):
    """写盘前的最后一道闸：这几项错了客户端会静默跳过该应用。

    relaxed=True 供批量导入用：那批条目不写 sha256/size（用户定的口径），图标用上游仓库的真实图标。
    其余检查（categories/platform/包键名/地址形状）仍然照旧。
    """
    errs = []
    if not isinstance(entry.get("categories"), list) or not entry["categories"]:
        errs.append(f"categories 必须是数组，现在是 {entry.get('categories')!r}")
    for c in entry.get("categories") or []:
        if c not in VALID_CATEGORIES:
            errs.append(f"分类 {c!r} 不在固定分类表内")
    if not isinstance(entry.get("platform"), list) or not entry["platform"]:
        errs.append(f"platform 必须是数组，现在是 {entry.get('platform')!r}")
    for p in entry.get("platform") or []:
        if p not in ("x86", "arm", "all"):
            errs.append(f"platform 里的 {p!r} 非法")
    if entry.get("run_as") not in ("root", "package"):
        errs.append(f"run_as={entry.get('run_as')!r}")
    if entry.get("install_type") not in ("", "root"):
        errs.append(f"install_type={entry.get('install_type')!r}")
    if not isinstance(entry.get("is_docker"), bool):
        errs.append("is_docker 必须是布尔")
    icon = entry.get("icon_url") or ""
    if icon != DEFAULT_ICON and not (relaxed and icon.startswith("https://")):
        errs.append(f"icon_url 必须是 {DEFAULT_ICON}"
                    + ("（relaxed 模式下也必须是绝对 https 地址）" if relaxed else ""))
    # 固定口径：本源 distributor + 上游项目作者/项目页/README
    if entry.get("distributor") != DISTRIBUTOR or entry.get("distributor_url") != DISTRIBUTOR_URL:
        errs.append(f"distributor 必须是 {DISTRIBUTOR} / {DISTRIBUTOR_URL}，现在是 "
                    f"{entry.get('distributor')!r} / {entry.get('distributor_url')!r}")
    repos = {m.group(1) for m in
             (re.match(r"https://github\.com/([^/]+/[^/]+)/releases/download/", pk.get("download_url") or "")
              for rel in (entry.get("releases") or {}).values()
              for pk in (rel.get("packages") or {}).values()) if m}
    if len(repos) == 1:
        repos_holder = repos.pop()
        project_url = f"https://github.com/{repos_holder}"
        if entry.get("maintainer_url") != project_url:
            errs.append(f"maintainer_url 必须是项目页 {project_url}，现在是 {entry.get('maintainer_url')!r}")
        if not entry.get("maintainer"):
            errs.append("maintainer 不能为空（上游项目作者）")
        ru = entry.get("readme_url")
        if ru and not ru.startswith(f"https://cdn.jsdelivr.net/gh/{repos_holder}@"):
            errs.append(f"readme_url 必须用 jsDelivr CDN 地址，现在是 {ru!r}")
    if not entry.get("releases"):
        errs.append("没有 releases")
    for ver, rel in (entry.get("releases") or {}).items():
        pkgs = rel.get("packages") or {}
        if not pkgs:
            errs.append(f"{ver} 没有 packages")
        for arch, pk in pkgs.items():
            if arch not in ("x86", "arm", "all"):
                errs.append(f"{ver} 包键名 {arch!r} 非法")
            if entry.get("platform") != ["all"] and arch not in entry.get("platform", []):
                errs.append(f"{ver} 包键名 {arch} 不在 platform 里")
            if not re.match(r"^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/.+$",
                            pk.get("download_url") or ""):
                errs.append(f"{ver}/{arch} download_url 不是带 tag 的 release 地址")
            sha = pk.get("sha256")
            if sha is None and relaxed:
                pass                                    # 批量导入不写 sha256（用户定的口径）
            elif not re.fullmatch(r"[0-9a-f]{64}", sha or ""):
                errs.append(f"{ver}/{arch} sha256 不是 64 位十六进制")
            size = pk.get("size")
            if size is None and relaxed:
                pass                                    # 同上，不写 size
            elif not isinstance(size, int) or size <= 0:
                errs.append(f"{ver}/{arch} size 必须是正整数")
    if errs:
        raise RuntimeError(f"{appname} 未通过写盘前自检：{'；'.join(errs)}")


def write_entry(appname, entry, ver, truth=True):
    sanity_check(appname, entry)
    path = os.path.join(ROOT, "fnpack.json")
    with open(path, encoding="utf-8") as fh:
        index = json.load(fh)
    with open(path + ".bak", "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
    old = index["apps"].get(appname)
    if old:
        if not truth:
            # 这次的元数据是猜的（仓库没 manifest）→ 不许覆盖已有条目里人工维护的值。
            # 但固定口径字段（distributor / maintainer_url / readme_url）是算出来的，必须按规则更新。
            derived_plats = entry["platform"]
            kept = []
            for k, v in old.items():
                if k == "releases" or k in ("distributor", "distributor_url", "maintainer_url", "readme_url"):
                    continue
                if v in (None, "", [], {}):
                    continue
                if entry.get(k) != v:
                    kept.append(k)
                entry[k] = v
            if kept:
                say(f"  · 元数据是猜的，保留已有人工值：{'、'.join(sorted(kept))}", err=True)
            keys = sorted(entry["releases"][ver]["packages"])
            if entry["platform"] != ["all"] and any(a not in entry["platform"] for a in keys):
                say(f"  ！保留的 platform {entry['platform']} 容不下包键名 {keys} → 改用推导值 {derived_plats}",
                    err=True)
                entry["platform"] = derived_plats
        entry["icon_url"] = old.get("icon_url", entry["icon_url"])
        if old.get("install_type"):
            entry["install_type"] = old["install_type"]
        old_versions = old.get("releases", {})
        if ver in old_versions:
            merged = {**old_versions[ver].get("packages", {}), **entry["releases"][ver]["packages"]}
            entry["releases"][ver]["packages"] = merged
            plats = sorted(set(old.get("platform", [])) | set(entry["platform"]))
            entry["platform"] = [p for p in ("x86", "arm", "all") if p in plats]
            say(f"  · 同版本合并架构：{sorted(merged)}", err=True)
        elif old_versions:
            say(f"  · 跟版：新增 {ver}，保留已收录版本 {sorted(old_versions)}", err=True)
        entry["releases"] = {**old_versions, **entry["releases"]}
    index["apps"][appname] = entry
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


# ---------------------------------------------------------------- main

def parse_repo(text):
    m = re.search(r"github\.com/([^/\s]+/[^/\s#?]+)", text)
    return (m.group(1) if m else text).removesuffix(".git").strip("/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repos", nargs="*", help="仓库链接或 owner/repo，可给多个")
    ap.add_argument("-c", "--categories", default="系统工具")
    ap.add_argument("--arch", choices=["auto", "arm", "x86", "all"], default="auto")
    ap.add_argument("--asset", default="", help="同架构有多个包时指定资产文件名")
    ap.add_argument("--batch", default="", help="每行一个仓库链接（可写 '链接 分类'）")
    ap.add_argument("--jobs", type=int, default=4, help="并发抓取数，默认 4")
    ap.add_argument("--refresh", action="store_true", help="忽略 tools/.cache 强制重查")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    jobs = []            # (repo, cats)
    for raw in args.repos:
        jobs.append((parse_repo(raw), None))
    if args.batch:
        with open(args.batch, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                cat = parts[1] if len(parts) > 1 else None
                jobs.append((parse_repo(parts[0]), cat))
    if not jobs:
        ap.error("至少要给一个仓库链接，或用 --batch")

    default_cats = [c.strip() for c in args.categories.split(",") if c.strip()]
    for c in default_cats:
        if c not in VALID_CATEGORIES:
            sys.exit(f"错误：分类 {c} 不在固定分类表内：{'、'.join(VALID_CATEGORIES)}")
    for repo, cat in jobs:
        for c in job_cats(cat, default_cats):
            if c not in VALID_CATEGORIES:
                sys.exit(f"错误：{repo} 的分类 {c} 不在固定分类表内：{'、'.join(VALID_CATEGORIES)}")

    results, failures = {}, {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futs = {pool.submit(build_entry, repo, job_cats(cat, default_cats), args.arch,
                            args.asset, args.refresh): repo
                for repo, cat in jobs}
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            repo = futs[fut]
            done += 1
            try:
                appname, entry, ver, notes, truth = fut.result()
                results[repo] = (appname, entry, ver, notes, truth)
                say(f"[{done}/{len(jobs)}] ✓ {repo} → {appname} {ver}", err=True)
            except Exception as exc:  # noqa: BLE001 - 单个仓库失败不该拖垮整批
                failures[repo] = str(exc)
                say(f"[{done}/{len(jobs)}] ✗ {repo}：{exc}", err=True)

    for repo, _ in jobs:
        if repo not in results:
            continue
        appname, entry, ver, notes, _truth = results[repo]
        say(f"\n===== {repo} =====")
        for n in notes:
            say(f"  · {n}", err=True)
        say(f'"{appname}": ' + json.dumps(entry, ensure_ascii=False, indent=2))

    if failures:
        say("\n以下仓库收录失败：", err=True)
        for repo, err in failures.items():
            say(f"  ✗ {repo}：{err}", err=True)

    if not args.write:
        say(f"\n（dry-run：{len(results)} 个待写入；加 --write 才会写入 fnpack.json）")
        return 1 if failures else 0

    for repo, _ in jobs:
        if repo not in results:
            continue
        appname, entry, ver, _notes, truth = results[repo]
        write_entry(appname, entry, ver, truth)
        say(f"已写入 fnpack.json（应用 {appname}）")
    say(f"\n共写入 {len(results)} 个应用")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
