# Magpie · 飞牛 fnOS 应用包

把上游 [yetone/magpie](https://github.com/yetone/magpie) 做成飞牛 fnOS 可安装的 `Magpie.fpk`：
原生进程运行（不用 Docker），Web 面板管理 provider / 账号 / 路由，网关默认端口 3425。

- 面板：点桌面图标直接进（入口 URL 里带着打包时固定的访问密钥）；直接开 `http://<NAS>:3430/?k=<密钥>` 也行
- 网关：`http://<NAS>:3425/v1`（OpenAI 兼容）、`http://<NAS>:3425`（Anthropic / Gemini）
- 上游版本：见 `package/app/PROVENANCE.json`（源码 tag + commit + 二进制 sha256）
- 构建：纯 Go、`CGO_ENABLED=0 -tags nogui`，不带桌面壳（GTK/Wails），保留 Web 面板与 CLI

## 作者与来源

| 角色 | 是谁 | manifest / `fnpack.json` 字段 |
| --- | --- | --- |
| 开发者（飞牛适配与打包） | bekafka | `maintainer` / `maintainer_url` |
| 发布者（发布到应用源） | bekafka（[FnDepot](https://github.com/bekafka/FnDepot)） | `distributor` / `distributor_url` |
| 源作者（上游项目，权利源头） | [yetone/magpie](https://github.com/yetone/magpie) | `source_author` / `source_author_url` |

口径见 FnFactory 的 [`specs/authorship.md`](https://github.com/bekafka/FnFactory/blob/main/specs/authorship.md)：
开发者/发布者固定写 bekafka，源作者永远指上游项目最初的创造者与权利源头（不是打包者）。

## 目录

```
package/          fnOS 包模板（manifest / config / cmd / wizard / app）
packaging/        payload 生产线（build.sh：拉上游 tag → Go 交叉编译 → PROVENANCE）
tests/            设备上的验收阶梯（accept.sh）
build-local.sh    本地一键出包
```

## 用起来

```bash
# 面板登录密钥：安装向导里填的那个（存在这里；桌面图标已经自动带上）
sudo cat /vol1/@appdata/Magpie/web-key

# 网关密钥（局域网共享时，远程客户端作为 Bearer token）
sudo cat /vol1/@appdata/Magpie/gateway-keys.txt

# 加一个 provider（也可以用面板）
sudo magpie-cli provider add deepseek sk-...

# 从本机命令行看 provider / 模型
sudo magpie-cli providers
sudo magpie-cli models
```

Agent 侧（在另一台电脑上）：

```bash
export OPENAI_BASE_URL=http://192.168.2.22:3425/v1
export OPENAI_API_KEY=sk-magpie-key-...        # 局域网共享时必须带网关密钥
# Anthropic:  ANTHROPIC_BASE_URL=http://192.168.2.22:3425   ANTHROPIC_API_KEY=sk-magpie-key-...
# Gemini:     GOOGLE_GEMINI_BASE_URL=http://192.168.2.22:3425 GEMINI_API_KEY=sk-magpie-key-...
```

模型名是 `provider/model`，例如 `deepseek/deepseek-chat`；列表看面板「供应商」页或 `magpie-cli models`。

## 端口与访问控制

| 项 | 默认 | 说明 |
|---|---|---|
| Web 面板端口 | 3430 | 安装向导可改；应用设置页留空表示不改 |
| AI 网关端口 | 3425 | 同上；也可以在面板「设置 → 网关端口」里改 |
| 局域网共享 | 开启 | 关闭后网关只监听 `127.0.0.1`，只有本机能用 |

面板绑定 `0.0.0.0`，但每个请求都要带面板密钥（`?k=` 或登录后的 cookie），无密钥 401。

面板访问密钥**在打包时生成并固定**：`packaging/webkey`（28 位）→ 写进包内 `app/bin/webkey`
→ 构建脚本替换 `ui/config` 里的 `__WEB_KEY__`，入口变成 `/?k=<密钥>`，点桌面图标直接进面板。

> 为什么必须打包时写死：飞牛登记的入口 URL 只对 `${host}` / `${wizard_port}` 做替换，
> **查询串里的占位符会被整个吃掉**（实测 `${wizard_web_key}`、官方支持的 `${wizard_path}` 都变成 `/`，
> 请求里连查询串都没有；而字面量 `?k=…` 正常）。入口类型也必须用 `url`（`iframe` 下实测会被并进路径）。
>
> 代价：密钥随包公开（Release 资产里能读到），它挡的是误闯/爬虫，不是能上局域网的人。
> 面板默认只监听局域网，别直接映射到公网；要私密就自己改 `$PKGVAR/web-key` 与入口 URL。
> 也因此**不要随意轮换 `packaging/webkey`**——已安装用户的入口还带着旧 key，换 key 等于要他们重装。

**入口地址的端口是安装时登记的**，之后改面板端口不会自动更新——想换端口请卸载重装。命令行静默安装：

```bash
# install.env
wizard_port=3430
wizard_gateway_port=3425
wizard_lan=true
# 面板密钥现在由打包时的 packaging/webkey 决定，安装环境文件只需端口
appcenter-cli install-fpk Magpie-<version>-arm.fpk --env install.env
```

网关的监听范围由 magpie 自己的 `settings.json`（`lan` / `port`）决定：**开启局域网共享后，远端请求必须带一个已启用的
网关密钥**，无密钥/错误密钥 401，回环请求不受限（上游设计）。安装时创建名为 `fnOS` 的网关密钥并写进
`/vol1/@appdata/Magpie/gateway-keys.txt`（0600）；之后可在面板「网关 → 网关密钥」增删、轮换、限额。

> 为什么不设 `MAGPIE_ADDR`：新版上游只要它里写了具体地址就不再理会 `lan`，网关会一直绑在那个地址上；
> 端口与监听范围统一交给 `settings.json`，脚本只负责把向导值写进去。

## 数据与卸载

所有状态都在 `/vol1/@appdata/Magpie`（卸载不删，重装沿用）：

```
config.env           端口 / 局域网共享开关（脚本用）
web-key              面板密钥（0600）
gateway-keys.txt     局域网网关密钥（0600）
config/magpie/       settings.json、providers.json（含上游 key）、routing、用量记录…
home/                应用用户的 HOME（账号登录态、~/.claude、~/.codex 等）
cache/               models.dev 目录、Bun 与插件缓存
```

「完全卸载」只删这些状态，不动应用目录以外的任何文件；「保留配置卸载」什么都不删。

## 已知边界

- **没有桌面壳**：`nogui` 构建，只有 Web 面板 / CLI / 网关；不需要图形环境。
- **不跟上游自更新**：`settings.json` 预置 `noAutoUpdate=true`，升级走应用中心（二进制与生命周期脚本必须成套）。
- **不打点**：服务进程带 `MAGPIE_NO_STATS=1`；想支持上游可以去掉（`cmd/main` 的 build_env）。
- **插件（Bun）**：插件页首次使用会下载 Bun；国内网络可在「插件 → 国内镜像」打开镜像开关。
- **账号登录**：`magpie-cli accounts add codex` 这类交互式登录需要终端（如用终端应用 SSH 上去），`sudo` 运行。
- **卸载向导**：应用中心的卸载按钮要在弹窗里选「保留/完全卸载」，所以 `appcenter-cli uninstall` 会拒绝并提示去 Web UI。
- **桌面入口是安装时登记的**：`app/ui/config` 在安装那一刻被飞牛写进数据库（`app_service.url`，变量占位符运行时替换），
  所以面板端口改完要重装才能让图标跟着变；应用设置页只同步脚本自己的 `config.env`。
- **入口 URL 里的查询串只认字面量**：`${wizard_*}` / `${wizard_path}` 都会被丢掉；入口类型用 `url`，`iframe` 下实测会被并进路径。密钥在 `packaging/webkey`（构建时注入），轮换它会让已安装用户的图标失效。
- **文件权限**：飞牛安装后的 ApplyPermission 会把 `@appdata` 里的文件统一改成 0700，`cmd/main` 每次启动把
  `config.env` / `web-key` / `gateway-keys.txt` 改回 0600。

## 构建

```bash
# 本地出包（arm64 或 amd64）
ARCH=arm64 VERSION=0.1.1279 CHANGELOG="..." bash build-local.sh

# 只产 payload（CI 里由 FnFactory 调用）
ARCH=arm64 VERSION=0.1.1279 PAYLOAD_DIR=... bash packaging/build.sh
```

`packaging/build.sh` 浅克隆上游 tag、核对 tag 与 commit、用 Go 交叉编译（不依赖 cgo），并把
commit / Go 版本 / 二进制 sha256 写进 `app/PROVENANCE.json`。

## 验收

真机（飞牛 arm64）上：

```bash
sudo bash tests/accept.sh all
```

覆盖状态、端点、鉴权（正例+负例）、端到端（mock 上游）、生命周期（stop/start、孤儿、密钥不变）与运维项。
当前结果：**PASS=38 FAIL=0**（2026-10-17，192.168.2.22 / aarch64）。
