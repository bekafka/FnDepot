# FnDepot 源 · bekafka

第三方 fnOS 应用的 **索引源**（FnDepot V2 格式）。本源不开发应用、不重新打包、不修改安装包：
每个应用的 FPK 都是从**原作者自己的 GitHub Releases 地址**直接安装的。

## 使用

FnDepot 客户端 → 添加源 → 填仓库地址：

```text
https://github.com/bekafka/FnDepot
```

## 收录原则

- 只收录**原作者官方发布**的 `.fpk`（GitHub Releases 资产），不镜像、不重打包、不改文件。
- 应用版权、代码安全与更新维护均归原作者；本源只负责把作者已有的发布整理成客户端可读的元数据。
- 本源内的 `sha256` / `size` 均取自实际下载的安装包，客户端会强校验；上游改动导致校验失败时，该版本会被客户端跳过而不会静默安装。
- 若你是作者且不希望被本站收录，开 issue 即可移除。

## 已收录

| 应用 | 应用键名 | 版本 | 架构 | 作者 | 安装包来源 |
| --- | --- | --- | --- | --- | --- |
| 一键超频 | `onekey-overclock` | 1.2.0 | arm | 很多问题的小明同学 | [gulugulupao/onekey-overclock](https://github.com/gulugulupao/onekey-overclock/releases) |

## 目录

```text
FnDepot/
├── fnpack.json                     # V2 索引（schema_version = "2"）
├── assets/icons/{appname}.png      # 图标（取自安装包内 ICON_256.PNG）
├── tools/new-entry.py              # 从 Release 资产反推条目
└── README.md
```

## 新增 / 更新一个应用

第三方包的应用键名、版本、架构、哈希都必须来自安装包本体，不能靠文件名猜。
用脚本自动完成：

```bash
# 国内直连 GitHub 失败时先走代理
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890

# 先空跑看结果
python3 tools/new-entry.py <owner/repo> <tag> <asset文件名> -c 系统工具
# 确认后写入 fnpack.json（自动备份 fnpack.json.bak）
python3 tools/new-entry.py <owner/repo> <tag> <asset文件名> -c 系统工具 --install-type root --write
```

脚本会下载 FPK、解开 `manifest` 与 `config/privilege`，输出 `appname`、`version`、`platform`、
`run_as`、`sha256`、`size` 等字段。之后还需人工补两件事：

1. 把图标放进 `assets/icons/{appname}.png`（可从 FPK 内 `ICON_256.PNG` 提取）：
   `tar xzOf pkg.fpk ICON_256.PNG > assets/icons/{appname}.png`
2. 补 `maintainer_url`、`bug_report_url`（指向作者仓库与 issue），必要时精简 `desc` / `changelog`。

## 发布前校验

```bash
jq empty fnpack.json                       # 严格 JSON
jq -r '.apps | keys[]' fnpack.json         # 应用键名清单
curl -sI "$(jq -r '.apps[].releases[].packages[].download_url' fnpack.json)" | head -1
```

正文改动直接 push 到默认分支 `main` 即可，客户端同步时按 `version` 变化感知更新。
**已发布的「版本号 + 架构」对应的文件视为不可变**：上游发新版本时新增版本节点，不要静默替换同版本条目。

## 说明

本源为社区第三方项目，与飞牛（fnOS）官方无关联。超频、改内核参数一类工具存在硬件风险，请自行评估、备份、量力而行。
