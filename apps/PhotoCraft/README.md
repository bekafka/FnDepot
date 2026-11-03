# PhotoCraft（浏览器运行版）

把 [storytold/photocraft](https://github.com/storytold/photocraft) 的**官方 WebAssembly 静态包**
做成飞牛 fnOS 可安装的应用：NAS 只负责把静态文件按正确响应头发出去，整个图像编辑器
（图层、蒙版、调整图层、图层样式、文字、矢量、真实 PSD 读写）在**访客浏览器里**运行。

- 上游：`storytold/photocraft`，纯 Rust 重写、双合成器（CPU 参考 + wgpu）、alpha 阶段
- 本包：**不改上游代码**，只做 fnOS 适配与两处必要的托管修正（见下）

## 包里是什么

| 路径（`target/` 下） | 内容 |
|---|---|
| `bin/photocraft-web` | 本仓库 `src/` 编出来的静态宿主（纯 Go 标准库，`CGO_ENABLED=0` 静态链接） |
| `webroot/` | 上游 `photocraft-web-<ver>.zip` 解包后的站点，已打补丁、已带中文字体 |
| `ui/` | 桌面入口与图标 |
| `share/PROVENANCE.json` | 上游版本、站点内容摘要、字体与二进制 sha256、工具链 |

宿主只做三件事：发文件、写对的响应头、提供 `/healthz`。**不写盘、不代理、无服务端存储**。

## 两处必要的修正

1. **`snippets/` 路径缺陷（上游 issue #10491）**：自 0.17 起，`app/photocraft-web.js` 里
   `import … from "./snippets/eframe-<hash>/inline0.js"` 是相对胶水自身目录解析的，但官方 zip
   只把 `snippets/` 放在解包根，浏览器在 `/app/snippets/…` 上吃 404，页面永久停在
   「Loading PhotoCraft…」。构建脚本把根 `snippets/` 复制进 `app/`（**幂等**，上游发新版后重跑
   即可），并在打包前复查，补丁不成功直接失败。
2. **中文字体**：浏览器不提供系统字体，上游只自带 Inter / JetBrains Mono，中文排版没有可用家族。
   构建脚本按上游 `fonts/manifest.txt` 约定随包附带 `Noto Sans CJK SC Regular`（OFL-1.1，
   sha256 与 craft-fonts 清单一致）。

## 响应头契约（宿主已实现）

- `.wasm` → `application/wasm`（否则浏览器拒绝流式编译）
- `app/*.part-*` → 原字节直出，**不加 Content-Encoding**（页面自己解压），长缓存
- `index.html` / `app/photocraft-web.js` / `app/parts.txt` / `fonts/manifest.txt` → `no-cache`
- 带内容哈希的资源 → `immutable` 长缓存
- 未知路径 → **404**，禁止 SPA 兜底（否则缺文件会被掩盖成白屏/一直加载）

## 出包

```bash
ARCH=arm64 VERSION=0.20.1 CHANGELOG="…" bash build-local.sh
ARCH=amd64 VERSION=0.20.1 CHANGELOG="…" bash build-local.sh
```

可脱离网络复用已下载的工件：

```bash
PHOTOCRAFT_WEB_ZIP=/path/photocraft-web-0.20.1.zip ARCH=arm64 VERSION=0.20.1 bash build-local.sh
```

上游版本用 `PHOTOCRAFT_UPSTREAM_VERSION` 覆盖；上游 zip 与字体都按固定 sha256 校验
（`packaging/build.sh` 顶部）。

## 验收

装到真机后：

```bash
bash tests/accept.sh all
```

五段：身份 / 端点 / 响应头 / 生命周期 / 运维。含「未知路径必须 404」「分片不得带
Content-Encoding」「`.wasm` 必须 application/wasm」等硬断言。

## 已知限制（如实写）

- **数据不进 NAS**：打开与保存都在访客浏览器里（浏览器选文件、下载回本地）。想让 NAS 上的
  照片原地编辑保存，需要另一套围绕无头引擎的方案，不是这个包。
- **无登录**：静态站点没有账号概念，同网段能访问该端口的人都能打开编辑器（看到的只是他
  自己本机打开的文件）。请勿把端口暴露到公网。
- **WebGPU 需要安全上下文**：局域网明文 `http://` 会退化为 WebGL2（功能可用、较慢）；要
  WebGPU 走 https 入口。
- 上游处于 alpha，功能可用但不是 Photoshop 的替代品。

## 目录

```
apps/PhotoCraft/
├── package/          fnOS 包模板（manifest / cmd / config / wizard / app/ui）
├── src/              静态宿主源码（Go）
├── packaging/build.sh payload 生产线
├── build-local.sh    本地出包
└── tests/accept.sh   五段验收
```
