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
        // Test target intentionally omitted: XCTest is only available when
        // building with full Xcode, not Command Line Tools alone. To run the
        // PacketTests under `Tests/MacConnectCoreTests/`, install Xcode and
        // re-add this entry:
        //
        //   .testTarget(
        //       name: "MacConnectCoreTests",
        //       dependencies: ["MacConnectCore"],
        //       path: "Tests/MacConnectCoreTests"
        //   ),
    ]
)
