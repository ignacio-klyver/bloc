// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bloc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bloc",
            path: "Sources/Bloc",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
