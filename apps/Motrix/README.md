# motrix-fpk · Motrix Server 的飞牛 fnOS 应用包

把上游 [agalwood/Motrix](https://github.com/agalwood/Motrix) 的 **Server 版**（最新 beta）做成飞牛 fnOS 可安装的
`Motrix.fpk`，**以原生进程运行**（不用 Docker），内核是官方 aria2 fork `motrixapp/aria2`，Web 面板由 Node 提供。

```
上游 agalwood/Motrix          本仓库 motrix-fpk                    打包厂 + 索引
├── v2.0.0-beta.49            ├── packaging/Motrix/  (fpk 模板)     bekafka/fpk-factory
├── 官方 server 镜像    ──▶   ├── packaging/build.sh (payload 生产线) │  _build-fpk.yml
│   motrixapp/motrix-server    ├── packaging/patches/  (fnOS 补丁)   bekafka/FnDepot
└── motrixapp/aria2            └── .github/workflows/release.yml  ──▶ 索引元数据
```

## 包里放的是什么字节，从哪来

| 内容 | 来源 | 说明 |
|---|---|---|
| `server/dist/**`（服务端 JS + Web 面板 + 内置插件 + legal） | **官方 arm64 镜像** `motrixapp/motrix-server:<version>` 里上游已构建好的产物 | 镜像 manifest digest 记进 `app/PROVENANCE.json` |
| `server/node_modules/**` | 用上游 `scripts/stage-server-app.mjs --libc gnu` 重新 stage | 关键：把 better-sqlite3 的 **musl** prebuild 换成 **glibc** prebuild |
| `server/bin/aria2c` | 上游 release `motrixapp/aria2` v1.37.0-motrix.17 | `scripts/fetch-engine.mjs` 下载并按 `engine.lock.json` 校验 sha256；AArch64 **static-pie** |
| `server/bin/motrix-finalize-fs` | **上游源码 + 本仓库补丁**，在 `rust:1.94.1-alpine` 里构建 | 见下节「为什么必须打补丁」 |
| `server/LICENSE`、`THIRD_PARTY_*`、`legal/` | 上游随包提供 | MIT，再分发需保留这些文件 |

**整个 payload 零编译产出，且通过上游自己的校验器** `scripts/verify-server-package.mjs --libc gnu`
（校验目标架构、原生件无外来架构、体积预算、externals 可解析、stage 清单指纹逐条对账）。

## 为什么必须打一个补丁

上游 `motrix-finalize-fs`（下载完成后安全收尾改名的辅助进程）在 `open_root()` 里**从 `/` 逐级
`open(O_RDONLY|O_DIRECTORY)`**。飞牛 fnOS 的内核 `trimacl` 层只允许应用用户**穿过**数据卷根目录
（`/vol1` 对应用用户是可执行、不可读），于是：

```
Failed to commit finalized file: open_root: Permission denied (os error 13)
```

文件其实已经下载完成（留在 `<名字>.motrix` 临时名下），但**永远改不成最终名**，任务状态 `error`。

本仓库的补丁（[`packaging/patches/finalize-fs-open-root-o_path.patch`](packaging/patches/finalize-fs-open-root-o_path.patch)）让这条路径在
遇到 `EACCES/EPERM` 时把**中间目录**回退成 `O_PATH`（`O_PATH` 描述符足以支撑后续
`openat`/`renameat2`/`linkat`/`statx`），最终目录仍优先用可读句柄打开 —— 普通文件系统上行为完全不变。

实测旁证（同一台设备）：

| 做法 | 结果 |
|---|---|
| 原始二进制 + 应用用户 | `open_root: Permission denied`，任务 error |
| 给应用用户 `setfacl -m u:Motrix:r-x /vol1` | 无效 —— fnOS 的 `trimacl` 覆盖 POSIX ACL |
| 给 sidecar `setcap cap_dac_read_search+ep` | 无效 —— 能力同样不被采纳 |
| 应用用户加入 `Users` 组 | 仍读不了 `/vol1` |
| **整个应用以 root 运行** | 可以（但没必要把网络服务跑成 root） |
| **本补丁（应用仍是 `package` 用户）** | ✅ 端到端 2 秒落盘、sha256 一致 |

## 目录结构

```
packaging/Motrix/          fnOS 包模板（manifest / config / cmd / wizard / ui / 图标）
packaging/build.sh         payload 生产线（fpk-factory 的 _build-fpk.yml 调用它）
packaging/tools/oci-extract.py  不依赖 docker 的镜像取件（Registry API + 按层解包 + whiteout）
packaging/patches/         upstream 源码补丁
build-local.sh             本地一键出包（等价于 CI）
tests/motrix-accept.sh     设备上的验收阶梯（endpoints / auth / e2e / lifecycle）
```

## 本地出包

```bash
# 依赖：git / node>=20 / pnpm / python3 / docker(打补丁用)
ARCH=arm64 VERSION=2.0.0-beta.49 \
  CHANGELOG="说明文字" \
  bash build-local.sh
# 产物：dist/Motrix-<version>-arm.fpk + .sha256
```

x86_64 机器上打 arm64 包时，若没有能跑 arm64 容器的运行时，可先把补丁版 sidecar 在别处构建好：

```bash
MOTRIX_FINALIZE_FS_BIN=/path/to/patched/motrix-finalize-fs \
  ARCH=arm64 VERSION=2.0.0-beta.49 bash build-local.sh
```

## 安装 / 验收

```bash
# 设备（root）：
appcenter-cli install-fpk Motrix-2.0.0-beta.49-arm.fpk --env config.env
appcenter-cli start Motrix
# 验收阶梯：
bash tests/motrix-accept.sh all
```

打开 Web 面板**不需要登录**（默认已关闭 operator 口令）：局域网内直接访问
`http://<NAS_IP>:26800/` 或从飞牛桌面点图标即进面板（**默认端口 26800**，安装向导里可改）。

> 想恢复上游的「解锁页 + 口令」：构建时加 `AUTH_MODE=token`，装好后
> `sudo cat /vol1/@appdata/Motrix/data/operator-token` 取口令。

## 关键设计

- **首次安装默认中文**：启动就绪后由 `cmd/main` 调一次应用自己的 RPC（`command:updateSettings`
  → `app.language=zh-CN`），并落 `${TRIM_PKGVAR}/.language-init` 标记，只做一次；用户之后自己改语言不会被覆盖。
- **默认端口 26800**（向导里可改）：避开 8080 这种热门端口；`config.env` 里落实际值，入口与就绪探测都读它。
- **运行身份 `package`**（专用应用用户 `Motrix`），不碰 root，不需要能力/ACL 特权。
- 运行时用飞牛官方 **`nodejs_v24`**（`install_dep_apps=nodejs_v24`），不打包 Node，省 ~30MB。
- 下载目录用官方 **`data-share`** 机制：`/vol1/@appshare/Motrix/downloads`（文件里可见，应用用户与管理员都有权限）；
  额外目录可在安装向导/应用设置里填（会做「绝对路径 + 应用用户可写」校验，不合规的只记日志不启用）。
- **默认关闭登录口令**（`AUTH_MODE=open`）：上游没有关闭开关，构建期对 `dist/server/index.mjs` 做一处
  字符串改写（`packaging/tools/disable-operator-auth.mjs`），让 `createApp()` 不注册 operator 鉴权 →
  解锁页消失、`/rpc/*` 与 `/api/*` 开放、`/rpc/events` 实时通道照常。锚点必须命中 1 次，否则构建直接红。
  代价：**能访问该端口的人都能操作下载**（个人局域网可接受，公网/不可信网络请走反代 + 认证）。
- `AUTH_MODE=token` 保留上游默认：这时才会运行 `packaging/tools/patch-renderer-hint.mjs`，把解锁页文案里
  写死的 `MOTRIX_OPERATOR_TOKEN` 提示换成本机真实口令路径。
- **下载文件权限**：飞牛的 data-share 权限层会把应用新建的文件强制成 `0700`（连 `touch` 都一样，umask 无效），
  其他应用用户读不了。`cmd/main` 启动时把目录修成 `0755`、文件修成 `0644`，并起一个随服务存活的轮询
  （默认 30s）修新文件 —— 这样 Jellyfin / Plex 这类应用才取得到刚下载的文件。可用
  `MOTRIX_FIX_PERMISSIONS=0`（写进 `config.env`）关掉。
- **日志轮转**：`info.log` 超过 5MB（`MOTRIX_LOG_MAX_BYTES`）就轮转为 `info.log.1`，只留一份。
- **引擎端口自愈**：启动前检查 `settings.json` 里的 aria2 RPC 端口（16800）与 BT 监听端口（6881），
  被外来进程占用就自动改用下一个空闲端口并写回设置，不再直接 fatal 退出。
- **内存上限**：node 以 `--max-old-space-size=512` 启动（实测常驻 ~139MB），避免在 3~4GB 的机器上失控。
- `cmd/main` 加固：pid 文件 + `/proc/<pid>/exe` 归一化身份校验 + 按 **exe** 清理孤儿
  （`aria2c` / `motrix-finalize-fs` 是独有二进制；**node 的进程名是 `MainThread`，不能用 `pgrep -x node`**）；
  就绪判据是应用自己的 `/healthz`，端口现读 `config.env`；启动失败会回收自己拉起的进程。
- `checkport=false`、不写 `service_port`：**安装向导 / 应用设置页只问一个 Web 端口**（其余端口/开关在
  `config.env` 里调），
  `app/ui/config` 的 `${wizard_port}` + `install_callback`/`config_callback` 里的兜底重写保证桌面入口跟着走；
  端口被占用时安装照常完成，但日志会写明占用者（应用启动会因此失败，换端口即可）。
- **桌面入口用 `type: iframe`**：在飞牛桌面窗口内打开，不跳新标签页（服务端没有 `X-Frame-Options`/CSP
  `frame-ancestors`，实测可内嵌）。

## FnDepot 上架素材

`docs/fndepot/` 里是索引仓库要用的整套素材（图标、三张 1600x1000 实机截图、应用页 README）以及上架命令，
见 [docs/fndepot/README.md](docs/fndepot/README.md)。

## 卸载

飞牛的卸载向导里二选一：

- **保留配置卸载**（默认）：`/vol1/@appdata/Motrix` 里的任务库、设置、插件、日志全部保留，重装即接着用；
- **完全卸载**：删掉上述应用数据（含口令文件），下载目录 `/vol1/@appshare/Motrix/downloads` 里的文件**不动**。

实现在 `wizard/uninstall`（radio，字段 `wizard_uninstall_mode`）+ `cmd/uninstall_callback`
（`purge` 才会删，且只删 `/vol1/@appdata/*` 前缀下的内容，路径不符就跳过）。

## 已知限制

- 只出 **arm64**（`release.yml` 的 matrix 单架构；x86 只需加一行）。
- `wizard/config`（应用设置页）与桌面入口的点击体验需要人工过一遍（自动化已覆盖端口重写逻辑）。
- 上游是 beta 版，release notes 自己要求先备份数据；本包不代替备份。
- MDXP（16801）默认对局域网监听，用于浏览器扩展/CLI 配对；明文 HTTP 配对需在向导里显式打开
  `MOTRIX_ALLOW_INSECURE_OPERATOR_HTTP`（默认关闭）。
