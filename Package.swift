// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SSwitcher", targets: ["SSwitcher"])],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "SSwitcher", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"])
    ]
)
