# uv · 飞牛 fnOS 应用包

把 [Astral 的 uv](https://github.com/astral-sh/uv) 做成飞牛 fnOS 可安装的 `uvbin.fpk`：装完就能在终端直接敲 `uv` 与 `uvx`。

## 这是什么形态

uv 是 Rust 写的 Python 包与项目管理器，官方发布 **standalone 单文件可执行版**（不需要先装 Python 或 pip 才能跑它自己）：

| 形态 | 里面是什么 | 是否需要 Python |
| --- | --- | --- |
| pip 安装（`pip install uv`） | Python 包 | **需要**，机器上得有 Python |
| **standalone 可执行文件**（本包用的） | 单个 ELF（Rust 静态编译） | **不需要** |

本包取后者：上游 release 的 `uv-<target>.tar.gz`（Linux 取 gnu 口味，目标机 glibc 2.36 满足）。
所以应用中心里它**没有任何前置应用**。

**边界说清楚**：这个包只提供 `uv` / `uvx` 两条命令，**不会替换系统 python3**。
需要 Python 时由 uv 自己管：`uv python install 3.12` 把解释器装到 uv 自己的目录（`~/.local/share/uv/python`），
项目里 `uv venv` 会自己找到或下载合适的解释器。

## 装完之后

```bash
uv --version
uv venv                 # 在项目里建虚拟环境
uv pip install <包>     # 替代 pip
uv add <包>             # 项目模式（pyproject.toml）
uv tool install <工具>  # 替代 pipx，装到 ~/.local/bin
uvx <工具>              # = uv tool run，临时跑一个工具
uv python install 3.12  # 自己管理 Python 解释器
uv cache dir            # 缓存位置
```

命令入口是 `/usr/local/bin/uv` 与 `/usr/local/bin/uvx`，指向 `/var/apps/uvbin/target/bin/`。
这个位置在默认 PATH 上，登录 shell、非登录 shell、脚本、cron 都能直接用。

## 命令入口怎么建立、怎么还原

飞牛官方机制是 `config/resource` 里声明 `usr-local-linker`，平台在**应用启动时**建链接、停止时移除。
这个应用没有常驻进程（`ctl_stop=false`，不显示启动按钮），「启动」不一定发生，所以**安装阶段自己挂一次**。

→ 与 pnpm 包的关键差异：uv 有**两条**命令，链接助手按名字逐条记账：

- 安装时 `/usr/local/bin/uv` 或 `/usr/local/bin/uvx` 已被占用 → 把原指向记进
  `/vol1/@appdata/uvbin/preserved-usr-local-bin-<name>`，再改指本应用；原物是真实文件则另存 `.bin`；
- 卸载时只删「指向本应用」的那两条，并按各自记录还原；原目标早就不存在就只清理，不留悬空链接；
- `cmd/main stop` 不动链接——命令式应用点一次「停止」不该让终端里的 uv 消失。

## 目录

```
package/               fnOS 包模板（manifest / config / cmd / wizard / app）
  app/uv-link.sh       命令入口助手（两条命令的 ensure / remove / status）
  cmd/install_callback 铺命令入口 + 二进制自检（--version 读不出来就判安装失败）
  cmd/uninstall_callback 撤两条入口 + 各自还原
packaging/build.sh     payload 生产线（取上游 standalone 资产 → 双路校验 → 核对 ELF 架构 → 铺 uv/uvx）
tests/accept.sh        设备上的验收阶梯（cmd / cache / realinstall / path + 卸载前后两段）
build-local.sh         本地一键出包
authorship.env         作者口径声明（本应用按上游署名 astral-sh）
```

## 构建

```bash
# 本地出包（需能访问 GitHub releases；国内环境可用 UV_DL_PROXY 指定代理）
ARCH=arm64 VERSION=0.13.7 CHANGELOG="首版" bash build-local.sh
ARCH=amd64 VERSION=0.13.7 bash build-local.sh
```

**两个与 pnpm 不同的口径**：

1. **uv 的 tag 不带 v 前缀**（`0.13.7`，不是 `v0.13.7`）——`VERSION` 直接写版本号；
2. 资产名是**目标三元组**（`uv-aarch64-unknown-linux-gnu.tar.gz` / `uv-x86_64-unknown-linux-gnu.tar.gz`），
   还有 musl 口味；本包固定取 gnu。

**校验**：优先用上游随包发布的 `.sha256` 文件，取不到再退回 release 元数据里的资产摘要；两路都拿不到就中止。

## 验收

```bash
sudo bash tests/accept.sh all      # 命令可用性 + 缓存 + 真实使用 + 命令名冲突
sudo bash tests/accept.sh cmd      # 只跑命令可用性
```

卸载链路要两段跑（带卸载向导的包不能用命令行卸载）：

```bash
sudo bash tests/accept.sh preuninstall   # 记录卸载前状态
# 应用中心界面里卸载
sudo bash tests/accept.sh postuninstall  # 核对两条入口已移除/已还原、应用目录已清理
```

## 作者与来源

| 角色 | 是谁 | manifest 字段 |
| --- | --- | --- |
| 开发者 / 发布者 / 源作者 | [astral-sh/uv](https://github.com/astral-sh/uv)（MIT OR Apache-2.0） | `maintainer` / `distributor` / `source_author` |

本包按上游署名（见 `authorship.env`），不改上游任何代码。

## 已知限制

- **不替换系统 python3**：需要解释器用 `uv python install`；`uv venv` 会自动找或下载。
- **不注册短名或别名**：只暴露 `uv` 与 `uvx` 两条，符合飞牛「命令名带应用标识、避免抢占通用名」的约定。
- **不跟随上游自动升级**：升级走应用中心（自动跟版流水线每 6 小时巡检上游正式版）。
- **卸载走应用中心界面**：本包带卸载选项，命令行卸载会被要求改用界面。
