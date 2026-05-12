// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacConnect",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacConnectCore", targets: ["MacConnectCore"]),
        .executable(name: "macconnect", targets: ["MacConnectApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "MacConnectCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/MacConnectCore"
        ),
        .executableTarget(
            name: "MacConnectApp",
            dependencies: ["MacConnectCore"],
            path: "Sources/MacConnectApp"
        ),
        .testTarget(
            name: "MacConnectCoreTests",
            dependencies: [
                "MacConnectCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Tests/MacConnectCoreTests"
        ),
    ]
)
