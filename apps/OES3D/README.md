# OES3D · 开发者说明

- 应用键：`OES3D`
- 目标架构：仅 `arm64`（OES-A311D）
- 载体：仓库内静态 HTML + Python 标准库 HTTP 服务
- `package/`：fnOS 包模板（manifest、生命周期脚本、UI 入口、图标）
- `payload/`：实际页面与服务源码（`www/index.html`、`server/serve.py`、`server/led_helper.py`、`server/led-map.json`）
- `packaging/build.sh`：把 `payload/` 复制进 `$PAYLOAD_DIR`，并生成 `share/PROVENANCE.json`
- 服务监听 `0.0.0.0:23080`，数据目录使用 `$TRIM_PKGVAR`
- `run-as=root` 是 sysfs LED 写入所需；只发布 arm64。

构建由 FnFactory `_build-fpk.yml` 调用；发布入口为 FnDepot `build-app.yml`。
