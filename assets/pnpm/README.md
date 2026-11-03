# pnpm · 飞牛 fnOS 版

[pnpm](https://github.com/pnpm/pnpm) 是 Node.js 生态里更快、更省磁盘的包管理器。装好这个包后，
飞牛终端的任意 shell 里都能直接用 `pnpm`，不需要先装 Node。

> 本包 = pnpm 官方发布的 **standalone 单文件可执行版本** + 飞牛适配，未修改上游任何代码。

## 作者与来源

| 角色 | 是谁 |
| --- | --- |
| **源作者**（上游项目，权利源头） | [pnpm/pnpm](https://github.com/pnpm/pnpm)（MIT） |
| 开发者 / 发布者 | pnpm（本包按上游署名，与上游项目同一主页） |

## 装完之后

```bash
pnpm -v                 # 版本号
pnpm install            # 在项目目录里
pnpm store path         # 缓存目录
pnpm setup              # 想让 pnpm add -g 的全局命令进 PATH，跑一次并重开终端
```

命令入口是 `/usr/local/bin/pnpm`，指向 `/var/apps/pnpm/target/bin/pnpm`；这个位置在默认 PATH 上，
登录 shell、非登录 shell、脚本、cron 都能直接用。

## 这个包为什么不需要 Node

pnpm 本体是用 TypeScript 写的程序，运行时需要一个 JavaScript 引擎。上游同时提供两种发行形态：
一种是 npm 包（要有 Node 才能跑），另一种是把 Node 引擎直接用 Node SEA 编译进可执行文件内部的
**standalone 单文件**。本包取的是后者，因此：不依赖应用中心里的 nodejs 运行时，卸载或升级 nodejs
都不会影响它。

**边界**：这只解决「pnpm 命令能跑」。`pnpm install` 之后你的项目要真正运行，仍然需要 Node
（装应用中心的 nodejs 运行时即可）——pnpm 是包管理器，不替项目提供解释器。

## 一些实测细节

- **缓存落点**：pnpm 要求缓存与项目在同一文件系统。项目在 `/vol1/...` 时缓存落在
  `~/.local/share/pnpm/store/v11`；项目在另一个文件系统（比如内存盘 `/tmp`）时，它会改用项目内的
  `node_modules/.pnpm-store`。这是 pnpm 自身规则，不是包的问题。
- **原生扩展**：包里一并带了 pnpm 自带的 `dist/`（node-gyp 等），所以带原生扩展的项目
  （node-sass、better-sqlite3 之类）做 rebuild 也能正常工作。
- **命令入口由平台建立**：飞牛的生命周期脚本以包用户身份运行，写不了系统目录，因此
  `/usr/local/bin/pnpm` 是由平台的 `usr-local-linker` 机制建立的（manifest 里已声明）。
  卸载时平台会把它移除；如果安装前这个命令名已经存在，安装阶段会记录并接管、卸载时按记录还原。
- **卸载走应用中心界面**：本包带卸载选项（保留记录 / 完全删除），因此命令行卸载会被要求改用界面。

## 从哪来

- 上游：<https://github.com/pnpm/pnpm>（MIT），资产取自上游 Release 的 `pnpm-linux-<x64|arm64>.tar.gz`
- 校验：上游不发校验清单文件，打包时读取 Release 元数据里每个资产自带的 sha256 摘要核对
- 版本：跟随上游 tag（自动跟版流水线每 6 小时巡检一次，只取正式版）
