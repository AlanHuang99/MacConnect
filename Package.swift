// swift-tools-version:5.9
import Foundation
import PackageDescription

/// Two distribution channels share one source tree:
///
///   • Direct (GitHub Releases / DMG)  — links Sparkle for in-app updates.
///   • Mac App Store                   — Sparkle-free; the App Store delivers
///                                       updates and rejects apps that bundle
///                                       Sparkle's mach-lookup machinery.
///
/// Setting MACCONNECT_SPARKLE=1 in the environment adds the Sparkle dependency
/// and defines the `SPARKLE` compilation condition (all Sparkle code is gated
/// behind it). The default build — and therefore the future App Store build —
/// never sees Sparkle. See the README's "Distribution channels" section.
let sparkleEnabled = ProcessInfo.processInfo.environment["MACCONNECT_SPARKLE"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0")
]

var appDependencies: [Target.Dependency] = ["MacConnectCore"]

var appSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

if sparkleEnabled {
    packageDependencies.append(
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    )
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
    appSwiftSettings.append(.define("SPARKLE"))
}

let package = Package(
    name: "MacConnect",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacConnectCore", targets: ["MacConnectCore"]),
        .executable(name: "macconnect", targets: ["MacConnectApp"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "MacConnectCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "Sources/MacConnectCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MacConnectApp",
            dependencies: appDependencies,
            path: "Sources/MacConnectApp",
            resources: [
                .process("Resources")
            ],
            swiftSettings: appSwiftSettings
        ),
        .testTarget(
            name: "MacConnectCoreTests",
            dependencies: [
                "MacConnectCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "Tests/MacConnectCoreTests"
        )
    ]
)
