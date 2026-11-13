// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "workstack", defaultLocalization: "zh-Hans", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "workstack", targets: ["WorkbenchApp"]),
        .executable(name: "window-probe", targets: ["WindowProbe"]),
    ],
    targets: [
        .target(name: "WorkbenchCore"),
        .target(name: "MacWindows", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "WindowProbe", dependencies: ["MacWindows", "WorkbenchCore"]),
        .executableTarget(name: "WorkbenchApp", dependencies: ["WorkbenchCore", "MacWindows"], resources: [.process("Resources")]),
        .testTarget(name: "WorkbenchAppTests", dependencies: ["WorkbenchApp", "WorkbenchCore", "MacWindows"]),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore"]),
    ])
