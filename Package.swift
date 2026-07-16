// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "make-an-issue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MakeAnIssue", targets: ["MakeAnIssue"]),
        .executable(name: "make-an-issue-worker", targets: ["MakeAnIssueWorkerCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MakeAnIssue",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/MakeAnIssue"
        ),
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "MakeAnIssueWorkerCore",
            dependencies: [
                "CSQLite",
                .product(name: "TOML", package: "swift-toml"),
            ],
            path: "Sources/MakeAnIssueWorkerCore"
        ),
        .executableTarget(
            name: "MakeAnIssueWorkerCLI",
            dependencies: ["MakeAnIssueWorkerCore"],
            path: "Sources/MakeAnIssueWorkerCLI"
        ),
        .testTarget(
            name: "MakeAnIssueTests",
            dependencies: ["MakeAnIssue"],
            path: "Tests/MakeAnIssueTests"
        ),
        .testTarget(
            name: "MakeAnIssueWorkerTests",
            dependencies: ["CSQLite", "MakeAnIssueWorkerCore"],
            path: "Tests/MakeAnIssueWorkerTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
