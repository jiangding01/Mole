// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MoleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoleKit", targets: ["MoleKit"])
    ],
    targets: [
        .target(name: "MoleKit"),
        .testTarget(name: "MoleKitTests", dependencies: ["MoleKit"]),
    ]
)
