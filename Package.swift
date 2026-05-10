// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacConnect",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacConnectCore", targets: ["MacConnectCore"]),
        .executable(name: "macconnect", targets: ["MacConnectApp"]),
    ],
    targets: [
        .target(
            name: "MacConnectCore",
            path: "Sources/MacConnectCore"
        ),
        .executableTarget(
            name: "MacConnectApp",
            dependencies: ["MacConnectCore"],
            path: "Sources/MacConnectApp"
        ),
        .testTarget(
            name: "MacConnectCoreTests",
            dependencies: ["MacConnectCore"],
            path: "Tests/MacConnectCoreTests"
        ),
    ]
)
