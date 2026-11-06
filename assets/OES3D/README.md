# OES3D · 网心云 OES 3D 指示灯控制台

针对 **网心云 OES / OES-A311D（fnOS arm64）** 的 3D 实机模型与五颗绿色 LED 控制面板。

- 3D 页面直接打开，无外部资源、无需联网。
- 五颗 LED 可逐颗开关；右侧电源键第一次全关、第二次全开，全亮 5 秒后按真实盘位状态校正。
- 支持每日定时开/关，配置保存在应用数据目录。
- 仅构建 **arm64** 版本，不对 x86 发布。
- 写入 `/sys/class/leds/*/brightness` 需要 root 权限，应用以 root 运行；建议只在局域网使用。

应用键：`OES3D`。源码与打包脚本在 [FnDepot](https://github.com/bekafka/FnDepot/tree/main/apps/OES3D)。

源作者：bekafka / FnDepot（本项目最初的创造者与权利源头）。
