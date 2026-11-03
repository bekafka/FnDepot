# uv · 飞牛 fnOS 版

[uv](https://github.com/astral-sh/uv) 是 Astral 用 Rust 写的 Python 包与项目管理器（极快），替代
pip / pip-tools / virtualenv / pipx 这一套。装好这个包后，飞牛终端的任意 shell 里都能直接用
`uv` 与 `uvx`，不需要先装 Python 或 pip。

> 本包 = uv 官方发布的 **standalone 单文件可执行版本** + 飞牛适配，未修改上游任何代码。

## 作者与来源

| 角色 | 是谁 |
| --- | --- |
| **源作者**（上游项目，权利源头） | [astral-sh/uv](https://github.com/astral-sh/uv)（MIT OR Apache-2.0） |
| 开发者 / 发布者 | astral-sh（本包按上游署名，与上游项目同一主页） |

## 装完之后

```bash
uv --version
uv venv                  # 在项目里建虚拟环境（解释器由 uv 自己找或下载）
uv pip install <包>      # 替代 pip
uv add <包>              # 项目模式（pyproject.toml）
uv tool install <工具>   # 替代 pipx，装到 ~/.local/bin
uvx <工具>               # 临时跑一个工具
uv python install 3.12   # 让 uv 自己管理 Python 解释器
uv cache dir             # 缓存位置
```

命令入口是 `/usr/local/bin/uv` 与 `/usr/local/bin/uvx`，指向 `/var/apps/uv/target/bin/`；
这个位置在默认 PATH 上，登录 shell、非登录 shell、脚本、cron 都能直接用。

## 这个包为什么不需要 Python

uv 自己是 Rust 编译的静态二进制，跑它本身不需要 Python——所以机器上一个 Python 都没装，
`uv --version` 照样能用。**但它不替换系统 python3**：需要解释器时用 `uv python install`，
uv 会把 Python 装到自己的目录（`~/.local/share/uv/python`），项目里 `uv venv` 也能自动找或下载。

## 一些实测细节

- **两条命令**：`uv` 是主命令；`uvx` 是 `uv tool run` 的别名入口。上游发布包若未附 `uvx`，
  本包会用同名软链补齐（uv 按调用名分派，行为等价）。
- **命令入口由平台建立**：飞牛的生命周期脚本以包用户身份运行、写不了系统目录，因此
  `/usr/local/bin/{uv,uvx}` 由平台的 `usr-local-linker` 建立（manifest 已声明）。
  如果安装前这两个命令名已经存在，安装阶段会记录并接管、卸载时按记录还原。
- **缓存与 Python 都在用户家目录**：`~/.cache/uv`、`~/.local/share/uv`、工具装到 `~/.local/bin`——
  多用户各用各的，不占应用数据盘。
- **卸载走应用中心界面**：本包带卸载选项，命令行卸载会被要求改用界面。

## 从哪来

- 上游：<https://github.com/astral-sh/uv>（MIT OR Apache-2.0），资产取上游 Release 的
  `uv-<target>.tar.gz`（Linux 取 gnu 口味：`aarch64-unknown-linux-gnu` / `x86_64-unknown-linux-gnu`）
- 校验：优先用上游随包发布的 `.sha256` 文件，取不到再退回 Release 元数据里的资产摘要
- 版本：跟随上游 tag（**不带 v 前缀**，例如 `0.13.7`），自动跟版流水线每 6 小时巡检一次，只取正式版
