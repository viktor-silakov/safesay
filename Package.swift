// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "safesay",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "safesay"),
        .testTarget(name: "SafesayTests", dependencies: ["safesay"]),
    ]
)
