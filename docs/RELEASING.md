# CI、版本与发布

CI 随 master push 和 PR 自动执行；发布需要手动触发，默认只创建 Draft Release。

## 自动测试

`.github/workflows/ci.yml` 对 master push 与 PR 执行 Swift 算法测试、原生离屏渲染/PNG 自测、release 构建，并上传 14 天产物。矩阵：macos-15（arm64）与 macos-15-intel（x86_64）；CI 和 Release 均通过 DEVELOPER_DIR 固定 Xcode 16.4 / Swift 6.1，不依赖 runner 默认工具链，先检查并打印实际版本。Xcode 路径依据官方 [ARM 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) 与 [Intel 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。应用最低编译目标仍为 macOS 14，macOS 14 实际运行仍需人工验收；runner 标签依据 [GitHub 官方说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。云端 CI 没有交互式权限验收，不能证明真实窗口截屏成功。workflow 仅给读取仓库权限，PR 不使用发布凭据。Actions 使用固定 commit SHA，对应官方 [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) 和 [upload-artifact v7.0.0](https://github.com/actions/upload-artifact/releases/tag/v7.0.0)，Dependabot 可提交升级 PR。

## 自动加版本与打包

原生渲染与连续滚动回归运行打包后的 Release 应用；算法测试仍使用 Debug 并收集覆盖率。连续会话按约 30fps 投递合成帧，未优化的 Intel Debug 在本机复现处理积压、丢帧及末尾保护确认，不能作为分发版本的实时处理验收。测试仍检查逐像素结果、末帧排空、恢复与导出，不跳过 Intel。

当前建议显式触发一次 Release 工作流，默认 patch +1；不在每个 commit 上改版本，避免噪声与竞争。

1. 确认 master 的 CI 和人工验收通过。
2. 在 GitHub 仓库设置创建 `release` Environment，建议要求维护者审核；开启 Actions（后续决定发布时再做）。
3. 从 master 手动运行 `Prepare Release`，选择 patch/minor/major。
4. 工作流先跑测试，更新唯一版本源 `VERSION`，构建 universal app、检查双架构、执行包内自测、生成 SHA256SUMS。
5. 构建成功后才提交版本与标签，以 atomic push 一并写入远端，然后创建 **Draft Release**，等待维护者填写具体变更、安装验收并手动发布。首次触发 patch 会从 0.1.0 升为 0.1.1。

并发发布串行处理；从最新 master checkout，不允许在 fork 或非 master 上发布。构建失败不提交版本；远端分支在构建期间前进，普通 push 会安全失败，不会强推。失败前构建产物已上传 Artifact。若 branch protection 禁止 github-actions bot 直接写 master，当前自动提交阶段会失败：应把版本提升改为审核 PR 流程，或明确配置受限发布身份；不要为了跑通而关闭分支保护。GITHUB_TOKEN 推送产生的提交通常不再次触发 push workflow，发布工作流已自行测试。

个人维护阶段可先对 master 启用禁止删除、禁止强推，保留普通推送。公开协作后再要求 PR 和双架构 CI，并同步改造上述版本提交流程。当前私有组织仓库的套餐不支持分支保护；公开仓库可在免费套餐配置，私有组织仓库需要支持该功能的 Team / Enterprise 套餐。参见 [GitHub 分支保护说明](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)。不要仅为消除提醒而改变仓库可见性。

如果版本和标签已写入但 Draft 创建失败，可以从 Actions 下载产物，核对 SHA256SUMS 后手工为已有 tag 建 Draft，**不要重跑自动递增步骤**。脚本不会自动修改 CHANGELOG；发布人需编写清晰变更说明，当前 `docs/RELEASE-NOTES.md` 是需补充的初始模板。

## 签名与公证

当前产物仅 ad-hoc 签名，在 CI 中也如此；不会伪称“Apple 已验证”。正式公开分发需要 Apple Developer Program 账户、有效 Developer ID Application 证书及私钥、Team ID，以及 notarytool 可用的 App Store Connect API 凭据或 Apple ID 应用专用密码。不要提交证书、密码或私钥到仓库。

[Apple 官方 Developer ID 指南](https://developer.apple.com/developer-id/)与[公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。准备好身份后：

```bash
SIGN_IDENTITY='Developer ID Application: YOUR ENTITY (TEAMID)' UNIVERSAL=1 scripts/build-app.sh
xcrun notarytool submit dist/Kirk-Screenshot-0.1.0-macOS.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple 'dist/Kirk Screenshot.app'
xcrun stapler validate 'dist/Kirk Screenshot.app'
spctl --assess --type execute --verbose 'dist/Kirk Screenshot.app'
# staple 后重新压缩，再重新生成 checksum；不要分发 staple 前的旧 zip。
ditto -c -k --sequesterRsrc --keepParent 'dist/Kirk Screenshot.app' dist/Kirk-Screenshot-0.1.0-macOS.zip
shasum -a 256 dist/*.zip > dist/SHA256SUMS.txt
```

`SIGN_IDENTITY` 分支启用 hardened runtime 与安全时间戳。CI 自动导入证书、隔离临时 keychain、公证凭据和清理尚未接入，需在取得实际签名材料后配置独立的受保护 job。不要把需要的 secret 伪造为占位值或在 fork PR 中开放使用。
