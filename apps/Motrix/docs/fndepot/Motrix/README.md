# Motrix · 飞牛 fnOS 版

全功能下载管理器 **Motrix** 的 Server 版（Web 面板），以原生进程跑在飞牛 fnOS 上：支持 HTTP / FTP / BT / 磁力，
内核是官方 aria2 fork（`motrixapp/aria2`，带 SQLite 持久化），任务与设置在重装后保留。

> 第三方打包（bekafka），上游项目：[agalwood/Motrix](https://github.com/agalwood/Motrix)（MIT）。
> 本包 = 上游 v2.0.0-beta.49 的服务端产物，未修改上游业务逻辑。

## 功能

- Web 面板：仪表盘（速度/任务/活动热力图）、下载列表、Tracker、插件
- HTTP / FTP / BT / 磁力，多线程分片、限速、代理、DHT / LPD、Tracker 订阅
- 任务库与设置持久化（SQLite），卸载重装不丢
- 可选媒体合并插件（使用系统 `ffmpeg`，本机已探测可用）

## 安装与使用

1. App Center 安装后启动，点桌面图标（或浏览器打开 `http://<NAS_IP>:26800/`）
2. **无需登录**：本包已关闭 operator 口令，打开即用
3. 默认下载目录：`/vol1/@appshare/Motrix/downloads`（在飞牛「文件」里可见）
4. 端口：Web **26800**（安装向导里可改）；MDXP 16801（浏览器扩展/CLI 配对用）

## 数据与目录

| 路径 | 内容 |
|---|---|
| `/vol1/@appshare/Motrix/downloads` | 下载的文件（目录 0755 / 文件 0644，其他应用可读） |
| `/vol1/@appdata/Motrix/data` | 任务库、设置、aria2 会话/DHT 状态、插件 |
| `/vol1/@appdata/Motrix/info.log` | 运行日志（超过 5MB 自动轮转为 `info.log.1`） |

## 说明与限制

- 界面首次安装默认**简体中文**（可在「设置 → 外观 → 语言」改）。
- 关闭登录口令意味着**能访问该端口的人都能操作下载**；请只在可信局域网使用，或自行加反代认证。
- BT 监听端口默认 6881；被其他应用占用时会自动改用下一个空闲端口（写入应用设置）。
- 只提供 **arm64**（飞牛设备目前均为 aarch64）。
- 上游仍是 beta，升级前建议先备份下载目录与 `/vol1/@appdata/Motrix`。

## 卸载与升级

卸载时飞牛会弹出选择：

- **保留配置卸载**（默认）：任务库、设置、插件都留着，重装后继续用；
- **完全卸载**：删除任务库、设置、插件、日志与口令文件。

两种方式都**不会删除** `/vol1/@appshare/Motrix/downloads` 里的下载文件。
- 升级：应用内「检查更新」不适用（Server 版不支持自更新），由本应用的新版本包更新。

## 溯源

- 上游：agalwood/Motrix `v2.0.0-beta.49`
- 服务端产物：官方镜像 `motrixapp/motrix-server:2.0.0-beta.49`（linux/arm64，manifest `sha256:01b23a25…`）
- 重新 stage：上游 `scripts/stage-server-app.mjs --libc gnu`（better-sqlite3 换 glibc prebuild）
- 验收：上游 `scripts/verify-server-package.mjs --libc gnu`
- aria2c：`motrixapp/aria2` v1.37.0-motrix.17（lockfile 校验 sha256，AArch64 静态）
- `motrix-finalize-fs`：上游源码 + [飞牛兼容补丁](https://github.com/bekafka/motrix-fpk/tree/main/packaging/patches)（`open_root` 的 `O_PATH` 回退），在 `rust:1.94.1-alpine` 内构建
