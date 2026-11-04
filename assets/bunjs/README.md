# Bun · 飞牛 fnOS 版

[bun](https://github.com/oven-sh/bun) 是 Oven 用 Zig 写的 JavaScript / TypeScript 一体化工具链：
**一个可执行文件里同时是运行时、包管理器、打包器、测试运行器**，速度比 node + npm 那一套快很多。
装好这个包后，飞牛终端的任意 shell 里都能直接用 `bun` 与 `bunx`，不需要先装 Node.js。

> 本包 = bun 官方发布的 **standalone 单文件可执行版本** + 飞牛适配，未修改上游任何代码。

> 本应用在应用中心里的键是 `bunjs`、显示名 **Bun**：它沿用已有同名应用的安装位置（`/vol1/@appcenter/bunjs`），安装即为**覆盖升级**，不会与旧版并排共存。

## 作者与来源

| 角色 | 是谁 |
| --- | --- |
| **源作者**（上游项目，权利源头） | [oven-sh/bun](https://github.com/oven-sh/bun)（MIT） |
| 开发者 / 发布者 | oven-sh（本包按上游署名，与上游项目同一主页） |

## 装完之后

```bash
bun --version
bun install              # 按 package.json 装依赖
bun add <包>             # 加依赖
bun run <脚本>           # 跑 scripts
bun test                 # 内置测试运行器
bun build ./index.ts     # 打包
bunx <工具>              # 临时跑一个 npm 包里的工具（＝ bun x）
bun -e 'console.log(1)'  # 直接求值
```

命令入口是 `/usr/local/bin/bun` 与 `/usr/local/bin/bunx`，指向 `/var/apps/bun/target/bin/`；
这个位置在默认 PATH 上，登录 shell、非登录 shell、脚本、cron 都能直接用。

## 这个包为什么不需要 Node.js

bun 自己是 Zig 编译的静态二进制，跑它本身不需要 Node——所以机器上一个 node 都没有，
`bun --version` 照样能用。**但它不替换系统 node**：需要 node 的项目照旧用自己的 node，
bun 是独立运行时；`bun install` 生成 `bun.lock`，不会接管已有项目的 `node_modules` 结构。

## 一些实测细节

- **两条命令**：`bun` 是主命令；`bunx` 等价于 `bun x`，包内是几百字节的包装脚本（不用软链——打包器会把软链
  指向的 102 MB 二进制再存一份，让包体从 ~40 MB 涨到 107 MB）。
- **命令入口由平台建立**：飞牛的生命周期脚本以包用户身份运行、写不了系统目录，因此
  `/usr/local/bin/{bun,bunx}` 由平台的 `usr-local-linker` 建立（manifest 已声明）。
  如果安装前这两个命令名已经存在，安装阶段会记录并接管、卸载时按记录还原。
- **缓存与全局包在用户家目录**：`~/.bun/install/cache`、`~/.bun/bin`——多用户各用各的，不占应用数据盘。
- **体积**：bun 单文件约 102 MB（自带运行时的固有成本）；成品包约 40 MB 量级，装完占盘约 102 MB。
- **卸载走应用中心界面**：本包带卸载选项，命令行卸载会被要求改用界面。

## 从哪来

- 上游：<https://github.com/oven-sh/bun>（MIT），资产取上游 Release 的
  `bun-linux-<arch>.zip`（标准 gnu 版；`bun-linux-x64.zip` / `bun-linux-aarch64.zip`）
- 校验：上游随发的汇总清单 `SHASUMS256.txt`（一行一个「摘要 + 文件名」）
- 版本：跟随上游 tag（形如 `bun-v1.4.4`），自动跟版流水线每 6 小时巡检一次，只取正式版
