// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SSwitcher", targets: ["SSwitcher"]),
        .executable(name: "SSwitcherInputMethod", targets: ["SSwitcherInputMethod"])
    ],
    targets: [
        .target(name: "SwitcherCore"),
        .target(name: "InputMethodSupport"),
        .executableTarget(name: "SSwitcher", dependencies: ["SwitcherCore", "InputMethodSupport"]),
        .executableTarget(name: "SSwitcherInputMethod", dependencies: ["InputMethodSupport", "SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"])
    ]
)
