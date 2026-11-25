// swift-tools-version: 5.9

import PackageDescription

// Builds the Tuno executable only; build.sh wraps it into Tuno.app together
// with the bridge dylib and resources.
let package = Package(
    name: "Tuno",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tuno", path: "Sources/App"),
    ]
)
