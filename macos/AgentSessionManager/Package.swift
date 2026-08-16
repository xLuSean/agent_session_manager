// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgentSessionManager",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentSessionManagerCore", targets: ["AgentSessionManagerCore"]),
        .library(
            name: "AgentSessionManagerFixtures",
            targets: ["AgentSessionManagerFixtures"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite3",
            path: "Sources/CSQLite3"
        ),
        .target(
            name: "AgentSessionManagerCore",
            dependencies: ["CSQLite3"]
        ),
        .target(
            name: "AgentSessionManagerFixtures",
            dependencies: ["AgentSessionManagerCore"]
        ),
        .testTarget(
            name: "AgentSessionManagerCoreTests",
            dependencies: [
                "AgentSessionManagerCore",
                "AgentSessionManagerFixtures",
                "CSQLite3",
            ],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
