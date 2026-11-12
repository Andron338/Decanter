// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Decanter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DecanterCore", targets: ["DecanterCore"]),
        .executable(name: "Decanter", targets: ["Decanter"]),
    ],
    targets: [
        .target(name: "DecanterCore"),
        .executableTarget(name: "Decanter", dependencies: ["DecanterCore"]),
        .executableTarget(name: "decanter-cli", dependencies: ["DecanterCore"]),
        .testTarget(name: "DecanterCoreTests", dependencies: ["DecanterCore"]),
    ]
)
