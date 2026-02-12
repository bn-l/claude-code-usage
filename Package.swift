// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClaudeCodeUsage",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeUsage",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
