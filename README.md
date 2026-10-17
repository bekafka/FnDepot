# FnDepot · 第三方应用源（应用源码 + 索引）

飞牛 fnOS 第三方应用源。客户端只读 `fnpack.json`，`.fpk` 资产发布在**本仓库自己的 Release** 里。

```
客户端 App Center
      │  读 fnpack.json
      ▼
  FnDepot（本仓库）  ──── download_url ────▶  本仓库 Release 的 .fpk 资产
      ▲
      │  源码（apps/<App>/）
      │
  FnFactory（构建机器人）  ── builds & publishes ──▶  本仓库 Release + fnpack.json
```

**集中式模型**（2026-10-17 起）：

- `apps/<App>/` 存放每个 fpk 应用的**源代码项目**（包模板、payload 生产线、验收测试、说明）
- 构建由 [bekafka/FnFactory](https://github.com/bekafka/FnFactory) 的 GitHub Actions 完成，
  产物发布到本仓库的 Release（tag 形如 `<App>-v<version>`），并写回 `fnpack.json`
- 本仓库不镜像、不重新打包、不改文件 —— 只提供源码与索引

---

## 目录

| 路径 | 说明 |
|---|---|
| `fnpack.json` | 索引本体，客户端读的就是它 |
| `categories.json` | 官方固定分类表（9 类）+ 客户端模糊匹配用的同义词 |
| `assets/` | 图标与应用页素材（`<App>/ICON.PNG`、`<App>/Preview/*.png`、`<App>/README.md`） |
| `apps/` | **每个 fpk 应用的源代码项目**（`package/` + `packaging/` + `tests/`） |
| `.github/workflows/build-app.yml` | 构建入口：填 app_key / version / changelog，调 FnFactory |
| `tools/add-app.py` | 上架一个新应用（只写应用级元数据） |
| `tools/verify.py` | 校验器，**推送前必须跑** |

---

## 客户端填的地址

```
https://github.com/bekafka/FnDepot
```

---

## 为什么必须「先上架、再发版」

发布流水线只做这一句：

```bash
jq '.apps[K].releases[V] = {...}' fnpack.json
```

如果 `.apps[K]` 还不存在，**jq 会静默建出一个只含 `releases` 的空壳**。
缺 `display_name` / `desc` / `platform` / `categories` / `icon_url` / `run_as` /
`install_type` / `is_docker` 里的任何一个，**客户端会直接跳过这个应用，且不报任何错**。

你会面临「索引里明明有、客户端就是看不到」，而且查不出原因。

所以流程固定为两步：

```bash
# 第一步：上架（只做一次）
python3 tools/add-app.py \
    --key MyApp \
    --display-name "我的应用" \
    --desc "一句话描述" \
    --categories 系统工具 \
    --platform x86 arm \
    --repo bekafka/FnDepot \
    --run-as package \
    --icon assets/MyApp/ICON.PNG \
    --write

# 第二步：把应用源码放进 apps/MyApp/（package/ + packaging/ + tests/），
#         然后在 Actions 里跑 Build App（填 app_key=MyApp、version、changelog）
gh workflow run build-app.yml -f app_key=MyApp -f version=1.0.0 -f changelog="首个版本"
```

`FnFactory` 的发布模块会替你**卡住第一步**：app 键不存在就直接失败并提示上面这条命令。

---

## 校验（推送前必做）

```bash
python3 tools/verify.py --no-net     # 第一步：秒级，只查结构与一致性
python3 tools/verify.py              # 第二步：全量，核对每个外链的 Content-Length
```

**顺序是有意的**：结构错了本地立刻能看到，不必等几十个外链请求；
全量那步失败也说明不了结构好不好。退出码 `0` 才推。

校验器会拦下这些「客户端静默失败」的情况：

| 检查 | 不做的后果 |
|---|---|
| 9 个必填字段齐全 | 客户端**静默跳过**该应用 |
| `platform` / `categories` 必须是数组 | 同上 |
| 分类必须在 `categories.json` 的 9 类内 | 客户端筛选不到 |
| 包键名必须在 `platform` 里 | 该架构设备看不到应用 |
| `download_url` 必须是带 tag 的 release 地址 | 上游一发新版，旧地址 404 |
| 禁 `latest/download` | 同上 |
| `sha256` 64 位十六进制、`size` 正整数 | 客户端强校验失败、拒装 |
| 外链 `Content-Length` == 索引 `size` | 上游重传过 → 哈希已失效 |

---

## README 收录表（约定，非强制）

`README.md` 里可以维护一张收录表：

```
| 显示名 | 应用键名 | 版本 | 架构 | 作者 | 来源 |
| --- | --- | --- | --- | --- | --- |
| 演示应用 | `demo-app` | 1.0.0 | x86 / arm | bekafka | [bekafka/demo-app](https://github.com/bekafka/demo-app) |
```

发布流水线会**自动同步**已存在的行（版本、架构两列），但 `verify.py` **不强制**这张表存在——
漏写只是文档不全，不影响客户端。所以表可以有，也可以不要。

---

## 架构字段口径

| 字段 | 取值 | 含义 |
|---|---|---|
| `platform` | `["x86"]` / `["arm"]` / `["all"]` | 客户端按设备架构过滤 |
| `packages` 键名 | `x86` / `arm` / `all` | 必须落在 `platform` 内（除非 platform 是 `["all"]`） |
| `run_as` | `package` / `root` | 应用以哪个用户运行 |
| `install_type` | `""` / `"root"` | `""` = 装到存储空间；`"root"` = 装到系统空间 |

> `install_type: "root"` 必须有物证：读包内 `cmd/install_callback`，确认它是否碰 `/boot` 或注册 systemd。
> 不要照抄别的应用。
