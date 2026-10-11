// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TerminatorKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "TerminatorCore", targets: ["TerminatorCore"]),
        .library(name: "TerminatorPersistence", targets: ["TerminatorPersistence"]),
        .library(name: "TerminatorSecurity", targets: ["TerminatorSecurity"]),
        .library(name: "TerminatorSSH", targets: ["TerminatorSSH"]),
        .library(name: "TerminatorFeatures", targets: ["TerminatorFeatures"]),
        .library(name: "TerminatorTestSupport", targets: ["TerminatorTestSupport"]),
        .executable(name: "terminator-attach", targets: ["TerminatorAttach"]),
        .executable(name: "terminator-service", targets: ["TerminatorConnectionService"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
    ],
    targets: [
        .target(name: "TerminatorCore", resources: [.process("Resources")]),
        .target(
            name: "TerminatorPersistence",
            dependencies: ["TerminatorCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "TerminatorSecurity",
            dependencies: ["TerminatorCore", "CBcryptPBKDF"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "TerminatorSSH",
            dependencies: [
                "TerminatorCore",
                "TerminatorSecurity",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TerminatorAttach",
            dependencies: ["TerminatorCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TerminatorConnectionService",
            dependencies: [
                "TerminatorCore",
                "TerminatorPersistence",
                "TerminatorSecurity",
                "TerminatorSSH",
            ]
        ),
        .target(
            name: "CBcryptPBKDF",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "TerminatorFeatures",
            dependencies: ["TerminatorCore"],
            resources: [.process("Resources")]
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
            dependencies: ["TerminatorCore", "TerminatorSecurity", "TerminatorTestSupport"]
        ),
        .testTarget(
            name: "TerminatorFeaturesTests",
            dependencies: ["TerminatorCore", "TerminatorFeatures", "TerminatorTestSupport"]
        ),
        .testTarget(
            name: "TerminatorSSHTests",
            dependencies: ["TerminatorCore", "TerminatorSSH", "TerminatorTestSupport"]
        ),
    ]
)
