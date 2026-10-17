# 交付说明 · Motrix fpk v1（2026-10-17）

## 1. 交付物

| 文件 | 大小 | SHA256 |
|---|---|---|
| `dist/Motrix-2.0.0-beta.49-arm.fpk` | 15,724,744 B (15.0 MiB) | `4e7ce7c2de469bd7022f0150fb5b490e1393ab1556e02138a182d9a04f3efc0b` |

- 目标平台：**arm**（飞牛 fnOS / aarch64 / glibc 2.36）
- 包内 `appname = Motrix`，`display_name = Motrix`，`version = 2.0.0-beta.49`，`platform = arm`
- 依赖项：`install_dep_apps = nodejs_v24`（飞牛官方运行时 24.13.1）

### payload 溯源（同时写在包内 `app/PROVENANCE.json`）

| 项 | 值 |
|---|---|
| 上游 | agalwood/Motrix **v2.0.0-beta.49** |
| JS/Web/内置插件/legal | 官方镜像 `motrixapp/motrix-server:2.0.0-beta.49` (linux/arm64) |
| 镜像 manifest digest | `sha256:01b23a250e0a1e8539839d4f5d71a99b88a76227d2864f42d7838d6041289803` |
| 重新 stage | 上游 `scripts/stage-server-app.mjs --platform linux --arch arm64 --libc gnu --strict` |
| 上游验收 | `Verified Server linux-arm64-gnu: 49434235 bytes, 130 packages` |
| aria2 内核 | `motrixapp/aria2` v1.37.0-motrix.17（`scripts/engine.lock.json` 锁 sha256），AArch64 static-pie |
| finalize-fs | 上游源码 + 本仓库补丁，在 `rust:1.94.1-alpine` 内构建；sha256 `c32d4d59697f1451238387bbda4704fd6239373e02957c3a67dbb7543abd1c08` |
| 运行 crate 体积 | 49,379,260 B / 2955 文件（stage 清单自述），tar.gz 后 ~15MB |

## 2. 与最初方案的差异（就一处，但是必须的）

方案里 finalize-fs 是「从官方镜像里取那份静态产物」。实机验证发现**取来直接用会失败**：

```
$ createTask -> {"outcome":"created", ...}
任务状态：error
errorMessage: Failed to commit finalized file: open_root: Permission denied (os error 13)
产物：/vol1/@appshare/Motrix/downloads/sample.bin.motrix     ← 下完了，但改不成最终名
```

根因（逐项实测排除，见 README 的同名表格）：上游 `open_root()` 从 `/` 逐级 `O_RDONLY|O_DIRECTORY`，
而飞牛 fnOS 的内核 `trimacl` 层对应用用户只给 `/vol1` 的**执行（穿过）**权限，不给读权限；
POSIX ACL（`setfacl`）、文件能力（`setcap`）、加入 `Users` 组**全都不生效**（`trimacl` 覆盖它们）。
把整个应用改成 root 能绕过，但没有必要。

**处置**：给 `open_root` 打 30 行补丁 —— 中间目录遇 `EACCES/EPERM` 回退 `O_PATH`，最终目录仍优先
打开成可读句柄；普通文件系统上行为不变。补丁在 [`packaging/patches/`](packaging/patches/)，由
`packaging/build.sh` 在构建时 `git apply` 并用 alpine Rust 镜像编译。**应用仍以 `package` 用户运行。**

## 3. 实机验收（飞牛测试机 192.168.2.22，全新安装）

`tests/motrix-accept.sh all` → **PASS=15 FAIL=0**

| 级 | 判据 | 结果 |
|---|---|---|
| 1 | `appcenter-cli status` = running | ✅ running |
| 2 | `/healthz`、首页、`/assets/*.js`、局域网 IP 访问 | ✅ 全 200（局域网 `http://192.168.2.22:8080` 实测 200） |
| 3 | 无 token `/api/diagnostics` = **401**；带 token = 200；口令文件 0600 | ✅ |
| 4 | 端到端下载：RPC `command:createTask` → 3MiB 文件落到 `/vol1/@appshare/Motrix/downloads`，sha256 一致 | ✅ 2 秒，属主 `Motrix:Motrix` |
| 5 | stop → 端口释放、无残留 node/aria2c/finalize-fs；start → 1 秒重新就绪；口令不重新生成 | ✅ |
| 6 | 卸载 → 重装：`/vol1/@appdata/Motrix`（含 SQLite、口令、插件）与 `/vol1/@appshare/Motrix/downloads` 原样保留 | ✅ 口令 sha 未变、marker 文件仍在、下载文件仍在 |

补充证据（浏览器实测，截图曾放在 `docs/screenshots/`，现已并入 `assets/Motrix/Preview/`）：

- 局域网 `http://192.168.2.22:8080/` 首屏是 **Unlock Motrix** 解锁页（提示从 `<dataDir>/operator-token` 取口令）。
- 粘贴口令 → 进入完整面板：ENGINE **Ready**（`aria2 v1.37.0`）、侧栏 Dashboard/Downloads/Trackers/Plugins/Settings、
  TRANSFER 统计（Today 608.77 MiB，即前述验收下载的量）。

其他证据：

- 引擎自检（`/api/diagnostics` 带 token）：`engine.state=ready`、`version=1.37.0-motrix.17`、
  `hasSqlitePersistence=true`、自动探测到系统 `ffmpeg 8.1.1-mediasrv`（媒体合并插件前置条件具备）。
- `ss -ltnp`：`0.0.0.0:8080`（Web/API）、`0.0.0.0:16801`（MDXP）由 `nodejs_v24` 的 node 持有，
  引擎 RPC `127.0.0.1:16800` 仅回环。
- 优雅退出：`SIGTERM` → 日志 `shutting down` → `aria2 process exited` (code 0)，无孤儿。

## 3.5 2026-10-17 上午的三处改动（已重打包并重装验证）

| 改动 | 落点 | 验证 |
|---|---|---|
| **取消 `MOTRIX_OPERATOR_TOKEN`**：向导删掉「登录口令」字段，脚本不再写 `operator-token.env`、`cmd/main` 不再导出该变量 | `wizard/install`、`wizard/config`、`app/apply-config.sh`、`cmd/main` | 重装后进程环境里 `MOTRIX_OPERATOR_TOKEN` 计数为 **0**；口令文件仍是自动生成那份（sha 未变），解锁照常 |
| **端口在向导里自定义**：Web 端口 + MDXP 端口（默认 8080 / 16801，MDXP 填 0 关闭），带数字/范围校验；安装时若端口被占，把占用者写进日志 | `wizard/install`、`wizard/config`、`app/apply-config.sh` | 安装后向导字段核对通过；`config.env` 正确落盘 |
| **桌面入口改为内页打开**：`type: url` → `type: iframe` | `app/ui/config` | 安装后入口 `type=iframe`；用浏览器把应用嵌进 `<iframe>` 实测能正常渲染解锁页（服务端无 `X-Frame-Options`/CSP 拦截）；验收阶梯 15/15 仍全过 |

> 说明：解锁页上那句 "set MOTRIX_OPERATOR_TOKEN" 是**上游前端自带文案**，我们没改 JS 包；本包只是不再提供/
> 使用该变量，口令一律走文件。想手动指定口令仍然可以自己 `export MOTRIX_OPERATOR_TOKEN=...` 后重启。

## 3.6 2026-10-17 第二轮改动（解锁页文案 + 向导精简）

| 改动 | 落点 | 验证 |
|---|---|---|
| **解锁页不再出现 `MOTRIX_OPERATOR_TOKEN`**：上游把这条提示写死在渲染包里（26 种语言各一份），改由构建期打补丁 —— `help`/`error` 两条文案换成本机真实路径 `sudo cat /vol1/@appdata/Motrix/data/operator-token`，其余零散提及改成 `operator-token` | 新增 `packaging/tools/patch-renderer-hint.mjs`，`build.sh` 在 stage 前调用；补丁后自检，残留即 `exit 7` | 安装后 `grep -rl MOTRIX_OPERATOR_TOKEN …/renderer-web` = **0**；浏览器实测解锁页文案已变（该截图已随口令模式下线删除） |
| **安装向导只留一个端口**：删掉 MDXP 端口 / 扩展配对开关 / 额外下载目录三个字段，只保留 `Web 面板端口` | `wizard/install`、`wizard/config` | 安装后向导字段核对：只有一个 `wizard_port` |

> 注：MDXP 端口（16801）、明文 HTTP 配对开关、额外下载目录**上游面板里没有入口**，去掉向导后仍可在
> `/vol1/@appdata/Motrix/config.env` 里改（脚本照旧读这三个键，缺省即默认值），改完重启应用生效。

## 4. 用法

```
App Center → Motrix → 启动 → 打开
登录口令：sudo cat /vol1/@appdata/Motrix/data/operator-token
默认下载目录：/vol1/@appshare/Motrix/downloads（飞牛“文件”里可见）
端口：Web 8080 / MDXP 16801（安装向导与应用设置页可改；MDXP 填 0 关闭）
```

卸载不会删数据；重装沿用原来的口令、任务库与下载目录。回滚 = 卸载后装回旧版本 fpk。

## 5. 未覆盖 / 待办

| 项 | 说明 |
|---|---|
| 桌面入口点击体验 | 入口配置（`app/ui/config`，`${wizard_port}` + 回调兜底重写）已就位并在日志里确认端口同步；浏览器侧已实测解锁 + 面板渲染（见 `assets/Motrix/Preview/`），但“从飞牛桌面点一下”仍建议人工过一眼 |
| 应用设置页改端口 | `config_callback` 逻辑已实现（含“改前是否在跑”判断），未在 UI 上实测；口令已不再由本包提供 |
| `--env` 之外的交互式安装 | 本次用 `appcenter-cli install-fpk --env` 静默装；UI 上填向导未实测 |
| x86 包 | 生产线已参数化（`ARCH=amd64` + linux/amd64 镜像 + x64 aria2c + x86_64 sidecar），未实打 |
| 升级路径 | 尚无第二版可升；升级流程与卸载重装同构，`upgrade_callback` 已实现 |
| CI 首次真跑 | `release.yml` 指向 `bekafka/fpk-factory`，**该仓库与 `bekafka/FnDepot` 在 GitHub 上还不存在**；FnDepot 也要先 `tools/add-app.py` 首次收录，否则发布模块按设计直接失败 |
| 本机 x86_64 上打 arm64 包 | 需要 `MOTRIX_FINALIZE_FS_BIN=` 指向已构建好的补丁版 sidecar（本机没有 arm64 容器能力）；CI 的 arm64 runner 上 docker 原生构建，无需该开关 |

## 6. 测试期在设备上留下的东西

- 应用 `Motrix` 处于 **running**（测试机上的正式安装，非临时目录），数据在 `/vol1/@appdata/Motrix`、
  下载目录 `/vol1/@appshare/Motrix/downloads`（已清空测试文件）。
- 早期试验用的 `/vol1/app/motrix-lab/` 与 `/root` 下的临时脚本、`/root/motrix-finalize-fs.orig`
  （官方 sidecar 备份）已清理；`/root/motrix-config.env`（安装向导用的 env 文件）保留，便于重装。
- 未改任何系统级配置：`/vol1`、`/vol1/@appshare` 上试验用的 `setfacl` 条目已 `setfacl -x` 撤销，
  `Motrix` 用户已从 `Users` 组移除，sidecar 上的 `setcap` 能力随文件被替换而消失。
- `/root/Motrix-2.0.0-beta.49-arm.fpk` 留了一份，便于在设备上直接重装。

---

## 3.7 2026-10-17 第三轮改动（按要求彻底取消登录口令）

| 改了什么 | 落点 | 实测 |
|---|---|---|
| **关闭 operator 口令鉴权**：unlock 页不再出现，`/rpc/*`、`/api/*` 直接可用 | 新增 `packaging/tools/disable-operator-auth.mjs`，`build.sh` 新增 `AUTH_MODE=open|token`（默认 `open`）；它把镜像里那份 `dist/server/index.mjs` 的 `operatorAuth:{operatorToken:` 改写成 `operatorAuth:(void 0)&&{operatorToken:`，让 `createApp()` 走上游自带的「未注册鉴权」分支（`/rpc/auth/status` 返回 `{authed:true,mode:"unrestricted"}`） | 见下 |
| 向导提示、安装日志、manifest 描述同步改成「打开即用」 | `wizard/install`、`wizard/config`、`cmd/install_callback`、`manifest` | 安装日志："已关闭登录口令，打开 Web 面板即用" |
| 解锁页文案补丁只在 token 模式跑 | `build.sh` | `AUTH_MODE=open` 时不再执行 `patch-renderer-hint.mjs` |
| 鉴权模式随包落盘，供安装脚本/验收脚本判断 | `build.sh` → `app/AUTH_MODE`；`build-local.sh` 一并拷进工作区 | 设备上 `/vol1/@appcenter/Motrix/AUTH_MODE` = `open` |

**实测证据（全新卸载重装后，`tests/motrix-accept.sh all` → PASS=16 FAIL=0）**

```
$ curl -s http://127.0.0.1:8080/rpc/auth/status
{"authed":true,"mode":"unrestricted","canLogout":false}      ← 渲染端看到 authed 就跳过解锁页
$ curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/diagnostics
200                                                          ← 无凭据直接可用（按设计开放）
[PASS] /rpc/auth/status = authed/unrestricted（无解锁页）
[PASS] 无凭据直接访问 /api/diagnostics = 200（按设计开放）
[PASS] 首页不再要求解锁
[PASS] 端到端下载 3MiB → /vol1/@appshare/Motrix/downloads，sha256 一致（2s）
[PASS] stop/start 生命周期、无残留进程、任务库仍在
```

**安全边界（重要）**：关闭后，任何能访问 `8080` 的人都能控制下载、看任务列表，也能审批浏览器扩展配对。
个人局域网可接受；若经飞牛网关或公网暴露，请自行加反代认证 / 防火墙，或改用 `AUTH_MODE=token` 重新打包。
MDXP（16801）本身仍有自己的 token，不受影响。

**回退**：`AUTH_MODE=token` 重新出包即可（其余字节完全不变）。当时的解锁页截图
（口令模式下的解锁页截图已删除；`assets/Motrix/Preview/1-dashboard.png` 是关闭口令后的中文面板实拍。）

**产物**：本轮的 fpk 为 `dist/Motrix-2.0.0-beta.49-arm.fpk`
（15,716,748 B，sha256 `91824cfb60aa2b0f770b3469765a6eddba13b3a6659de04a07c6f95bd7e4e62b`）。

---

## 3.8 2026-10-17 第四轮改动（默认端口 / 向导精简 / 默认中文）

| 需求 | 落点 | 实测 |
|---|---|---|
| **默认端口 8080 → 26800**（自定义端口保留） | `wizard/install`、`wizard/config` 的 `initValue`；`app/apply-config.sh` 与 `cmd/main` 的兜底值；验收脚本默认值 | `config.env` = `MOTRIX_PORT=26800`；`0.0.0.0:26800` 监听、8080 不再监听；`/healthz` 200 |
| **删掉端口字段下面那行小提示** | `wizard/install` 只剩一个端口字段（无 tips）；`wizard/config` 只保留"保存后会重启"那条 | 安装后 `cat /var/apps/Motrix/wizard/install` 核对 |
| **首次安装界面语言默认中文** | `cmd/main` 新增 `init_default_language()`：服务就绪后调 `POST /rpc/command/command:updateSettings` `{"app":{"language":"zh-CN"}}`，成功后落 `${TRIM_PKGVAR}/.language-init`（只做一次，用户后续改语言不被覆盖） | `query:getSettings` → `app.language = zh-CN`；marker 已生成；zh-CN 文案是随主包内置的（不额外拉 chunk） |

复验：卸载 → 重装（`--env` 只给 `wizard_port=26800`）→ `tests/motrix-accept.sh all` → **PASS=16 FAIL=0**
（端点 / 无解锁页 / 端到端下载 / 启停与孤儿 / 任务库保留 全过）。

**产物**：`dist/Motrix-2.0.0-beta.49-arm.fpk`
15,719,380 B，sha256 `d005306bdba283d4395b8b215d02e78c6d888d2018501ace83787ef568a7fc03`。

> 说明：语言这一步不需要改上游代码 —— 语言是存在应用设置里的（`MOTRIX_HOST_LANGUAGE` 只影响服务端/插件 locale），
> 所以走它自己的设置接口最稳，也不用再维护一处补丁。

---

## 3.9 2026-10-17 第五轮改动（运维三项 + 素材）

### A 类（行为修复，均有实测）

| 问题 | 根因 | 处置 | 实测 |
|---|---|---|---|
| 下载文件 `0700`，其他应用读不了 | **飞牛的 data-share 权限层**会把新建文件强制成 `0700`（`touch`/重定向/aria2 直写都一样，umask 0022 无效）；`chmod` 能生效 | `cmd/main` 启动时 `find … ! -perm -o+rx` → 目录 `0755`、文件 `0644`；并起一个跟随 node 进程的 30s 轮询修新文件（`perm-fix.pid`，stop 时收掉） | 目录 `755`、文件 `755/644`；`sudo -u Aria2/CloudSaver` 读 succ；下线开关 `MOTRIX_FIX_PERMISSIONS=0` |
| `info.log` 无上限 | 纯追加 | 启动时 >5MB 轮转为 `info.log.1`（只留一份） | 灌到 6.0M → 重启后 `info.log=8K`、`info.log.1=6.0M`，日志有"日志已轮转" |
| 16800/6881 被占 → 上游 fatal 退出 | 引擎端口来自 `settings.json`，上游不自愈 | 启动前读设置、探测端口，被占则挑下一个空闲（跳过 Web/MDXP 端口）并原子写回 `settings.json` | 占用 16800 后启动：日志"自动改用 16802"、`rpcPort=16802`、engine ready；6881 被 Aria2 应用占 → 自动 6882 |
| node 无堆上限 | 默认 | `--max-old-space-size=512` | `/proc/<pid>/cmdline` 含该参数；常驻 RSS ~139MB |

验收脚本新增「阶段 6：运维项」5 条断言（目录/文件权限、修正轮询存活、内存参数、日志轮转过），
`tests/motrix-accept.sh all` → **PASS=21 FAIL=0**。

### D 类

| 项 | 处置 |
|---|---|
| `fpk.py inspect` 把目录 `core` 当崩溃转储 | 已改本机 skill：`_sensitive_issue(path, is_dir)`，只有**文件** `core`/`*.core` 才算；两处调用点传 `path.is_dir()`/`member.isdir()`；补回归测试 `test_core_directory_is_allowed_but_core_file_is_rejected`（`test_archive` 25 passed）。改动记在 skill 的 `LOCAL-PATCHES.md`。当前 fpk `inspect` → **OK**。（skill 另有 2 个既有失败在 `test_bundled_toolchain`，与本改动无关，已核实还原后同样失败） |
| node 内存 | 见上（512MB 上限） |
| FnDepot 素材 | 新增 `assets/Motrix/`：`ICON.PNG`(256)、`Preview/{1-dashboard,2-downloads,3-settings}.png`（1600x1000，简体中文、无登录、引擎就绪，headless Chromium 实拍）与 `README.md`；`fnpack.json` 补 `preview_urls` / `readme_url` 指向它们 |

### 产物

`dist/Motrix-2.0.0-beta.49-arm.fpk` — 15,720,861 B，
sha256 `e432d09c2e74c57b3b45fd21e567a7b89b278ccce17465e141768e0fbe594d9d`。

> 备注：设备上 aria2 BT 监听端口现在是 `6882` —— 因为 6881 正被同机的 Aria2 应用占用，启动时自动换的（预期行为）。

---

## 4.0 2026-10-17 第六轮改动（卸载向导 + 素材清理）

| 需求 | 落点 | 实测 |
|---|---|---|
| 卸载时给「保留配置 / 完全卸载」两种方式 | 新增 `wizard/uninstall`：`radio` 字段 `wizard_uninstall_mode`，默认 `keep`，另一项 `purge`，附一条 tips（两种模式都不删下载文件）。`cmd/uninstall_init` 记录选择；`cmd/uninstall_callback` 执行：`purge` 只删 `$PKGVAR` 下的 `data/ home/ tmp/ config.env AUTH_MODE .language-init *.pid info.log*`，且**只认 `/vol1/@appdata/*` 前缀**，路径不符就跳过 | 脚本级：`purge` 后临时目录为空；`keep` 后 `data/motrix.db` 仍在。真实卸载（CLI 无 `--env`，走默认 keep）：`/vol1/@appdata/Motrix/data` 全部保留、`KEEP-MARKER` 未丢、下载目录仍在 |
| 删掉 `docs/screenshots/01-unlock.png` | 删除文件；NOTES 3.6/3.7 里对它的引用改成"该截图已随口令模式下线删除" | `grep -rn 01-unlock` = 0 |
| 顺手：旧的英文 `02-dashboard.png`（8080、带解锁步骤）已被替换成关闭口令后的中文面板实拍 | `docs/screenshots/02-dashboard.png` ← `docs/fndepot/Motrix/Preview/1-dashboard.png` | 见文件 |

验收脚本「阶段 6」新增一条：`/var/apps/<pkg>/wizard/uninstall` 存在且含 `wizard_uninstall_mode`。
`tests/motrix-accept.sh all` → **PASS=22 FAIL=0**。

> 说明：App Center 的卸载向导要在 UI 里点选才算全链路验过（CLI `uninstall` 不接受 `--env`，
> 无法非交互传 `wizard_uninstall_mode`）。向导 JSON 与回调逻辑已按规范实现并单测，
> "点一下卸载选『完全卸载』"留给你在应用中心过一次即可。

**产物**：`dist/Motrix-2.0.0-beta.49-arm.fpk` — 15,722,760 B，
sha256 `fc2087a1bf70fe5f23ffcffab143f8628cf9a96369a9e581c2b1a1b77e69c8e1`。

---

## 5.0 2026-10-17 上线 GitHub 自动化构建（双架构发布）

### 建仓与推送

| 仓库 | 内容 |
|---|---|
| `bekafka/motrix-fpk` | 应用包（模板 + payload 生产线 + release.yml，双架构矩阵） |
| `bekafka/fpk-factory` | 打包厂（可复用 workflow + specs/ + templates/ + scaffold/lint 工具） |
| `bekafka/FnDepot` | 索引（Motrix 已收录：元数据/图标/3 张预览图/README，`preview_urls`+`readme_url`） |

secret：`FNDEPOT_TOKEN` 已配置到 motrix-fpk。

### 发布结果（第七次运行全绿）

- **Release v2.0.0-beta.49**：`Motrix-2.0.0-beta.49-arm.fpk`（15,724,179 B，sha256 `222dc193…`）
  + `Motrix-2.0.0-beta.49-x86.fpk`（15,482,956 B，sha256 `05567d0d…`）
- **FnDepot 索引已写入**：platform `arm+x86`、两包 sha256/size/download_url 全齐；
  `verify.py` 全量通过（外链核对 2/2）
- **端到端复验**：从 Release 下载 arm 包 → sha256 与索引一致 → 装上测试 NAS →
  验收 22/22 PASS

### 六次失败与修复（全部沉淀进 fpk-factory/specs/pitfalls.md §13/§14）

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | 组装工作区 exit 1 | `find\|head` 的 SIGPIPE（payload >40 文件必现） | 管道加 `\|\| true` |
| 2 | arm Packing failed: Invalid version | **fnpack 1.2.4（设备自带 arm64）拒绝 `x.y.z-beta.N`**；1.2.3（amd64）不校验 | 统一用 amd64 1.2.3 |
| 3 | arm: Exec format error | arm64 runner 跑不了 amd64 ELF | 装 `qemu-user-static` 经 binfmt 执行 |
| 4 | 准备工具 exit 141 | `./fnpack --help \| head -2` 又一个 SIGPIPE | 同 #1 |
| 5 | release: not a git repository | 可复用 workflow 的 release job 没 checkout（`gh` 需要仓库上下文） | job 里补 checkout |
| 6 | Invalid format '"x86": {' | `$GITHUB_OUTPUT` 多行 JSON 必须用 heredoc 定界符 | 改 `key<<EOF` 格式 |

### 日常发布方式

```bash
git tag v2.0.0-beta.50 && git push origin v2.0.0-beta.50     # 跟上游新版本
# 或手动：Actions → Release → Run workflow（填 version/changelog）
```

---

## 6.0 2026-10-17 迁移到集中式模型（FnDepot 应用源码 + FnFactory 构建）

### 仓库拓扑变化

| 之前（分散） | 现在（集中） |
|---|---|
| `bekafka/motrix-fpk` 应用仓库 | **删除用途**：README 已标注废弃 |
| `bekafka/fpk-factory` 打包厂 | **改名 `bekafka/FnFactory`** |
| `bekafka/FnDepot` 索引 | FnDepot = 索引 + **所有应用源码**（`apps/<App>/`） |

Motrix 源码现在位于：<https://github.com/bekafka/FnDepot/tree/main/apps/Motrix>
（`package/` 模板 + `packaging/` 生产线 + `tests/` + `docs/`）

### 发布链路

```
FnDepot/.github/workflows/build-app.yml （Build App，手动填 app_key/version/changelog）
  └─ uses: bekafka/FnFactory/.github/workflows/_build-fpk.yml@main
        ├─ build（arm64 + amd64 矩阵）
        ├─ release  → FnDepot 自己的 Release（tag: Motrix-v<version>）
        └─ publish  → 写回 FnDepot 的 fnpack.json（用 GITHUB_TOKEN，无需 PAT）
```

### 迁移中踩的两个坑（已修，均沉淀到 FnFactory）

| 症状 | 根因 | 修法 |
|---|---|---|
| 注入 manifest 报 `sed: unknown option to 's'` | changelog 里含 `/` 和 `&`，`sed "s/…/${CHANGELOG}/"` 的分隔符被撞 | 改用 python 做字符串替换（无分隔符问题）；heredoc 内代码需缩进到块标量内 |
| 索引推送 `403 Permission denied to github-actions[bot]` | 两处都要 `contents: write`：**仓库级** Actions 默认权限 + **被调用 workflow** 的顶层 `permissions`（后者会把调用方给的权限收紧回 read） | `PUT /repos/{repo}/actions/permissions/workflow` 设 default=write；`_publish-index.yml` 顶层与 publish job 都写 `contents: write` |

### 已验证

- Run 39008523443 **全绿**：双架构 → Release `Motrix-v2.0.0-beta.49` → 索引回写 → verify.py 外链 2/2
- 从 FnDepot Release 下载 arm 包，sha256 与索引一致（`332ea32a…`），`inspect` OK
- 装上测试 NAS：验收 **22/22 PASS**
- 本地 `tools/verify.py` 全量通过
