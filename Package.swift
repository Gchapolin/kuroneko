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
    ],
    targets: [
        .target(
            name: "KuronekoCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "Kuroneko",
            dependencies: ["KuronekoCore"]
        ),
        .testTarget(
            name: "KuronekoCoreTests",
            dependencies: ["KuronekoCore"]
        ),
    ]
)
