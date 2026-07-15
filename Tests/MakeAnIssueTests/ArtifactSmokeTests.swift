import XCTest
@testable import MakeAnIssue

final class ArtifactSmokeTests: XCTestCase {
    func testFakeProviderFilesIssueThroughRealRunner() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fakeClaude = environment["MAKE_AN_ISSUE_SMOKE_FAKE_CLAUDE"], !fakeClaude.isEmpty else {
            throw XCTSkip("Only run from scripts/smoke-app.sh")
        }

        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("make-an-issue-smoke-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let config = IssueFilingConfig(
            cliCommand: fakeClaude,
            mcpServerName: "github",
            mcpToolName: "issue_write",
            tokenEnvKey: "MAKE_AN_ISSUE_SMOKE_TOKEN",
            tokenCommand: "false",
            mcpServerJSON: #"{"command":"false"}"#
        )
        let repo = RepoBinding(
            rootURL: repoURL,
            displayName: "smoke-repo",
            displayPath: repoURL.path
        )
        let tempDirectory = FileManager.default.temporaryDirectory
        let existingMCPFiles = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("make-an-issue-mcp-") }

        let result = try await IssueFilingRunner.file(
            transcript: "Smoke-test issue filing without network access.",
            repo: repo,
            config: config,
            ownerRepo: "example/smoke"
        )

        XCTAssertEqual(result.number, 4242)
        XCTAssertEqual(result.url, "https://github.com/example/smoke/issues/4242")

        let remainingMCPFiles = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("make-an-issue-mcp-") }
        XCTAssertEqual(remainingMCPFiles, existingMCPFiles, "Runner must remove its temporary MCP config")
    }
}
