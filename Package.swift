// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-music",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-music", type: .dynamic, targets: ["osaurus_music"])
    ],
    targets: [
        .target(
            name: "osaurus_music",
            path: "Sources/osaurus_music"
        ),
        .testTarget(
            name: "osaurus_musicTests",
            dependencies: ["osaurus_music"],
            path: "Tests/osaurus_musicTests"
        )
    ]
)
