// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMCRManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CMCRManager", targets: ["CMCRManager"]),
        .executable(name: "cmcrctl", targets: ["cmcrctl"]),
    ],
    targets: [
        .target(name: "CMCRCore"),
        .executableTarget(name: "CMCRManager", dependencies: ["CMCRCore"]),
        .executableTarget(name: "cmcrctl", dependencies: ["CMCRCore"]),
        .testTarget(name: "CMCRCoreTests", dependencies: ["CMCRCore"]),
    ]
)
