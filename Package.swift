// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Fala",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Fala",
            path: "Sources/Fala",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
