// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-music",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-music", type: .dynamic, targets: ["osaurus_music"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "osaurus_music",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/osaurus_music"
        ),
        .testTarget(
            name: "osaurus_musicTests",
            dependencies: [
                "osaurus_music",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_musicTests"
        )
    ]
)
