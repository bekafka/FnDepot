# CloudflareIP · 飞牛 fnOS 应用包

把「Cloudflare 优选」做成飞牛 fnOS 可安装的 `CloudflareIP.fpk`：原生进程运行（不用 Docker），
一个端口提供中文 Web 面板，按你的真实域名挑出**真的能服务这个域名**的边缘线路，
并写进本机 `/etc/hosts` 的受管区块。

- 面板：`http://<NAS>:26890/`（端口在安装向导与应用设置页可改）
- 工具本身：源码在 [`src/`](src/)，随本仓库入库，由流水线编译（可复现构建）
- 上游/权利源头：本项目自研，源作者即本源仓库（[bekafka/FnDepot](https://github.com/bekafka/FnDepot)）

## 作者与来源

| 角色 | 是谁 | manifest 字段 |
| --- | --- | --- |
| 开发者（飞牛适配与打包） | bekafka | `maintainer` / `maintainer_url` |
| 发布者（发布到应用源） | bekafka（[FnDepot](https://github.com/bekafka/FnDepot)） | `distributor` / `distributor_url` |
| 源作者（本项目创造者） | bekafka | `source_author` / `source_author_url` |

口径见 FnFactory 的 [`specs/authorship.md`](https://github.com/bekafka/FnFactory/blob/main/specs/authorship.md)。

## 目录

```
package/                  fnOS 包模板
  manifest                三个作者 + 简介（含 root 运行与端口说明）
  config/privilege        run-as: root —— 写 /etc/hosts 必须有 root
  config/resource         usr-local-linker：装完终端可直接用 cloudflareip 子命令
  cmd/main                生命周期：start / stop / status / bootstrap
  cmd/*_callback          安装/设置/升级/卸载回调
  app/apply-config.sh     向导值 → config.env + 种一份 config.json + 写真实端口的桌面入口
  app/ui/                 桌面入口 config 与两档图标
  wizard/                 安装 / 设置 / 卸载向导
packaging/
  build.sh                payload 生产线：编译 src/ → app/bin/cloudflareip + PROVENANCE
  needs-go                标记文件：CI 看到它就 actions/setup-go
src/                      工具源码（纯 Go 标准库，go.mod 仅一行 module + go 1.27）
tests/accept.sh           设备上的六阶验收（e2e 会真写一次 hosts 再还原）
build-local.sh            本地一键出包（严格复刻 CI 顺序）
```

## 关键设计（都是实测约束，不是偏好）

| 点 | 做法 | 为什么 |
| --- | --- | --- |
| 运行身份 | `run-as: root` | 工具的全部功能是改 `/etc/hosts`，包用户没有这条路；官方 privilege 契约支持 root 模式，代价写进了 manifest 简介与安装向导 |
| 写入闸门 | 两道：启动期 `-write`（`CFIP_WRITE`）+ 面板里点「应用优选」 | 预览模式能测速看排名但绝不碰系统文件；`-write` 关掉后所有写接口直接 403 |
| 配置落点 | `$TRIM_PKGVAR/config/config.json` 与 `state.json`；工作目录 = PKGVAR | `target/` 重装会被整体抹掉；tools 只认 `-config` 给的路径与它同目录的 state |
| 不覆盖用户配置 | `apply-config.sh` 只在 `config.json` 不存在时种默认值 | 域名列表、探测参数由面板维护，设置页保存端口不该把它们冲掉 |
| 端口默认 | 26890（冷门段） | 8080/8000/3000/5000 在 NAS 上大概率已被占用 |
| 桌面入口端口 | `apply-config.sh` 写**实际端口**而不是 `${wizard_port}` | 飞牛入口占位符只在安装时可用；设置页改端口后不重写就是「点图标 404」 |
| 版本可核对 | 流水线 `-ldflags -X main.version=`，`cloudflareip help` 首行打印 | 证明设备上跑的是新包，而不是被缓存/旧进程占着 |
| 不碰 hosts | 编译、安装、升级、卸载都不写 `/etc/hosts` | 那是用户当前生效的系统解析；只有面板里点「应用」才写，点「还原默认」才清 |
| 隐藏浏览器 | 启动带 `NO_BROWSER=1`、`HOME=$TRIM_PKGVAR/home` | 服务里不能尝试 xdg-open；`~` 展开必须落在应用目录内 |

## 构建

CI 入口是 FnDepot 的 **Build App**（`workflow_dispatch`：`app_key=CloudflareIP`、`version`、`changelog`），
它调用 FnFactory 的可复用流水线：矩阵造 payload → amd64 fnpack 统一打包两架构 → Release
（tag `CloudflareIP-v<version>`）→ 回写 `fnpack.json`。

本地出包（不联网、不打 Release）：

```bash
ARCH=arm64 VERSION=1.0.0 CHANGELOG="首版" bash build-local.sh
ARCH=amd64 VERSION=1.0.0 bash build-local.sh
```

版本号两段：功能版本 `1.0.0`，只改打包（生命周期/向导/文案）时用修订号 `1.0.0-2`。

## 验收

```bash
# 装到真机后
bash tests/accept.sh all
# 单阶段：status / endpoints / auth / e2e / lifecycle / ops
CFIP_E2E_TIMEOUT=180 bash tests/accept.sh e2e   # 网络慢就把等待上限调大
```

`e2e` 会真加一个域名、真测一轮、真写一次 hosts、再还原，跑完把域名列表恢复原样；
取不到候选时**判 FAIL 并打印服务端自检文案**，不会假装通过。

## 已知边界

- 面板没有登录口令（工具原本是给本机用的），同源护栏只是防跨站写入；**不要把端口暴露到公网**。
- 写 `/etc/hosts` 只影响本机解析；要覆盖整个局域网，得在路由器/DNS 侧做（不在本应用范围）。
- 测速结果依赖出网质量与目标域名确实挂在 Cloudflare 后面；换网络后应重新测速。
