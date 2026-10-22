// swift-tools-version: 6.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Eemini",
    platforms: [
        .macOS(.v27)
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.2"),
        .package(url: "https://github.com/DiscordBM/DiscordBM.git", from: "1.16.2"),
        .package(url: "https://github.com/karwa/swift-url.git", from: "0.4.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Eemini",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "WebURL", package: "swift-url"),
                .product(name: "DiscordBM", package: "DiscordBM"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
