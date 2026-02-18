// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Clacal",
    platforms: [.macOS(.v15)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Clacal",
            dependencies: []
        ),
        .testTarget(
            name: "ClacalTests",
            dependencies: [
                "Clacal",
            ]
        ),
    ]
)
