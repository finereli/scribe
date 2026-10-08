// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scribe",
    // Core Audio process taps (system audio capture) need macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "Scribe", path: "Sources/Scribe")
    ]
)
