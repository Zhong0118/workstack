// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowWorkbench", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WindowWorkbench", targets: ["WorkbenchApp"]),
        .executable(name: "window-probe", targets: ["WindowProbe"]),
    ],
    targets: [
        .target(name: "WorkbenchCore"),
        .target(name: "MacWindows", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "WindowProbe", dependencies: ["MacWindows", "WorkbenchCore"]),
        .executableTarget(name: "WorkbenchApp", dependencies: ["WorkbenchCore", "MacWindows"], resources: [.process("Resources")]),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore"]),
    ])
