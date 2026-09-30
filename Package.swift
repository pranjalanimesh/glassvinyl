// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlassVinyl",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "GlassVinyl", path: "Sources/GlassVinyl")
    ]
)
