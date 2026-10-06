// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalSearch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalSearch", targets: ["LocalSearch"])],
    targets: [
        .executableTarget(name: "LocalSearch", resources: [.process("Resources")]),
        .testTarget(name: "LocalSearchTests", dependencies: ["LocalSearch"])
    ],
    swiftLanguageModes: [.v5]
)
