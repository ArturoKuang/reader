// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReaderCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
    ],
    targets: [
        .target(
            name: "ReaderCore",
            dependencies: ["CZLIB"],
            path: "Sources/ReaderCore"
        ),
        .systemLibrary(
            name: "CZLIB",
            path: "Sources/CZLIB",
            providers: [
                .apt(["zlib1g-dev"]),
                .brew(["zlib"]),
            ]
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"],
            path: "Tests/ReaderCoreTests"
        ),
    ]
)
