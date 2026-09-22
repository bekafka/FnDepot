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
- 每个安装包的 `size` 与 `sha256` 都取自该安装包本身（GitHub 官方 digest，或本地实测下载），客户端会强校验；
  上游改动导致校验失败时，该版本会被客户端跳过而不会静默安装。
- 若你是作者且不希望被本站收录，开 issue 即可移除。

## 已收录

| 应用 | 应用键名 | 版本 | 架构 | 作者 | 安装包来源 |
| --- | --- | --- | --- | --- | --- |
| 一键超频 | `onekey-overclock` | 1.2.0 | arm | 很多问题的小明同学 | [gulugulupao/onekey-overclock](https://github.com/gulugulupao/onekey-overclock/releases) |
| 中转站监控 | `relay-monitor` | 2.0.0 | x86 | sddvcm | [sddvcm/relay-monitor](https://github.com/sddvcm/relay-monitor/releases) |

**中转站监控**作者只发布了 **x86 包**（manifest `platform = x86`，包内自带 x86 Python 解释器），
**arm64 设备上不会显示也无法安装**；其 README 写的最新版是 v2.0.5，但 GitHub 上实际只发布到 v2.0.0，
本源只收录真实发布过的版本。

## 目录

```text
FnDepot/
├── fnpack.json                     # V2 索引（schema_version = "2"）
├── assets/icons/{appname}.png      # 图标（取自安装包内 ICON_256.PNG）
├── tools/new-entry.py              # 从 Release 资产反推条目
└── README.md
```

## 常见疑问

**为什么下载地址不用 `releases/latest/download/...` 这种“永远最新”的固定地址？**

技术上 GitHub 支持，但对本源不可用，两个原因：

1. 这些作者的资产文件名**本身含版本号**（`OneKey-OC-v1.2.0-lite.fpk`、`fnmonitor-2.15.0-arm.fpk`）。
   `latest` 只是把请求转发到“最新那个 release 里的同名资产” —— 文件名一变，旧地址立刻 404：
   实测 `latest/download/OneKey-OC-v1.2.0-lite.fpk` 返回 200，而 `latest/download/OneKey-OC-v1.1.0-lite.fpk` 返回 404。
   也就是固定地址会在作者发下一版的当天失效。
2. V2 会**强校验 `sha256`**。`latest` 指向的文件内容随时会变，钉死的哈希必然过期（客户端拒装）；
   而要跟着改哈希、改 `version`，你仍然得每次同步一遍——省不掉工作，只多了一个会静默失效的地址。

所以本源一律写**带 tag 的确定性地址**：`.../releases/download/<tag>/<资产名>`。

**一定要把整包下载下来吗？**

不是。字段来源分两类：

| 字段 | 来源 | 需要下载整包吗 |
| --- | --- | --- |
| `version` | release tag | 否 |
| `size`、`sha256` | GitHub API 的 `size` 与 `digest`（上传时生成、不可变） | 否 |
| `appname`、`platform`、`desc`、`service_port`、`os_min_version`、`changelog` | 包内 `manifest` | 是（或读仓库里提交的同名文件） |
| `run_as` | 包内 `config/privilege` | 是（同上） |

`appname` / `platform` / `run_as` 这几项**不在** API 里，只能从包里（或仓库源码里）读，
而它们恰好是最不能猜的：键名必须与包内 `appname` 完全一致；`platform` 填错会让 arm 设备显示装不了的 x86 包。

因此脚本提供两种取元数据的方式：

- **默认（下载整包）**：最权威，`sha256` 为本地实测值；不消耗 GitHub API 配额，可离线复算。
- **`--light`（不下整包）**：元数据读作者仓库里提交的 `manifest` / `config/privilege`（几 KB），
  `size`/`sha256` 读 GitHub 官方 digest。要求仓库版 `manifest` 的 `version` 与 release tag 一致，
  不一致就报错让你改走下载——避免把落后于发布的仓库文件当成发布内容。
  实测一键超频：2.5 秒完成，且与原下载所得条目逐字段等价。

> 顺带一个反面结论：**“只读包里前几 KB 拿到 manifest 就中断”并不通用**。relay-monitor 的 `manifest`
> 排在包内第 17 位，前面是占全包 99.9% 的 `app.tgz`，流式读到它等于把整包读完。
> 是否可行取决于作者打包时的成员顺序，所以没把它做成默认路径。

`--light` 走 API，会消耗配额：未认证 **60 次/小时**（每个应用约 2 次）。设置 `GITHUB_TOKEN` 可提到 5000 次/小时；
查询结果缓存在 `tools/.cache/`，`--refresh` 可强制重查。

## 新增 / 更新一个应用

```bash
# 国内直连 GitHub 失败时先走代理
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890

# 方式一：不下整包（推荐，前提是作者仓库里提交了 manifest）
python3 tools/new-entry.py <owner/repo> <tag> <asset文件名> -c 系统工具 --light

# 方式二：下载整包（最权威；大包先用 curl 续传再喂进来）
curl -fL -C - --retry 8 --retry-all-errors -o /tmp/pkg.fpk <下载地址>
python3 tools/new-entry.py <owner/repo> <tag> <asset文件名> -c 系统工具 --local /tmp/pkg.fpk

# 确认无误后加 --write 写入 fnpack.json（自动备份 fnpack.json.bak）
```

之后还需人工补两件事：

1. 把图标放进 `assets/icons/{appname}.png`（可从 FPK 内 `ICON_256.PNG` 提取，或下载作者 Release 里的 `ICON_256.PNG`）：
   `tar xzOf pkg.fpk ICON_256.PNG > assets/icons/{appname}.png`
2. 补 `maintainer_url`、`bug_report_url`（指向作者仓库与 issue），必要时精简 `desc`。

几个约定：

- **双架构应用**：对每个架构各跑一次 `--write`，同版本的另一个架构会并进 `packages`，`platform` 自动取并集。
- **安装空间**默认 `""`＝存储空间；只有会写 `/boot`、注册 systemd 服务的应用才加 `--install-type root`
  （可参考作者自带 FnDepot 源里的写法交叉验证）。
- 更新已有应用时，脚本会保留手工维护的 `icon_url` / `maintainer_url` / `bug_report_url` 与安装空间设置。

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
