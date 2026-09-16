// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "monotext",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "monotext", path: "Sources/monotext")
    ]
)
