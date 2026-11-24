// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmartRoom",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "SmartRoom", path: "Sources/SmartRoom")
    ]
)
