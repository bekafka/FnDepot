# GitHub CLI · 飞牛 fnOS 版

[gh](https://github.com/cli/cli) 是 GitHub 官方命令行工具：在终端里管仓库、Issue、PR、Actions、Release、Gist，
也能直接调 GitHub API。装好这个包后，飞牛终端的任意 shell 里都能直接用 `gh`。

> 本包 = gh 官方发布的 linux 静态二进制 + 飞牛适配，未修改上游代码。

## 作者与来源

| 角色 | 是谁 |
| --- | --- |
| **源作者**（上游项目，权利源头） | [cli/cli](https://github.com/cli/cli)（MIT） |
| 开发者 / 发布者 | bekafka（[FnDepot](https://github.com/bekafka/FnDepot)） |

## 装完之后

```bash
gh --version
gh auth status        # 安装向导里填过 token 的话，这里会显示已登录
gh repo list
gh pr list
gh api user
```

命令入口是 `/usr/local/bin/gh`。

## 关于安装向导里的 GitHub Token

- **可选**。留空也能用 gh，只是需要认证的操作要各自 `gh auth login`。
- 填了之后，同机终端用户执行 `gh` 会自动带上它（以 `GH_TOKEN` 注入），不用重复登录。
- 为让所有终端用户都能用，token 会额外以 0644 存放在
  `/var/apps/gh/target/etc/github-token`——**同机有 shell 权限的账号都能读到**。
  建议填最小权限的 fine-grained token（只勾需要的仓库、只读即可）。
  想收紧就把它改成 0600（之后其它用户需自行登录）。
- 你自己在环境里设置的 `GH_TOKEN` / `GITHUB_TOKEN` 优先级更高，不会被安装时的值覆盖。

## 从哪来

- 上游：<https://github.com/cli/cli>（MIT），资产取 `gh_<version>_linux_<arm64|amd64>.tar.gz`
- 校验：用上游 release 自带的 `checksums.txt` 核对该资产那一行
- 版本：跟随上游正式版（自动跟版流水线每 6 小时巡检一次）
