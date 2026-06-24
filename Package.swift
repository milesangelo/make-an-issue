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
    targets: [
        .executableTarget(
            name: "MakeAnIssue",
            path: "Sources/MakeAnIssue"
        ),
        .testTarget(
            name: "MakeAnIssueTests",
            dependencies: ["MakeAnIssue"],
            path: "Tests/MakeAnIssueTests"
        )
    ]
)
