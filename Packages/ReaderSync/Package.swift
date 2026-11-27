// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReaderSync",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ReaderSync", targets: ["ReaderSync"]),
    ],
    dependencies: [
        .package(path: "../ReaderCore"),
    ],
    targets: [
        .target(
            name: "ReaderSync",
            dependencies: ["ReaderCore"],
            path: "Sources/ReaderSync",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "ReaderSyncTests",
            dependencies: ["ReaderSync", "ReaderCore"],
            path: "Tests/ReaderSyncTests"
        ),
    ]
)
