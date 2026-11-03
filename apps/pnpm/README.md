# pnpm · 飞牛 fnOS 应用包

把 [pnpm](https://github.com/pnpm/pnpm) 做成飞牛 fnOS 可安装的 `pnpm.fpk`：装完就能在终端直接敲 `pnpm`。

## 这是什么形态

pnpm 本体是一个 JavaScript 程序，要跑起来必须有 JavaScript 引擎。上游每版会同时发布两种东西：

| 形态 | 里面是什么 | 是否需要 Node |
| --- | --- | --- |
| npm 包（`npm i -g pnpm`） | JS 文件 + 脚本壳 | **需要**，机器上得有 Node |
| **standalone 可执行文件**（本包用的） | 单个 ELF，Node 引擎已编译进文件内部 | **不需要** |

本包取的是后者：官方 release 里的 `pnpm-linux-<arch>.tar.gz`，解出来就是一个可执行文件。
所以在应用中心里它**没有任何前置应用**，卸载或升级 nodejs 运行时都不会把它弄坏。

**边界说清楚**：这只解决「pnpm 命令能跑」。`pnpm install` 之后的项目要真正运行，仍然需要 Node
（装应用中心的 nodejs 运行时即可）——pnpm 是包管理器，不替项目提供解释器。

## 装完之后

```bash
pnpm -v                 # 版本号（与包内 share/PROVENANCE.json 一致）
pnpm install            # 在项目目录里
pnpm store path         # 内容寻址缓存目录
pnpm setup              # 想让 pnpm add -g 的全局命令进 PATH，跑一次并重开终端
```

**缓存落点有个实测细节**：pnpm 要求缓存与项目在同一个文件系统上，所以
项目在 `/vol1/...` 时缓存落在 `~/.local/share/pnpm/store/v11`；项目放在另一个文件系统
（例如 `tmpfs` 的 `/tmp`）时它会改用项目内的 `node_modules/.pnpm-store`。
这不是包的问题，是 pnpm 自身规则；排查「缓存怎么突然变了个位置」时按这条看。

命令入口是 `/usr/local/bin/pnpm`，指向 `/var/apps/pnpm/target/bin/pnpm`。
这个位置在默认 PATH 上，所以登录 shell、非登录 shell、脚本、cron 都能直接用，不需要改 profile。

## 命令入口怎么建立、怎么还原

飞牛官方的机制是 `config/resource` 里声明 `usr-local-linker`，由平台在**应用启动时**建立链接、
停止时移除。但这个应用没有常驻进程（`ctl_stop=false`，应用中心不显示启动按钮），「启动」这一步
不一定会发生，所以**安装阶段就自己挂一次**（`cmd/install_callback` → `app/pnpm-link.sh ensure`）。

`/usr/local/bin/pnpm` 是个通用命令名，机器上很可能已经有人占着（例：另一套手工装的 pnpm、
指向别的共享目录的软链）。所以接管有保护：

- 安装时发现被占用 → 把原指向记录到 `/vol1/@appdata/pnpm/preserved-usr-local-bin-pnpm`，然后改指本应用；
  如果原物是真实文件（不是软链），额外另存一份再接管；
- 卸载时只删「指向本应用」的链接，并按记录还原；原目标早就不存在就只清理，**不制造悬空链接**；
- `cmd/main stop` 刻意不动链接——命令式应用点一次「停止」不该让终端里的 `pnpm` 消失。

## 目录

```
package/                 fnOS 包模板（manifest / config / cmd / wizard / app）
  app/pnpm-link.sh       命令入口助手（ensure / remove / status 三个动作）
  cmd/install_callback   铺命令入口 + 二进制自检（版本号读不出来就判安装失败）
  cmd/uninstall_callback 撤命令入口 + 还原被接管的同名命令
packaging/build.sh       payload 生产线（拉上游 standalone 资产 → 校验 → 核对 ELF 架构）
tests/accept.sh          设备上的验收阶梯（cmd / store / realinstall / path + 卸载前后两段）
build-local.sh           本地一键出包
```

## 构建

```bash
# 本地出包（需能访问 GitHub releases；国内环境可用 PNPM_DL_PROXY 指定代理）
ARCH=arm64 VERSION=12.16.1 CHANGELOG="首版" bash build-local.sh
ARCH=amd64 VERSION=12.16.1 bash build-local.sh

# CI：FnDepot 仓库 Actions → Build App → app_key=pnpm, version=12.16.1
```

**校验口径与其它应用不同**：pnpm 的 release **不发 `SHA256SUMS` 文件**。打包脚本改用 GitHub
release 元数据里每个资产自带的 `digest`（`sha256:...`）做校验；拿不到摘要就直接退出，不会
「把实际值记下来当标准」。

## 验收

```bash
sudo bash tests/accept.sh all     # 命令可用性 + 缓存 + 真实安装 + 命令名冲突
sudo bash tests/accept.sh cmd     # 只跑命令可用性
```

卸载链路要两段跑（应用不能自己卸自己）：

```bash
sudo bash tests/accept.sh preuninstall      # 记录卸载前状态
sudo appcenter-cli uninstall pnpm
sudo bash tests/accept.sh postuninstall     # 核对入口已移除/已还原、应用目录已清理
```

## 作者与来源

| 角色 | 是谁 | manifest 字段 |
| --- | --- | --- |
| 开发者（飞牛适配与打包） | bekafka | `maintainer` / `maintainer_url` |
| 发布者（发布到应用源） | bekafka（[FnDepot](https://github.com/bekafka/FnDepot)） | `distributor` / `distributor_url` |
| 源作者（上游项目，权利源头） | [pnpm/pnpm](https://github.com/pnpm/pnpm)（MIT） | `source_author` / `source_author_url` |

## 已知限制

- **不注册短命令名**（`pn` / `px` / `pnpx`）：飞牛规范要求可执行文件名带应用标识、避免与系统命令
  抢同一路径，所以只暴露 `pnpm`。需要短名就自己加软链。
- **不预设 `PNPM_HOME`**：全局安装目录由 pnpm 自身默认值决定（各自用户家目录）。需要全局命令进 PATH，
  在该用户下跑一次 `pnpm setup` 并重开终端；不预置是为了不替用户改 shell 配置。
- **生命周期脚本以包用户身份运行**：飞牛在这台设备上让安装/卸载脚本以应用用户执行，对 `/usr/local/bin`
  没有写权限。因此命令入口实际由**平台的 usr-local-linker** 建立（manifest 已声明），脚本里的「接管已有
  同名命令并记录/还原」逻辑只在脚本有足够权限时（例如把 privilege 改成 root）才会真正生效。
- **不跟随上游自动升级**：升级走应用中心（本包新版本），不在应用内自更新。
- **项目仍需要 Node**：见上「边界说清楚」。
