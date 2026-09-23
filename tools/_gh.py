#!/usr/bin/env python3
"""GitHub token 查找（tools 下三个脚本共用）。

查找顺序：
  1. 环境变量 GITHUB_TOKEN / GH_TOKEN（dsh 启动时会把 $DSH_HOME/.env 注入进程环境）
  2. $DSH_HOME/.env  ← 用户把 token 写在这里时，无需重启 dsh 也能用
  3. $FNDEPOT_GH_TOKEN_FILE 指定的文件
  4. ~/.config/fndepot/token
  5. 仓库根目录 .gh_token（已 gitignore）

前三类按 KEY=VALUE 解析；第 4、5 类内容可以是裸 token，也可以是 KEY=VALUE。
"""

import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS = ("GITHUB_TOKEN", "GH_TOKEN")


def _read_env_file(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = re.sub(r"^export\s+", "", key.strip())
        if key in KEYS:
            value = value.strip().strip('"').strip("'")
            if value:
                return value
    return None


def _read_token_file(path):
    """显式 token 文件：允许裸 token，也允许 KEY=VALUE。"""
    value = _read_env_file(path)
    if value:
        return value
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" not in line:
                    return line
    except OSError:
        pass
    return None


def gh_token():
    for key in KEYS:
        val = os.environ.get(key)
        if val and val.strip():
            return val.strip()
    dsh_home = os.environ.get("DSH_HOME")
    for path in ([os.path.join(dsh_home, ".env")] if dsh_home else []) + \
                [os.path.expanduser("~/.dsh/.env")]:
        val = _read_env_file(path)
        if val:
            return val
    for path in (os.environ.get("FNDEPOT_GH_TOKEN_FILE"),
                 os.path.expanduser("~/.config/fndepot/token"),
                 os.path.join(ROOT, ".gh_token")):
        val = _read_token_file(path)
        if val:
            return val
    return None
