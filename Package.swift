// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "make-an-issue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MakeAnIssue", targets: ["MakeAnIssue"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "MakeAnIssue",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/MakeAnIssue"
        ),
        .testTarget(
            name: "MakeAnIssueTests",
            dependencies: ["MakeAnIssue"],
            path: "Tests/MakeAnIssueTests"
        )
    ]
)
