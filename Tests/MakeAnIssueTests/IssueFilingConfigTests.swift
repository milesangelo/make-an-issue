import XCTest
@testable import MakeAnIssue

/// Tests for `IssueFilingConfig` — pure value-type properties, no I/O.
/// Covers the scoped allowedTools string, mcpConfigJSON content, and claudeGitHub defaults.
final class IssueFilingConfigTests: XCTestCase {

    // MARK: - allowedToolsArgument

    func testAllowedToolsArgumentForClaudeGitHub() {
        XCTAssertEqual(
            IssueFilingConfig.claudeGitHub.allowedToolsArgument,
            "mcp__github__issue_write Read Grep Glob",
            "allowedToolsArgument must produce scoped least-privilege grant"
        )
    }

    func testAllowedToolsArgumentIsComputedFromConfig() {
        let config = IssueFilingConfig(
            cliCommand: "codex",
            mcpServerName: "myserver",
            mcpToolName: "create_ticket",
            tokenEnvKey: "MY_TOKEN",
            tokenCommand: "get-token",
            mcpServerJSON: "{}"
        )
        XCTAssertEqual(
            config.allowedToolsArgument,
            "mcp__myserver__create_ticket Read Grep Glob"
        )
    }

    // MARK: - mcpConfigJSON

    func testMcpConfigJSONContainsMcpServersKey() {
        XCTAssertTrue(
            IssueFilingConfig.claudeGitHub.mcpConfigJSON.contains("mcpServers"),
            "mcpConfigJSON must contain 'mcpServers'"
        )
    }

    func testMcpConfigJSONContainsServerName() {
        XCTAssertTrue(
            IssueFilingConfig.claudeGitHub.mcpConfigJSON.contains("\"github\""),
            "mcpConfigJSON must contain the server name key 'github'"
        )
    }

    func testMcpConfigJSONContainsGitHubMCPImage() {
        XCTAssertTrue(
            IssueFilingConfig.claudeGitHub.mcpConfigJSON.contains("ghcr.io/github/github-mcp-server"),
            "mcpConfigJSON must reference the official GitHub MCP Docker image"
        )
    }

    func testMcpConfigJSONContainsIssuesToolset() {
        XCTAssertTrue(
            IssueFilingConfig.claudeGitHub.mcpConfigJSON.contains("GITHUB_TOOLSETS=issues"),
            "mcpConfigJSON must scope the MCP session to 'issues' toolset only"
        )
    }

    // MARK: - claudeGitHub defaults

    func testClaudeGitHubTokenCommand() {
        XCTAssertEqual(
            IssueFilingConfig.claudeGitHub.tokenCommand,
            "gh auth token",
            "Token must be acquired from gh auth token (AUTH-01)"
        )
    }

    func testClaudeGitHubCLICommand() {
        XCTAssertEqual(IssueFilingConfig.claudeGitHub.cliCommand, "claude")
    }

    func testClaudeGitHubMCPServerName() {
        XCTAssertEqual(IssueFilingConfig.claudeGitHub.mcpServerName, "github")
    }

    func testClaudeGitHubMCPToolName() {
        XCTAssertEqual(IssueFilingConfig.claudeGitHub.mcpToolName, "issue_write")
    }

    func testClaudeGitHubTokenEnvKey() {
        XCTAssertEqual(
            IssueFilingConfig.claudeGitHub.tokenEnvKey,
            "GITHUB_PERSONAL_ACCESS_TOKEN"
        )
    }

    // MARK: - Equatable

    func testConfigEquatableToItself() {
        XCTAssertEqual(IssueFilingConfig.claudeGitHub, IssueFilingConfig.claudeGitHub)
    }

    func testConfigsWithDifferentCommandAreNotEqual() {
        let a = IssueFilingConfig(
            cliCommand: "claude",
            mcpServerName: "github",
            mcpToolName: "issue_write",
            tokenEnvKey: "GITHUB_PERSONAL_ACCESS_TOKEN",
            tokenCommand: "gh auth token",
            mcpServerJSON: "{}"
        )
        let b = IssueFilingConfig(
            cliCommand: "codex",
            mcpServerName: "github",
            mcpToolName: "issue_write",
            tokenEnvKey: "GITHUB_PERSONAL_ACCESS_TOKEN",
            tokenCommand: "gh auth token",
            mcpServerJSON: "{}"
        )
        XCTAssertNotEqual(a, b)
    }
}
