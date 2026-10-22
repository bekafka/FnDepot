# FnDepot · 飞牛 fnOS 第三方应用源

给飞牛 fnOS 准备的第三方应用源，收录一些官方应用中心里没有的应用。装好之后，应用的安装、更新、卸载都由
fnOS 应用中心统一管理，和官方应用一样操作。

## 应用列表

| 应用 | 键名 | 版本 | 架构 | 原作者 | 说明 |
| --- | --- | --- | --- | --- | --- |
| [Motrix](assets/Motrix/README.md) | `Motrix` | 2.0.0-beta.49 | arm / x86 | [agalwood/Motrix](https://github.com/agalwood/Motrix) | 全功能下载管理器（HTTP / FTP / BT / 磁力）的服务端 Web 面板，aria2 内核 |
| [Magpie](assets/Magpie/README.md) | `Magpie` | 0.1.1315 | arm / x86 | [yetone/magpie](https://github.com/yetone/magpie) | AI 模型统一网关：OpenAI / Anthropic / Gemini 三种 API 互转，路由组自动切账号，Web 面板管理 provider 与用量 |

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
| 运行方式 | 应用以独立低权限用户运行，数据落在应用自己的空间，卸载时可选择是否保留配置 |

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
