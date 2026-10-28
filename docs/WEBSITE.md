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
2. 将官网相关改动提交并推送到 `master`，`Website` 工作流自动构建和部署。PR 仅检查，不部署。
3. 首次部署成功后，将仓库 About → Website 设为上述地址。

不需要购买域名、服务器或 Apple 开发者账号。自定义域名可后续选配，域名本身可能收费。

构建脚本只复制明确列出的网页及演示素材，不发布整个仓库，也不包含 `.local/`、签名文件或应用安装包。下载按钮指向 GitHub 正式版页面。

`robots.txt`、站点地图和页面分享信息已提供；收录时间和搜索排名由搜索引擎决定。官网更新后不需要递增应用版本号。
