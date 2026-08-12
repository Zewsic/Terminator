// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TerminatorKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "TerminatorCore", targets: ["TerminatorCore"]),
        .library(name: "TerminatorPersistence", targets: ["TerminatorPersistence"]),
        .library(name: "TerminatorSecurity", targets: ["TerminatorSecurity"]),
        .library(name: "TerminatorFeatures", targets: ["TerminatorFeatures"]),
        .library(name: "TerminatorTestSupport", targets: ["TerminatorTestSupport"]),
    ],
    targets: [
        .target(name: "TerminatorCore"),
        .target(
            name: "TerminatorPersistence",
            dependencies: ["TerminatorCore"]
        ),
        .target(
            name: "TerminatorSecurity",
            dependencies: ["TerminatorCore"]
        ),
        .target(
            name: "TerminatorFeatures",
            dependencies: ["TerminatorCore"]
        ),
        .target(
            name: "TerminatorTestSupport",
            dependencies: ["TerminatorCore"]
        ),
        .testTarget(
            name: "TerminatorCoreTests",
            dependencies: ["TerminatorCore"]
        ),
        .testTarget(
            name: "TerminatorPersistenceTests",
            dependencies: ["TerminatorCore", "TerminatorPersistence", "TerminatorTestSupport"]
        ),
        .testTarget(
            name: "TerminatorSecurityTests",
            dependencies: ["TerminatorCore", "TerminatorSecurity"]
        ),
        .testTarget(
            name: "TerminatorFeaturesTests",
            dependencies: ["TerminatorCore", "TerminatorFeatures", "TerminatorTestSupport"]
        ),
    ]
)
