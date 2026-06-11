// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchboard",
            path: "Sources/Notchboard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
