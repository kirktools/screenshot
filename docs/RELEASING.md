# CI、版本与发布

CI 随 master push 和 PR 自动执行；维护者运行发布脚本推送版本标签后，自动测试、打包并正式发布。

## 自动测试

`.github/workflows/ci.yml` 对 master push 与 PR 执行 Swift 算法测试、原生离屏渲染/PNG 自测、release 构建，并上传 14 天产物。矩阵：macos-15（arm64）与 macos-15-intel（x86_64）；CI 和 Release 均通过 DEVELOPER_DIR 固定 Xcode 16.4 / Swift 6.1，不依赖 runner 默认工具链，先检查并打印实际版本。Xcode 路径依据官方 [ARM 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) 与 [Intel 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。应用最低编译目标仍为 macOS 14，macOS 14 实际运行仍需人工验收；runner 标签依据 [GitHub 官方说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。云端 CI 没有交互式权限验收，不能证明真实窗口截屏成功。workflow 仅给读取仓库权限，PR 不使用发布凭据。Actions 使用固定 commit SHA，对应官方 [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) 和 [upload-artifact v7.0.0](https://github.com/actions/upload-artifact/releases/tag/v7.0.0)，Dependabot 可提交升级 PR。

## 一条命令发布

```bash
make release                     # 默认 patch：0.1.0 → 0.1.1
make release BUMP=minor          # minor：0.1.0 → 0.2.0
make release BUMP=major          # major：0.1.0 → 1.0.0
make release-dry-run BUMP=minor  # 计算并预览，不联网、不改文件、不推送
```

这是 Make 的标准语法，与 Swift 无关。`release` 是任务名，`BUMP=minor` 覆盖 Makefile 中 `BUMP ?= patch` 的默认值。`BUMP=minor make release` 通过环境变量传入，在当前 Makefile 下也有效。

`make release --dry-run` 是 Make 自己的预演：只打印将调用的脚本，不执行脚本，也不会计算版本；`make release-dry-run` 则实际调用脚本的只读预览。直接运行脚本也可以：`./scripts/release.sh --minor --dry-run`。

### 实际流程

运行发布命令即表示确认当前已提交代码可以正式发布，无需二次确认或手动发布草稿：

1. 在 master 上提交开发改动，确认 CI 与真实桌面验收通过。脚本要求工作区干净，只允许推送 `kirktools/screenshot`。
2. 脚本读取 VERSION，检查本地 master 未落后或分叉、版本标签未占用，仅修改 VERSION 并生成 `chore: release vX.Y.Z` 提交。
3. 生成注释标签 `vX.Y.Z`，通过一次 `git push --atomic` 推送 master 和该标签；已经提交但尚未推送的 master 改动会一起推送，不自动提交其他文件。
4. 标签 push 触发 Release 工作流。检出标签指向的代码，校验标签与 VERSION 一致且提交属于 master；不会改为构建之后前进的 master。
5. 算法测试通过后构建 universal 应用，验证双架构、包内渲染/PNG 与连续滚动会话，生成校验和并上传 Artifact。
6. 全部成功后，直接创建正式 GitHub Release，附带 dmg、zip、SHA256SUMS 和自动生成的版本变更记录。

本机只需要 git、python3 以及平时 `git push` 的 SSH / HTTPS 认证，**无需安装或登录 gh**。云端使用 GitHub 自动提供的 GITHUB_TOKEN 调用 gh 创建 Release，不需要维护者额外存放个人 Token。标签触发依据 [GitHub 官方说明](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)。普通 master push 只跑 CI，不发布；不再有手动 workflow_dispatch 加版本流程，也不使用需要额外批准的 release Environment。

README 的功能、限制和安装说明不会由脚本自动改写；发布说明由 `docs/RELEASE-NOTES.md` 通用说明加 GitHub 自动生成的提交/PR 变更记录组成。发布前如需补充说明，应先修改并提交到本次代码中。当前包仍是 ad-hoc 签名，发布成功不代表已完成 Apple 签名或公证。

发布脚本回归运行 `python3 scripts/test-release.py`，使用临时本地 Git 仓库验证，不访问 GitHub，也不会真实发布。CI 会自动执行。

### 失败与重试

- 本地检查失败：没有版本改动或推送，按提示处理后重试。
- 本地版本提交或标签完成但推送失败：保留现场，不自动重置用户代码。修复原因后使用脚本输出的 `git push --atomic origin HEAD:refs/heads/master refs/tags/vX.Y.Z` 重试原版本；先确认 HEAD 仍是该版本提交。不要再次递增版本，也不要强推。
- 标签已推送但云端失败：直接在 Actions 重跑该次失败任务，仍构建同一个不可变版本。不要重新运行 release 脚本、覆盖标签或重复递增。
- 如失败原因需要修改源码：提交修复并发布一个新版本，保留失败标签的可追溯性。
- 如果 Release 已存在，创建步骤会失败，不会覆盖已发布文件。

当前流程会直接向 master 写版本提交；个人维护阶段可先禁止删除和强推。之后若要求所有变更必须走 PR，应把版本提交改为先审核 PR、合并后再打标签；不要为了发版关闭分支保护。每个版本单独排队，不取消正在运行的同版本发布。

## DMG 安装包

`scripts/build-app.sh` 同时生成 ZIP 和只读压缩 DMG。镜像内只有已签名应用和指向 `/Applications` 的安装入口，不会修改应用签名内容。已有构建可运行 `scripts/package-dmg.sh` 单独重新打包，`scripts/test-dmg.sh` 会以只读方式挂载，验证内容、安装入口、版本、签名及二进制后卸载。CI 的两种架构及 Release 均执行此验证；Artifact 和 Release 上传两种安装包，Release 校验和覆盖两者。已发布的旧版本不会自动补发 DMG。

DMG 不绕过 Gatekeeper，也不代替 Developer ID 签名和公证。当前仍保持 ad-hoc 签名；未来签名/公证时应先完成应用公证和 staple，再重新生成最终 ZIP、DMG 与校验和；若公证 DMG，则提交最终镜像并对其 staple 后再生成校验和。

## 签名与公证

当前产物仅 ad-hoc 签名，在 CI 中也如此；不会伪称“Apple 已验证”。正式公开分发需要 Apple Developer Program 账户、有效 Developer ID Application 证书及私钥、Team ID，以及 notarytool 可用的 App Store Connect API 凭据或 Apple ID 应用专用密码。不要提交证书、密码或私钥到仓库。

[Apple 官方 Developer ID 指南](https://developer.apple.com/developer-id/)与[公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。准备好身份后：

```bash
SIGN_IDENTITY='Developer ID Application: YOUR ENTITY (TEAMID)' UNIVERSAL=1 scripts/build-app.sh
xcrun notarytool submit dist/Screenshot-0.1.0-macOS.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple 'dist/Screenshot.app'
xcrun stapler validate 'dist/Screenshot.app'
spctl --assess --type execute --verbose 'dist/Screenshot.app'
# staple 后重新压缩，再重新生成 checksum；不要分发 staple 前的旧 zip。
ditto -c -k --sequesterRsrc --keepParent 'dist/Screenshot.app' dist/Screenshot-0.1.0-macOS.zip
shasum -a 256 dist/*.zip > dist/SHA256SUMS.txt
```

`SIGN_IDENTITY` 分支启用 hardened runtime 与安全时间戳。CI 自动导入证书、隔离临时 keychain、公证凭据和清理尚未接入，需在取得实际签名材料后配置独立的受保护 job。不要把需要的 secret 伪造为占位值或在 fork PR 中开放使用。
