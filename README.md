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
| 一键超频 | `onekey-overclock` | 1.2.0 | arm | 很多问题的小明同学 | [gulugulupao/onekey-overclock](https://github.com/gulugulupao/onekey-overclock) |
| 中转站监控 | `relay-monitor` | 2.0.0 | x86 | sddvcm | [sddvcm/relay-monitor](https://github.com/sddvcm/relay-monitor) |
| fnMusic 扩展 | `fnmusic-ext` | 2.2.7 | all | javycoder | [javycoder/fnos_music_ext](https://github.com/javycoder/fnos_music_ext) |
| 飞牛音乐酷狗扩展 | `fnmusic-ext-kugou` | 2.1.0 | all | ai2ku | [ai2ku/fnos-music-ext-kugou-fpk](https://github.com/ai2ku/fnos-music-ext-kugou-fpk) |
| Hosts 管理器 | `fnnas.hosts` | 1.0.61 | all | 豪子 / Contribuv | [Contribuv/fn-hosts](https://github.com/Contribuv/fn-hosts) |
| Hermes Agent | `hermes-agent` | 0.21.3.1 | all | veenyi | [veenyi/fnos-hermes-agent-web](https://github.com/veenyi/fnos-hermes-agent-web) |

各条目的可信度不一样，如实标注：

- **读到作者 manifest 的**（`fnnas.hosts`、`hermes-agent`）：`appname` / `platform` / `service_port` / `run_as` 是作者自己声明的真值。
  `hermes-agent` 用的是 [veenyi/fnos-hermes-agent-web](https://github.com/veenyi/fnos-hermes-agent-web)（FPK 发布在这里），
  其仓库内 manifest 版本号（0.21.0.1）落后于 tag（0.21.3.1），因此 `platform`/图标按仓库文件取，版本按 tag 取。
- **按 README 填的**（`fnmusic-ext`、`fnmusic-ext-kugou`）：这两个仓库没提交 manifest，
  `appname` 由资产文件名推导，`platform` 无架构声明故填 `all`，`desc`/`service_port`/`run_as` 来自 README。
  若装不上或显示异常，优先怀疑这几项。
- **`fnmusic-ext` 是 Docker 应用**（FPK 会起容器，未装 Docker 直接报错退出），已标 `is_docker: true`。
- **`fnmusic-ext-kugou` 本身不含音源**，需先自行部署 KuGouMusicApi 实例才能工作。
- **`中转站监控`** 作者只发布了 **x86 包**，arm64 设备上不会显示也无法安装；其 README 写的最新版是 v2.0.5，
  但 GitHub 上实际只发布到 v2.0.0，本源只收录真实发布过的版本。
- **`veenyi/fnos-hermes-agent` 未收录**：该仓库的 release 里没有任何 `.fpk` 资产，没有可安装的东西。
- **图标**：`fnnas.hosts`、`hermes-agent` 引用作者仓库内的真实 ICON；两个音乐扩展没有图标，统一引用本源通用图标 `assets/icons/fnapp.png`。
  **约定：应用没有图标时一律用 `assets/icons/fnapp.png`，不要删这个文件，也不要用外部占位图。**

> 这些条目**没有下载整包验证**：`size` 取自下载地址的 `content-length`，`sha256` 取自 GitHub Release 页面公布的官方 digest。
> 客户端安装时仍会按此强校验，若上游重传过资产则会被拦截。

## 目录

```text
FnDepot/
├── fnpack.json                     # V2 索引（schema_version = "2"）
├── assets/icons/fnapp.png          # 统一图标：所有应用都用它（勿删）
├── tools/add-app.py                # 【主】丢一个仓库链接就能收录（不下载整包）
├── tools/check-updates.py          # 巡检上游是否有新版 / 资产被重传
├── tools/new-entry.py              # 底层采集：--light / --local / 下载整包
├── .gh_token                       # 可选：GitHub token（已 gitignore，勿提交）
└── README.md
```

## 收录规则（固定口径）

1. **丢链接即收录**：给一个 GitHub 仓库链接，先抓项目主页/仓库里的关键信息，把**必填项**填齐即可；
   非必填项拿不到就不管（只有仓库 manifest 里免费带的才顺手写上）。
2. **图标统一**：`"icon_url": "assets/icons/fnapp.png"` —— 不用各应用自己的图标，也不用外部占位图。
3. **下载地址只由脚本取**：`download_url` / `sha256` / `size` 一律从上游 release 现取
   （GitHub 官方 digest + `content-length`），不手写、不靠文件名猜。
4. **版本只从首次收录算起**：不回溯补历史版本；以后巡检到新版本就**追加**新版本节点，已收录的版本保留
   （可用于回滚、以及老 fnOS 的系统版本兜底）。
5. 全程**不下载安装包**；只有确实需要本地实测哈希时才走 `--local`。
6. **README 收录表里的链接指向项目主页**（`https://github.com/owner/repo`），不要链到 `.../releases` 页面；
   收录后同步更新表里的版本号。

一条命令完成收录（`--write` 才落盘，不加是 dry-run）：

```bash
python3 tools/add-app.py <仓库链接> -c 分类 --write
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

`--light` 走 API，会消耗配额：未认证 **60 次/小时**（每个应用约 2 次）。结果缓存在 `tools/.cache/`，`--refresh` 可强制重查。

## 跟版 / 巡检（不下载安装包）

```bash
python3 tools/check-updates.py              # 检查全部已收录应用
python3 tools/check-updates.py fnmusic-ext  # 只查一个
```

报出三类情况：

- 上游发了**新版本**（tag 变了）
- **同版本但资产被重传**——我们钉在 `fnpack.json` 里的 `sha256` 已失效，客户端会拒装（这是外链源最容易悄悄坏掉的方式）
- 上游**资产命名变了**，自动匹配不到，需人工确认

退出码 `0` 全部最新 / `1` 有需处理的 / `2` 有查询失败，可直接挂 cron。
取数优先走 GitHub API（一次请求拿到 tag + 资产名 + size + digest）；配额不可用时**自动降级**到不耗配额的路径
（`releases.atom` 取 tag + release 页面取官方 digest + `HEAD` 取 content-length）。

## GitHub API token（可选，但建议配）

未认证配额是 **60 次/小时，且按出口 IP 计**——走代理时出口可能是共享 IP，更容易被别人用光；配上 token 后是 **5000 次/小时**。

**本机已经配好了**：token 写在 DSH 的用户层环境变量文件 `$DSH_HOME/.env` 里（键名 `GITHUB_TOKEN`）。
`tools/_gh.py` 会**直接解析这个 `.env`**，所以即使该文件"需重启 dsh 才注入进程环境"，脚本也立刻能用——
`check-updates.py` 输出里的来源显示 `(api)` 就代表 token 已生效（未认证时是 `(html)`）。

查找顺序（`tools/_gh.py`）：

```text
GITHUB_TOKEN / GH_TOKEN 环境变量
  → $DSH_HOME/.env                    ← 本机用的就是这个
  → $FNDEPOT_GH_TOKEN_FILE
  → ~/.config/fndepot/token
  → 仓库根目录 .gh_token              （已 gitignore）
```

**不要把 token 写进命令行、回复或提交里**（会留在 shell 历史 / 会话日志 / git 记录中）。
如果哪天要临时换一个 token，放到仓库根的 `.gh_token`（权限 600）即可，它已被 `.gitignore` 忽略：

```bash
cd /vol1/@team/公共/FnDepot
umask 077; printf '%s' '把token粘贴在这里' > .gh_token
```

验证（不会打印 token 本身）：

```bash
curl -s -H "Authorization: Bearer $(cat .gh_token)" https://api.github.com/rate_limit | jq .rate
# limit 应为 5000；返回 Bad credentials 则说明 token 抄错或已过期
```

建议用 **fine-grained token 且只给公开仓库的只读权限**（公开仓库的读接口对 classic token 也无需任何 scope），并设一个有效期。
配错或过期时脚本会明确报 `401`，并自动退回不耗配额的路径，不会因此中断。

## 新增 / 更新一个应用

**常规做法：一条命令**（给链接就行，不需要图标、不需要下载包）

```bash
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890   # 直连不通时
python3 tools/add-app.py <仓库链接> -c 系统工具          # dry-run，先看要写什么
python3 tools/add-app.py <仓库链接> -c 系统工具 --write   # 确认后落盘（自动备份 fnpack.json.bak）
```

`add-app.py` 会自己完成：取最新 tag 与 `.fpk` 资产 → 取官方 `sha256` digest 与 `content-length`
→ 读作者仓库里的 `manifest`/`config/privilege`（版本须与 tag 一致）→ 组装条目。
元数据读不到 manifest 时退回 README + 资产名推导，**会把"哪些字段是猜的"打印出来**。

底层工具（需要指定 tag / 本地包实测哈希等特殊情况才用）：

```bash
# 读仓库 manifest + API digest，不下整包
python3 tools/new-entry.py <owner/repo> <tag> <asset文件名> -c 系统工具 --light

# 下载整包后本地实测 sha256（大包先用 curl 续传）
curl -fL -C - --retry 8 --retry-all-errors -o /tmp/pkg.fpk <下载地址>
python3 tools/new-entry.py <owner/repo> <tag> <asset文件名> -c 系统工具 --local /tmp/pkg.fpk
```

（以上都需加 `--write` 才落盘。）

**不需要**手工补图标：所有应用统一 `assets/icons/fnapp.png`。
`maintainer_url` / `bug_report_url` 之类非必填项拿不到就不管。

## 自动推送

本仓库已配好 git 凭据助手 `tools/git-credential-fndepot`：它**实时**从 `tools/_gh.py` 取 token
（即 `$DSH_HOME/.env` 里的 `GITHUB_TOKEN`），**不把 token 写进 `.git/config`，也不写 `.git-credentials`**。

```bash
git config credential."https://github.com".helper "!$PWD/tools/git-credential-fndepot"
git config credential."https://github.com".username bekafka
```

配好之后提交完直接推即可（实测直连可用，不必带代理参数）：

```bash
git push origin main
```

推送前建议先看差异：`git log --oneline origin/main..HEAD`。
注意 token 是 classic PAT（含写权限）；若换成只读 token，推送会失败而读取不受影响。

几个约定：

- **双架构应用**：对每个架构各跑一次 `--write`，同版本的另一个架构会并进 `packages`，`platform` 自动取并集。
- **安装空间**默认 `""`＝存储空间；只有会写 `/boot`、注册 systemd 服务的应用才加 `--install-type root`
  （可参考作者自带 FnDepot 源里的写法交叉验证）。
- 更新已有应用时，脚本会保留手工维护的 `icon_url` / `maintainer_url` / `bug_report_url` 与安装空间设置。
- **图标**：统一用 `assets/icons/fnapp.png`（所有应用都一样，不必为每个应用单独找图标）。
- **版本**：只从首次收录算起；跟版时追加新版本节点并保留已收录版本，不回溯补历史。

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
