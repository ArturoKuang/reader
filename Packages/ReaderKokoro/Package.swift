// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReaderKokoro",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ReaderKokoro", targets: ["ReaderKokoro"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.4",
            traits: ["TTS", "NemoTextProcessing"]
        ),
    ],
    targets: [
        .target(
            name: "ReaderKokoro",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
