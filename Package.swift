// swift-tools-version: 6.0
import PackageDescription
import Foundation

// 演示源码只在显式的本地开发构建中参与编译。
let buildDocumentationDemo = ProcessInfo.processInfo.environment["SCREENSHOT_BUILD_DEMO"] == "1"
    && ProcessInfo.processInfo.environment["SCREENSHOT_VARIANT"] == "development"
let package = Package(
    name: "Screenshot", defaultLocalization: "zh-Hans", platforms: [.macOS(.v14)],
    products: [.library(name: "StitchCore", targets: ["StitchCore"]), .executable(name: "Screenshot", targets: ["Screenshot"])],
    targets: [.target(name: "StitchCore"),
              .executableTarget(name: "Screenshot", dependencies: ["StitchCore"], exclude: buildDocumentationDemo ? [] : ["Development"], resources: [.process("Localization")], swiftSettings: buildDocumentationDemo ? [.define("SCREENSHOT_DOCUMENTATION_DEMO")] : []),
              .testTarget(name: "StitchCoreTests", dependencies: ["StitchCore"])],
    swiftLanguageModes: [.v5])
