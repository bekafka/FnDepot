# bun · 飞牛 fnOS 应用包

把 [Oven 的 bun](https://github.com/oven-sh/bun) 做成飞牛 fnOS 可安装的 `bun.fpk`：装完就能在终端直接敲 `bun` 与 `bunx`。

## 这是什么形态

bun 用 Zig 写成，官方发布 **standalone 单文件可执行版**（跑它自己不需要 Node.js）：

| 形态 | 里面是什么 | 是否需要 Node.js |
| --- | --- | --- |
| npm 安装（`npm i -g bun`） | 走 npm 生态 | **需要**（得先有 npm） |
| **standalone 可执行文件**（本包用的） | 单个 ELF（Zig 构建，约 99 MB） | **不需要** |

本包取后者：上游 release 的 `bun-linux-<arch>.zip`（标准 gnu 版；baseline / musl / profile 变体不取）。
所以应用中心里它**没有任何前置应用**。

一个可执行文件里同时是：**JS/TS 运行时、包管理器、打包器、测试运行器**——可以替代
node + npm + nodemon + esbuild + jest 这一套。

**边界说清楚**：这个包只提供 `bun` / `bunx` 两条命令，**不会替换系统 node**，
也不会接管已有项目的 `node_modules` 结构（`bun install` 生成自己的 `bun.lock`）。

## 装完之后

```bash
bun --version
bun install              # 按 package.json 装依赖（比 npm 快很多）
bun add <包>             # 加依赖
bun run <脚本>           # 跑 package.json 里的 scripts
bun test                 # 内置测试运行器
bun build ./index.ts     # 打包
bun x <工具>             # 临时跑一个 npm 包里的工具
bunx <工具>              # 上一条的别名入口
bun -e 'console.log(1)'  # 直接求值
```

命令入口是 `/usr/local/bin/bun` 与 `/usr/local/bin/bunx`，指向 `/var/apps/bun/target/bin/`；
这个位置在默认 PATH 上，登录 shell、非登录 shell、脚本、cron 都能直接用。

## 命令入口怎么建立、怎么还原

飞牛官方机制是 `config/resource` 里声明 `usr-local-linker`，平台在**应用启动时**建链接、停止时移除。
这个应用没有常驻进程（`ctl_stop=false`，不显示启动按钮），「启动」不一定发生，所以**安装阶段自己挂一次**。

`bunx` 不是第二个二进制：它是 `bun` 按调用名分派出的别名入口（等价于 `bun x`），
包里以 `bin/bunx → bun` 软链的形式存在（上游 npm 包也是这个做法）。

链接助手按名字逐条记账：

- 安装时 `/usr/local/bin/bun` 或 `/usr/local/bin/bunx` 已被占用 → 把原指向记进
  `/vol1/@appdata/bun/preserved-usr-local-bin-<name>`，再改指本应用；原物是真实文件则另存 `.bin`；
- 卸载时只删「指向本应用」的那两条，并按各自记录还原；原目标早就不存在就只清理，不留悬空链接；
- `cmd/main stop` 不动链接——命令式应用点一次「停止」不该让终端里的 bun 消失。

## 目录

```
package/                fnOS 包模板（manifest / config / cmd / wizard / app）
  app/bun-link.sh       命令入口助手（两条命令的 ensure / remove / status）
  cmd/install_callback  铺命令入口 + 二进制自检（--version 读不出来就判安装失败）
  cmd/uninstall_callback 撤两条入口 + 各自还原
packaging/build.sh      payload 生产线（取上游 zip → 汇总清单校验 → 解压核对 ELF 架构 → 铺 bun/bunx）
tests/accept.sh         设备上的验收阶梯（cmd / cache / realinstall / path + 卸载前后两段）
build-local.sh          本地一键出包
authorship.env          作者口径声明（本应用按上游署名 oven-sh）
```

## 构建

```bash
# 本地出包（需能访问 GitHub releases；国内环境可用 BUN_DL_PROXY 指定代理）
ARCH=arm64 VERSION=1.4.4 CHANGELOG="首版" bash build-local.sh
ARCH=amd64 VERSION=1.4.4 bash build-local.sh
```

**三处与 pnpm / uv 不同的口径**：

1. **上游 tag 形如 `bun-v1.4.4`**（前缀是 `bun-v`）——`VERSION` 只写 `1.4.4`，脚本自己拼前缀；
2. 资产是 **zip** 而不是 tar.gz，按平台命名：`bun-linux-x64.zip` / `bun-linux-aarch64.zip`；
   另有 baseline / musl / profile 变体，本包固定取标准 gnu 版；
3. **校验用一份汇总清单 `SHASUMS256.txt`**（全平台一个文件，一行一个「摘要 + 文件名」），
   一次下载即可覆盖两个架构。

## 验收

```bash
sudo bash tests/accept.sh all      # 命令可用性 + 缓存 + 真实使用 + 命令名冲突
sudo bash tests/accept.sh realinstall   # 只跑一次真实使用（会联网装一个依赖，不可达则跳过）
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
| 开发者 / 发布者 / 源作者 | [oven-sh/bun](https://github.com/oven-sh/bun)（MIT） | `maintainer` / `distributor` / `source_author` |

本包按上游署名（见 `authorship.env`），不改上游任何代码。

## 已知限制

- **不替换系统 node**：需要 node 的项目照旧用自己的 node；bun 是独立运行时。
- **不接管已有 node_modules**：`bun install` 会用 `bun.lock`，与 npm 的 lockfile 互不干扰。
- **体积偏大**：单文件约 99 MB，打进 fpk 后包体明显大于 pnpm / uv，属正常。
- **卸载走应用中心界面**：本包带卸载选项，命令行卸载会被要求改用界面。
- **自动跟版每 6 小时巡检上游正式版**（含 canary 之外的所有 prerelease 都会被过滤掉）。
