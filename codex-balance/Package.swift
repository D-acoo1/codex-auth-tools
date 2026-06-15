// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexBalance",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexBalance", targets: ["CodexBalance"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexBalance",
            path: "Sources/CodexBalance"
        ),
    ]
)
