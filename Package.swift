// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTPlayer",
    platforms: [.macOS("14.2")],  // 14.2: Core Audio process taps
    targets: [
        .executableTarget(name: "YTPlayer", path: "Sources/YTPlayer")
    ]
)
