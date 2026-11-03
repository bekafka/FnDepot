# gh cli · 飞牛 fnOS 应用包

把 [GitHub CLI](https://github.com/cli/cli) 做成飞牛 fnOS 可安装的 `gh.fpk`：装完终端里直接可用 `gh`，
安装向导里可选填一个 GitHub Token，填了之后**同机终端用户都不用再 `gh auth login`**。

- 命令入口：`/usr/local/bin/gh`
- 载体：上游官方 `gh_<ver>_linux_<arch>.tar.gz`（Go 静态二进制），不依赖任何运行时
- 上游版本与校验：见包内 `share/PROVENANCE.json`（tag、资产 sha256、二进制 sha256）

## 作者与来源

| 角色 | 是谁 | manifest 字段 |
| --- | --- | --- |
| 开发者（飞牛适配与打包） | bekafka | `maintainer` / `maintainer_url` |
| 发布者（发布到应用源） | bekafka（[FnDepot](https://github.com/bekafka/FnDepot)） | `distributor` / `distributor_url` |
| 源作者（上游项目，权利源头） | [cli/cli](https://github.com/cli/cli)（MIT） | `source_author` / `source_author_url` |

## Token 是怎么生效的

`bin/gh` 不是裸二进制，而是一层包装（真实二进制是 `bin/gh.real`）：

```
/usr/local/bin/gh → /var/apps/gh-cli/target/bin/gh       # 包装层
                      └─ exec bin/gh.real "$@"        # 真正的 gh
```

包装层只在环境里**没有** `GH_TOKEN` / `GITHUB_TOKEN` 时，才从 token 文件取一个值注入，然后 exec 真二进制。
因此：用户自己设了 `GH_TOKEN` 就以用户为准；没设就用安装时填的那个。

token 的两个落点：

| 路径 | 权限 | 作用 |
| --- | --- | --- |
| `/vol1/@appdata/gh-cli/github-token` | 0600 | 规范来源，重装/升级后仍在 |
| `/var/apps/gh-cli/target/etc/github-token` | 0640 + ACL 授予设备普通用户组（默认 `Users`）读 | 给终端用户的副本：该组成员可读，组外账号读不到 |

**可见范围**：终端副本是 `0640` + ACL 授予设备普通用户组（默认 `Users`）读权限，只有该组成员能读；组外账号读不到。
想更严：把 `GH_FNOS_TOKEN_GROUP` 指到一个专用组（安装时按该组授权），或直接 `chmod 600` 该文件 / 删掉它，
代价是其它用户得自己 `gh auth login`。仍建议用**最小权限的 fine-grained token**。

## 用法

```bash
gh --version
gh auth status          # 走注入的 token 时，会显示登录自 GH_TOKEN
gh repo list
gh pr list
gh api user
```

改 token（应用中心里没有「设置页」）：重装并在向导里重填，或直接覆盖上面两个文件里的值
（`etc/github-token` 那份是终端用户实际读到的那份，两份都改才一致）。

## 目录

```
package/                 fnOS 包模板
  app/gh-wrapper.sh      命令入口包装（构建时装成 bin/gh）
  app/gh-link.sh         /usr/local/bin/gh 的建立/还原助手
  cmd/install_callback   写 token（两份）+ 自检 + 建命令入口
  cmd/upgrade_callback   升级后重新镜像 token 到新 payload
  cmd/uninstall_callback 撤入口/还原被接管的同名命令、按选择清理 token
  wizard/install         GitHub Token 输入项（可选，带格式校验与风险提示）
  wizard/uninstall       保留记录 / 完全卸载
packaging/build.sh       取上游产物 + 按上游 checksums 校验 + 核对架构
tests/accept.sh          设备验收（命令可用性 / token 生效 / 真实 API 调用 / 卸载前后）
build-local.sh           本地一键出包
```

## 构建与发布

```bash
# 本地（需要能访问 GitHub releases；国内可设 GH_DL_PROXY）
ARCH=arm64 VERSION=2.103.3 CHANGELOG="首版" bash build-local.sh

# 自动跟版：FnDepot 的 auto-release.yml 每 6 小时巡检 cli/cli 的正式版
gh workflow run auto-release.yml -f app=gh
```

## 已知限制

- **卸载走应用中心界面**：本包带卸载向导，`appcenter-cli uninstall` 会被要求改用界面。
- **不预置 `gh` 的 git 凭据助手**：`gh auth setup-git` 需要每个用户各自执行；本包只解决
  `GH_TOKEN` 注入，不改各用户的 `~/.gitconfig`。
- **token 可见性**：见上文，终端副本 0640 + ACL，仅设备普通用户组成员可读。
