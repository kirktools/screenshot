// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KirkScreenshot", defaultLocalization: "zh-Hans", platforms: [.macOS(.v14)],
    products: [.library(name: "StitchCore", targets: ["StitchCore"]), .executable(name: "KirkScreenshot", targets: ["KirkScreenshot"])],
    targets: [.target(name: "StitchCore"),
              .executableTarget(name: "KirkScreenshot", dependencies: ["StitchCore"], resources: [.process("Localization")]),
              .testTarget(name: "StitchCoreTests", dependencies: ["StitchCore"])],
    swiftLanguageModes: [.v5])
