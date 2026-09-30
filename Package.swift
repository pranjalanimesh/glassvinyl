// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTPlayer",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "YTPlayer", path: "Sources/YTPlayer")
    ]
)
