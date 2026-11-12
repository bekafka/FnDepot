# FnDepot · 飞牛 fnOS 第三方应用源

给飞牛 fnOS 准备的第三方应用源，收录一些官方应用中心里没有的应用。装好之后，应用的安装、更新、卸载都由
fnOS 应用中心统一管理，和官方应用一样操作。

## 应用列表

| 应用 | 键名 | 版本 | 架构 | 原作者 | 说明 |
| --- | --- | --- | --- | --- | --- |
| [Motrix](assets/Motrix/README.md) | `Motrix` | 2.2.1 | arm / x86 | [agalwood/Motrix](https://github.com/agalwood/Motrix) | 全功能下载管理器（HTTP / FTP / BT / 磁力）的服务端 Web 面板，aria2 内核 |
| [Magpie](assets/Magpie/README.md) | `Magpie` | 0.1.3472 | arm / x86 | [yetone/magpie](https://github.com/yetone/magpie) | 多模型 API 反代网关 + 编程 Agent 模型切换器：OpenAI Responses / Anthropic Messages / Gemini 双向互译，路由组合、Skills/MCP、脱敏、额度统计、自动签到 |
| [pnpm](assets/pnpm/README.md) | `pnpm` | 12.20.0 | arm / x86 | [pnpm/pnpm](https://github.com/pnpm/pnpm) | Node.js 生态里更快、更省磁盘的包管理器（官方 standalone 单文件版）：装完终端直接可用 `pnpm`，不依赖 nodejs 运行时 |
| [gh cli](assets/gh-cli/README.md) | `gh-cli` | 2.103.3 | arm / x86 | [cli/cli](https://github.com/cli/cli) | GitHub 官方命令行工具（官方静态二进制）：终端里管仓库 / Issue / PR / Actions / Release / API；安装向导可选填 GitHub Token，填了之后同机终端用户直接可用 `gh` |
| [uv bin](assets/uvbin/README.md) | `uvbin` | 0.13.7 | arm / x86 | [astral-sh/uv](https://github.com/astral-sh/uv) | Rust 写的 Python 包与项目管理器（官方 standalone 单文件版）：装完终端直接可用 `uv` / `uvx`，不需要先装 Python |
| [Bun](assets/bunjs/README.md) | `bunjs` | 1.4.4 | arm / x86 | [oven-sh/bun](https://github.com/oven-sh/bun) | Oven 用 Zig 写的 JS/TS 一体化工具链（官方 standalone 单文件版）：一个可执行文件里同时是运行时、包管理器、打包器、测试运行器，装完直接可用 `bun` / `bunx`；沿用应用中心已有的 `bunjs` 键，覆盖升级 |
| [Cloudflare 优选](assets/CloudflareIP/README.md) | `CloudflareIP` | 1.0.0 | arm / x86 | [bekafka/FnDepot](https://github.com/bekafka/FnDepot) | 给走 Cloudflare 的域名挑真正可用且落点近的边缘 IP，按页面级首字节耗时排名，结果写进本机 /etc/hosts 的受管区块（可一键还原） |
| [PhotoCraft](assets/PhotoCraft/README.md) | `PhotoCraft` | 0.20.1 | arm / x86 | [storytold/photocraft](https://github.com/storytold/photocraft) | 浏览器里运行的图像编辑器（WebAssembly）：图层、蒙版、调整图层、图层样式、文字、矢量与真实 PSD 读写；NAS 只做静态托管，编辑与文件读写都在访客设备上完成 |
| [OES3D](assets/OES3D/README.md) | `OES3D` | 1.0.2 | arm | [bekafka/FnDepot](https://github.com/bekafka/FnDepot) | 网心云 OES 3D 实机模型与五颗绿色 LED 指示灯控制面板，arm64 专用 |

> 版本与架构两列会随发版自动更新；「原作者」指上游项目最初的创造者与权利源头，人工维护、不随版本变。

## 添加应用源

飞牛 fnOS 应用中心 → 设置 → 应用源 → 添加，填入本仓库地址：

```
https://github.com/bekafka/FnDepot
```

添加后回到应用中心，在「第三方应用」里即可看到本源的收录应用，点安装就行。
安装包的下载与校验（SHA-256 / 体积）由应用中心完成，全部来自本仓库 Releases。

## 兼容性

| 项 | 说明 |
| --- | --- |
| 系统版本 | 飞牛 fnOS 1.x（应用包格式 V2） |
| 架构 | x86_64 / arm64（每个应用的具体架构见列表） |
| 运行方式 | 应用以独立低权限用户运行（个别需要改系统文件的应用以 root 运行，见其应用页说明），数据落在应用自己的空间，卸载时可选择是否保留配置 |

## 关于应用

- 每个应用都来自其原作者的开源项目，本仓库只做**打包适配**（飞牛应用包格式、生命周期脚本、
  目录与权限），不改上游业务逻辑。
- 每个应用都标明**三个作者**，不混写：
  - **开发者**：做飞牛适配、写生命周期脚本、打包的人 —— bekafka（[FnDepot](https://github.com/bekafka/FnDepot)）；
  - **发布者**：把 `.fpk` 发出来、维护本应用源的人 —— bekafka（同一仓库发布）；
  - **源作者**：上游项目**最初的创造者与权利源头**，见列表「原作者」列（例：Motrix 是
    [agalwood/Motrix](https://github.com/agalwood/Motrix)）。
- 单个应用的介绍、作者与来源、使用说明、端口与数据目录，见应用页（列表里的应用名可点）。
- 想自己打包、或把别的项目接进来：应用源码与打包脚本都在本仓库 `apps/` 下，
  构建流水线在 [bekafka/FnFactory](https://github.com/bekafka/FnFactory)。

## 反馈

- 应用本身的问题（功能、上游缺陷）：请到对应上游项目反馈。
- 打包 / 安装 / 飞牛适配相关的问题：在本仓库开 Issue。

## 许可

各应用版权归其原作者所有，遵循上游项目的开源许可；本仓库的索引与打包脚本同样开源。
