// swift-tools-version: 6.0
// 素材整理器
// OrganizerCore 与命令行在 Linux 和 macOS 上都能编译。
// OrganizerApp 只用 SwiftUI / AppKit / FSEvents / Carbon / AVFoundation / Security，
// 因此只在 macOS 上加入包。Linux 上 `swift test` 不会编译这些文件。

import PackageDescription

var products: [Product] = [
    .library(name: "OrganizerCore", targets: ["OrganizerCore"]),
    .executable(name: "chanwu", targets: ["OrganizerCLI"]),
]

var targets: [Target] = [
    .target(
        name: "OrganizerPosix",
        path: "Sources/OrganizerPosix",
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
        name: "OrganizerCore",
        dependencies: ["OrganizerPosix"],
        path: "Sources/OrganizerCore"
    ),
    .executableTarget(
        name: "OrganizerCLI",
        dependencies: ["OrganizerCore"],
        path: "Sources/OrganizerCLI"
    ),
    .testTarget(
        name: "OrganizerCoreTests",
        dependencies: ["OrganizerCore"],
        path: "Tests/OrganizerCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "ChanwuApp", targets: ["OrganizerApp"]))
targets.append(
    .executableTarget(
        name: "OrganizerApp",
        dependencies: ["OrganizerCore"],
        path: "Sources/OrganizerApp"
    )
)
#endif

let package = Package(
    name: "Chanwu",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
