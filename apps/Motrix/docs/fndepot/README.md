# FnDepot 上架素材

`Motrix/` 这一份就是 FnDepot 索引仓库里该应用目录的**全部内容**（图标、预览图、README）：

```
Motrix/
├── ICON.PNG                 # 来自 fpk 的 ICON_256.PNG
├── README.md                # 应用页说明
└── Preview/1-dashboard.png  # 1600x1000 实机截图（简体中文、无登录、引擎就绪）
    2-downloads.png
    3-settings.png
```

## 上架步骤

```bash
# 1) 复制素材到 FnDepot 仓库根
cp -a docs/fndepot/Motrix /path/to/FnDepot/Motrix

# 2) 首次收录（只做一次；键名必须等于 fpk 里 manifest 的 appname）
cd /path/to/FnDepot
python3 tools/add-app.py \
  --key Motrix \
  --display-name "Motrix" \
  --desc "全功能下载管理器（HTTP/FTP/BT/磁力）的服务端 Web 面板，aria2 内核，默认端口 26800。" \
  --categories 系统工具 \
  --platform arm \
  --repo bekafka/motrix-fpk \
  --run-as package \
  --install-type "" \
  --icon Motrix/ICON.PNG \
  --service-port 26800 \
  --write

# 3) 预览图与 README（add-app.py 不管这两项，用 jq 补）
jq '.apps.Motrix.preview_urls = [
      "Motrix/Preview/1-dashboard.png",
      "Motrix/Preview/2-downloads.png",
      "Motrix/Preview/3-settings.png"
    ]
    | .apps.Motrix.readme_url = "Motrix/README.md"' fnpack.json > fnpack.json.new
mv fnpack.json.new fnpack.json

# 4) 门禁
python3 tools/verify.py --no-net
python3 tools/verify.py          # 全量：核对每个外链 Content-Length
```

> `--readme` 会把 `readme_url` 指向**应用仓库**的 README（走 jsDelivr CDN）；这里选择把说明放在索引仓库里
> （`Motrix/README.md`），两者择一即可，不要同时设成不同来源。

## 截图怎么来的

`/opt/helium-browser-bin/helium --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
 --user-data-dir=/tmp/helium-shot --window-size=1600,1000 --virtual-time-budget=12000 \
 --screenshot=… http://<NAS_IP>:26800/#/downloads/all`

（UI 是 hash 路由：`#/downloads/all`、`#/settings`；截图前先清空任务记录，再用两个正常大小的任务做演示。）
