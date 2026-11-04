// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMCRManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CMCRManager", targets: ["CMCRManager"]),
        .executable(name: "cmcrctl", targets: ["cmcrctl"]),
        // CMCR Screen Agent (docs/screen-agent.md): shipped in CMCR Manager.app/Contents/Helpers and installed on the
        // iMacs. It does not link CMCRCore, to stay small and change rarely (every new build of it needs the
        // Screen Recording permission granted again on every iMac when signed ad-hoc).
        .executable(name: "cmcr-screen-agent", targets: ["cmcr-screen-agent"]),
    ],
    targets: [
        .target(name: "CMCRCore"),
        // Everything of the agent that can be tested without a screen: protocol, paths, scaling, JPEG, files.
        .target(name: "ScreenAgentKit"),
        .executableTarget(name: "CMCRManager", dependencies: ["CMCRCore"]),
        .executableTarget(name: "cmcrctl", dependencies: ["CMCRCore"]),
        .executableTarget(name: "cmcr-screen-agent", dependencies: ["ScreenAgentKit"]),
        .testTarget(name: "CMCRCoreTests", dependencies: ["CMCRCore"]),
        .testTarget(name: "CMCRManagerTests", dependencies: ["CMCRManager", "CMCRCore"]),
        .testTarget(name: "ScreenAgentKitTests", dependencies: ["ScreenAgentKit", "CMCRCore"]),
    ]
)
