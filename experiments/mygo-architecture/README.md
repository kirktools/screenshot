# MyGo 架构实验

这是独立分支上的可丢弃兼容性探针，不是正式 Screenshot 客户端，不改变应用构建、版本号、签名或发布。

目标架构为「普通界面/宿主 → 独立应用服务 → 平台适配 → 唯一 Swift StitchCore」。MyGo 不进入应用规则包，平台差异不散落在页面里，也不重写第二份拼接算法。

## 验证范围

- `application/`：会话代际、并发唤起、取消与迟到结果、输出提交；单消费者帧租约、失败释放与不可靠内容禁止导出。只依赖 Go 标准库。
- 探针：直接加载仓库现有 Swift C ABI，运行同一份合成匹配向量、跟踪器生命周期和非法帧拒绝。
- Web 界面：真实 MyGo WebView → Go 设置服务 → Swift 调用，以及页面截图的非空渲染检查。
- 自绘界面：实际 MyGo UI 窗口渲染和截图；并非 AppKit/Win32 原生控件。
- Windows x64 与 ARM64 分别原生编译、运行。实验 EXE 不依赖 .NET，仍需随包的 Swift/VC 运行时；网页模式还依赖 WebView2。

Windows 屏幕采集、选区浮层、焦点、DPI、连续滚动、系统授权、安装和更新不在这个探针的验收范围内。编译成功不代表这些已完成。macOS 真实采集及长图原型的个人操作记录不提交到此目录。

## 重现

将 `sorrycc/mygo` 的固定提交 `8593d227719d4932fea146891ac9f87303d90a24` 检出到仓库 `.build/mygo-framework`。探针通过本地 `replace` 固定使用它，没有跟随分支自动更新。

使用 Go 1.27.3，在此目录执行 `go test ./application`。Windows 先用仓库已有脚本安装/编译共享 Swift 核心；将核心 DLL、实际运行时依赖和 `Tests/Fixtures/stitch-vectors.json` 放到实验 EXE 旁。

```sh
go build -trimpath -tags mygo_noinspector -ldflags '-s -w' -o MyGoProbe.exe .
MyGoProbe.exe core
MyGoProbe.exe
MyGoProbe.exe native
```

CI 使用独立工作流，仅该实验分支的 push 触发；只读权限，不读取签名 secrets，不发布 Release。产物是临时未签名实验程序，保留系统安全保护，不作为用户安装包分发。

## 供应商运行时的路径检查

自己的 EXE/桥接 DLL 和所有文本严格执行仓库公共内容检查。官方 `swiftCore.dll` 可能包含上游 SDK 构建路径；打包脚本只在它与固定 6.4.1 SDK 内文件 SHA-256 完全相同时区分这些供应商路径，并写出来源摘要。仍扫描该 DLL 的凭据规则，不修改供应商二进制，不对其他文件豁免。来源 SDK 的安装归档由现有安装脚本校验固定 SHA-256。
