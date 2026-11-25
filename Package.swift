// swift-tools-version: 5.9

import PackageDescription

// Builds the Tuno executable only; build.sh wraps it into Tuno.app together
// with the bridge dylib and resources.
let package = Package(
    name: "Tuno",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local while NotchKit is being extracted; a versioned GitHub URL later.
        .package(path: "../NotchKit"),
    ],
    targets: [
        .executableTarget(name: "Tuno", dependencies: ["NotchKit"], path: "Sources/App"),
    ]
)
