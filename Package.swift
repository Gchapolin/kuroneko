// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kuroneko",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KuronekoCore", targets: ["KuronekoCore"]),
        .executable(name: "Kuroneko", targets: ["Kuroneko"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "KuronekoCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // The `kuroneko` command, shipped inside the app bundle.
        .executableTarget(
            name: "KuronekoCLI",
            dependencies: ["KuronekoCore"]
        ),
        .executableTarget(
            name: "Kuroneko",
            dependencies: [
                "KuronekoCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .testTarget(
            name: "KuronekoCoreTests",
            dependencies: ["KuronekoCore"]
        ),
    ]
)
