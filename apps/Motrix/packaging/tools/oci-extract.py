#!/usr/bin/env python3
"""从 OCI / Docker Registry 拉取镜像并解包出 rootfs（不依赖 docker / podman）。

用途：Motrix 官方 Server 镜像只以容器方式分发，但我们要的是里面那份
"上游已构建好的 server-app 产物"。本脚本只做 pull + 按层解包，
不执行镜像里的任何东西，因此在 x86_64 机器上也能安全地取 arm64 产物。

用法：
  oci-extract.py --repo motrixapp/motrix-server --tag 2.0.0-beta.49 \
                 --arch arm64 --outdir .build/image-arm64

输出：
  <outdir>/            解包后的 rootfs（已处理 whiteout）
  <outdir>.digest      该架构的 manifest digest（provenance 用）
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import urllib.error
import urllib.request
from typing import Any

ACCEPT_INDEX = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
ACCEPT_MANIFEST = ", ".join(
    [
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
REGISTRY = "https://registry-1.docker.io"
AUTH = "https://auth.docker.io/token"


def log(message: str) -> None:
    print(f"[oci-extract] {message}", flush=True)


def http_json(url: str, headers: dict[str, str]) -> Any:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def http_download(url: str, headers: dict[str, str], destination: str) -> None:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=300) as response, open(
        destination, "wb"
    ) as handle:
        shutil.copyfileobj(response, handle, length=1024 * 1024)


def anonymous_token(repo: str) -> str:
    url = f"{AUTH}?service=registry.docker.io&scope=repository:{repo}:pull"
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))["token"]


def select_manifest(index: dict[str, Any], arch: str) -> str:
    for entry in index.get("manifests", []):
        platform = entry.get("platform") or {}
        if platform.get("os") == "linux" and platform.get("architecture") == arch:
            return entry["digest"]
    raise SystemExit(f"no linux/{arch} manifest in image index")


# Docker/OCI whiteout 语义：.wh.<name> 删除同名条目；.wh..wh..opq 清空所在目录。
#
# 自己遍历成员而不是用 tarfile 的 filter：官方基础镜像里有绝对符号链接
# （alpine 的 /bin/arch -> /bin/busybox），任何 filter 都会拒绝；而我们只关心
# 镜像 /app 下的普通文件，所以只写 regular file + directory，其余（符号链接、
# 硬链接、设备、FIFO）一律跳过，并显式挡掉绝对路径与 .. 穿越。
def remove_path(path: str) -> None:
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.exists(path) or os.path.islink(path):
        os.remove(path)


def apply_layer(tar_path: str, root: str) -> None:
    root = os.path.realpath(root)
    with tarfile.open(tar_path, "r:*") as archive:
        for member in archive:
            if member.isdev() or member.isfifo():
                continue
            raw = member.name.lstrip("./")
            if not raw:
                continue
            name = os.path.normpath(raw)
            if name.startswith("/") or name == ".." or name.startswith("../"):
                continue
            base = os.path.basename(name)
            parent = os.path.dirname(name)
            if base == ".wh..wh..opq":
                target = os.path.join(root, parent)
                if os.path.isdir(target):
                    for entry in os.listdir(target):
                        remove_path(os.path.join(target, entry))
                continue
            if base.startswith(".wh."):
                remove_path(os.path.join(root, parent, base[len(".wh.") :]))
                continue
            destination = os.path.join(root, name)
            if not os.path.realpath(os.path.dirname(destination)).startswith(root):
                continue
            if member.isdir():
                os.makedirs(destination, exist_ok=True)
                os.chmod(destination, 0o755)
            elif member.isfile():
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    continue
                with open(destination, "wb") as handle:
                    shutil.copyfileobj(source, handle, length=1024 * 1024)
                os.chmod(destination, 0o755 if member.mode & 0o111 else 0o644)
            # 其余类型（符号链接 / 硬链接）跳过


def verify_digest(path: str, digest: str) -> bool:
    algorithm, _, expected = digest.partition(":")
    if algorithm != "sha256" or len(expected) != 64:
        return False
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest() == expected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    parser.add_argument("--outdir", required=True)
    parser.add_argument(
        "--layer-cache",
        default=None,
        help="layer 缓存目录（默认 <outdir>/../.layer-cache，按 blob sha256 校验后复用）",
    )
    options = parser.parse_args()

    outdir = os.path.abspath(options.outdir)
    layer_dir = os.path.abspath(
        options.layer_cache or os.path.join(os.path.dirname(outdir), ".layer-cache")
    )
    if os.path.exists(outdir):
        shutil.rmtree(outdir)
    os.makedirs(layer_dir, exist_ok=True)

    log(f"resolving {options.repo}:{options.tag} for linux/{options.arch}")
    token = anonymous_token(options.repo)
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": ACCEPT_INDEX,
    }
    index = http_json(
        f"{REGISTRY}/v2/{options.repo}/manifests/{options.tag}", headers
    )

    if index.get("mediaType") in ACCEPT_MANIFEST.split(", "):
        digest = f"sha256:{index.get('config', {}).get('digest', '')}"
        manifest = index
    else:
        digest = select_manifest(index, options.arch)
        manifest = http_json(
            f"{REGISTRY}/v2/{options.repo}/manifests/{digest}",
            {"Authorization": f"Bearer {token}", "Accept": ACCEPT_MANIFEST},
        )

    layers = manifest.get("layers") or []
    if not layers:
        raise SystemExit("manifest has no layers")
    log(f"manifest {digest} with {len(layers)} layers")

    root = outdir
    os.makedirs(root, exist_ok=True)
    for position, layer in enumerate(layers, start=1):
        blob = layer["digest"]
        size = layer.get("size", 0)
        target = os.path.join(layer_dir, f"{position:02d}-{blob.split(':')[1][:16]}.tar")
        if os.path.exists(target) and not verify_digest(target, blob):
            log(f"layer {position}/{len(layers)} cache digest mismatch, refetching")
            os.remove(target)
        if not os.path.exists(target):
            log(f"layer {position}/{len(layers)} {blob[:19]} ({size} bytes) downloading")
            http_download(
                f"{REGISTRY}/v2/{options.repo}/blobs/{blob}",
                {"Authorization": f"Bearer {token}"},
                target,
            )
            if not verify_digest(target, blob):
                raise SystemExit(f"layer digest mismatch after download: {blob}")
        else:
            log(f"layer {position}/{len(layers)} {blob[:19]} (cached)")
        apply_layer(target, root)

    with open(f"{outdir}.digest", "w", encoding="utf-8") as handle:
        handle.write(
            json.dumps(
                {
                    "repo": options.repo,
                    "tag": options.tag,
                    "arch": options.arch,
                    "manifest_digest": digest,
                },
                indent=2,
            )
            + "\n"
        )
    log(f"extracted to {outdir} (digest {digest})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as error:  # pragma: no cover - network
        print(f"[oci-extract] HTTP {error.code}: {error.reason}", file=sys.stderr)
        sys.exit(1)
    except (re.error, KeyError, tarfile.TarError) as error:  # pragma: no cover
        print(f"[oci-extract] failed: {error}", file=sys.stderr)
        sys.exit(1)
