// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalSearch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalSearch", targets: ["LocalSearch"])],
    targets: [.executableTarget(name: "LocalSearch")],
    swiftLanguageModes: [.v5]
)
