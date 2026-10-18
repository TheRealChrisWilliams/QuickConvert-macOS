// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickConvert",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuickConvert", targets: ["QuickConvert"])],
    targets: [
        .target(name: "ConvertCore"),
        .executableTarget(name: "QuickConvert", dependencies: ["ConvertCore"]),
        .testTarget(name: "ConvertCoreTests", dependencies: ["ConvertCore"])
    ],
    swiftLanguageVersions: [.v5]
)
