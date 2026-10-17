# Magpie · AI 模型统一网关

[Magpie](https://github.com/yetone/magpie) 把各家 AI 模型收进一个网关：Claude Code 跑 Kimi、Codex 跑 DeepSeek、
Gemini CLI 跑 GLM，都指向 NAS 上的同一个地址；OpenAI Chat / Responses、Anthropic Messages、Gemini 四种 API
互相转换，流式输出与工具调用照常。Web 面板管理 provider、账号、路由组与用量。

- **面板**：应用中心点 Magpie 图标直接进（入口 URL 自带打包时固定的访问密钥）。
- **网关**：`http://<NAS>:3425/v1`（OpenAI 兼容）、`http://<NAS>:3425`（Anthropic / Gemini）。
- **局域网共享**默认开启：远程客户端必须带**网关密钥**（安装时生成，`/vol1/@appdata/Magpie/gateway-keys.txt`），
  面板「网关 → 网关密钥」里可以增删、轮换、限额。关闭共享后网关只监听 `127.0.0.1`。

## 用起来

1. 面板「供应商 → 添加供应商」：选预设（DeepSeek / Kimi / 智谱 / 通义 / OpenRouter / Ollama…）填 key，
   或者选「自定义」填 Base URL；模型列表从厂商实时拉取。
2. 在另一台电脑上把 Agent 指过来：

   ```bash
   export OPENAI_BASE_URL=http://<NAS>:3425/v1
   export OPENAI_API_KEY=<网关密钥>          # 形如 sk-magpie-key-…
   # Anthropic: ANTHROPIC_BASE_URL=http://<NAS>:3425  ANTHROPIC_API_KEY=<网关密钥>
   # Gemini:    GOOGLE_GEMINI_BASE_URL=http://<NAS>:3425  GEMINI_API_KEY=<网关密钥>
   ```

   模型名是 `provider/model`（例如 `deepseek/deepseek-chat`），面板「供应商」页或 `magpie-cli models` 能看到列表。
3. 想按额度自动切换账号，就在「路由」里建路由组（smart / order / rotate / usage / pace），
   把组名当模型名给 Agent 用。

命令行（可选，等价于面板操作）：

```bash
sudo magpie-cli providers                     # 列 provider 与模型
sudo magpie-cli provider add deepseek sk-…    # 加一个
sudo magpie-cli gateway-key add "远程笔记本"   # 再发一个网关密钥
sudo magpie-cli accounts add codex            # 订阅账号登录（需要终端）
```

## 端口与数据

| 项 | 默认 |
|---|---|
| Web 面板 | 3430（安装向导可改） |
| AI 网关 | 3425（安装向导可改；面板「设置 → 网关端口」也能改） |

所有状态在 `/vol1/@appdata/Magpie`：`config/magpie/`（provider、路由、用量、设置）、`home/`（账号登录态）、
`cache/`（模型目录、插件缓存）、`web-key`、`gateway-keys.txt`。卸载时可选**保留配置**（默认，重装沿用）
或**完全卸载**（删除上述状态）；两种方式都不动应用目录以外的文件。

## 说明

- 面板登录密钥在安装时设置，会写进桌面图标的入口地址；**改端口或换密钥需要卸载重装**，图标才会跟着变。
- 本包不跟上游自更新（`noAutoUpdate`），升级走应用中心，由 CI 跟随上游 release 自动构建。
- 插件（插件页）首次使用会下载 Bun；国内网络可在插件页打开「国内镜像」。
- 面板与网关都是 HTTP；跨公网使用请放在 VPN 或带认证的反向代理后面。

源作者：[yetone/magpie](https://github.com/yetone/magpie)（MIT）。本应用包由
[bekafka](https://github.com/bekafka/FnDepot) 做飞牛适配与打包，不改上游业务逻辑。
