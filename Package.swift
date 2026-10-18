// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wink",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Wink", targets: ["Wink"])],
    targets: [
        .target(name: "ScreenCore", resources: [.process("Resources")]),
        .executableTarget(name: "Wink", dependencies: ["ScreenCore"], resources: [.process("Resources")]),
        .testTarget(name: "ScreenCoreTests", dependencies: ["ScreenCore"])
    ]
)
