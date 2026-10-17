# 图标目录

客户端默认读 `fnapp.png`。**请把图标文件放在这里**（建议 256×256 PNG，命名 `fnapp.png`）。

然后 `fnpack.json` 里每个应用写：

    "icon_url": "assets/icons/fnapp.png"

也可以给单个应用指定外链图标：

    "icon_url": "https://example.com/myapp.png"

`verify.py` 会检查本地路径是否存在、外链是否可达。
