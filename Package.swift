// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Screenshot", defaultLocalization: "zh-Hans", platforms: [.macOS(.v14)],
    products: [.library(name: "StitchCore", targets: ["StitchCore"]), .executable(name: "Screenshot", targets: ["Screenshot"])],
    targets: [.target(name: "StitchCore"),
              .executableTarget(name: "Screenshot", dependencies: ["StitchCore"], resources: [.process("Localization")]),
              .testTarget(name: "StitchCoreTests", dependencies: ["StitchCore"])],
    swiftLanguageModes: [.v5])
