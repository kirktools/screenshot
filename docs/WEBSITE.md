# 静态官网

官网源码在 `site/`，使用原生 HTML / CSS，无需 Node、第三方字体或统计脚本。图片、GIF 和 MP4 来自项目的合成演示素材。官网使用可播放、暂停的 16 秒无声 MP4，不自动播放；README 使用对应 GIF。素材展示原生控件与脚本驱动的合成滚动内容，非鼠标操作实录。

```sh
make site          # 构建到 .build/site
make site-check    # 构建并检查资源、锚点、发布范围
make site-preview  # 本地预览 http://127.0.0.1:4173
```

## 免费上线

公开仓库可使用 GitHub Pages 免费托管，默认地址为：

https://kirktools.github.io/screenshot/

1. 仓库 Settings → Pages → Build and deployment，Source 选择 **GitHub Actions**。
2. 将改动提交到 `master` 后，按项目发布流程发布新版本。`Release` 工作流成功创建正式版后调用 `Website`，部署同一版本标签中的官网源码。普通 push 不部署；官网相关 PR 仅检查。
3. 首次部署成功后，将仓库 About → Website 设为上述地址。

不需要购买域名、服务器或 Apple 开发者账号。自定义域名可后续选配，域名本身可能收费。

构建脚本只复制明确列出的网页及演示素材，不发布整个仓库，也不包含 `.local/`、签名文件或应用安装包。主下载按钮通过 `releases/latest/download/Screenshot-macOS.dmg` 直接下载最新正式版；旁边保留更新日志及其他下载入口。发布流程从已验证的版本化 DMG 复制出固定文件名，两份文件内容相同，校验清单同时覆盖。应用内更新继续使用原有带版本名的 ZIP。

固定文件名从包含本次改动的下一个正式版开始提供；旧 Release 不会被自动修改。首次上线随该版本发布完成，无需先手动部署官网。

官网作为发布流程的后续任务运行，避免 `GITHUB_TOKEN` 创建的 Release 无法触发独立 Release 事件工作流的问题；官网部署失败时已发布的应用仍保留，可在 Actions 重跑失败任务修复，不必再发一个版本。

## 仅更新官网

已有正式版时，可独立更新验证标签、文案或官网素材，无需发布应用版本：

1. 将官网改动按协作流程提交、推送到 `master`。
2. 打开 Actions → Website → Run workflow，分支选择 `master`。
3. 工作流锁定并构建当前 `master` 的官网源码，部署到原 Pages 地址。下载优先使用最新正式版的 `Screenshot-macOS.dmg`；旧正式版尚无固定名附件时，自动使用该版本实际存在的 `Screenshot-X.Y.Z-macOS.dmg`，构建时同时替换两个主下载按钮。缺少两种附件时停止部署。
4. 部署完成后检查线上首页；Google 验证标签需要出现在首页 HTML 的 `<head>` 中，再到对应网址前缀资源完成所有权验证。

此入口只更新官网，不构建应用、不创建或修改 Release。其他分支不能使用该手动入口；普通 push 仍不部署，官网 PR 仍只检查，正式发布仍使用对应版本的官网源码。正式发布与手动官网部署共用部署队列，避免互相取消。

`robots.txt`、站点地图和页面分享信息已提供；收录时间和搜索排名由搜索引擎决定。官网通常随应用正式版更新，也可使用上述入口独立维护。
