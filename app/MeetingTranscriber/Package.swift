// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ClassScribe",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "ClassScribe", targets: ["ClassScribe"]),
    ],
    dependencies: [
        // Fixed upstream release: clones and GitHub Actions resolve this without
        // relying on the developer-only .dependencies directory.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(path: "../../tools/audiotap"),
    ],
    targets: [
        .executableTarget(
            name: "ClassScribe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "AudioTapLib", package: "audiotap"),
            ],
            path: "ClassScribeSources",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ClassScribeTests",
            dependencies: ["ClassScribe"],
            path: "ClassScribeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
