# 静态官网

官网源码在 `site/`，使用原生 HTML / CSS，无需 Node、第三方字体或统计脚本。图片和 GIF 来自项目的合成演示素材。

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

`robots.txt`、站点地图和页面分享信息已提供；收录时间和搜索排名由搜索引擎决定。官网内容随应用正式版更新。
