import XCTest
@testable import MakeAnIssue

final class IssueFilingRunnerTests: XCTestCase {

    // MARK: - buildPrompt

    func testBuildPromptContainsTranscript() {
        let transcript = "We need a dark mode toggle in the settings screen."
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: transcript,
            ownerRepo: "owner/repo",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            prompt.contains(transcript),
            "buildPrompt must embed the transcript verbatim, got:\n\(prompt)"
        )
    }

    func testBuildPromptContainsIssueWriteToolName() {
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "test",
            ownerRepo: nil,
            config: .claudeGitHub
        )
        XCTAssertTrue(
            prompt.contains("issue_write"),
            "buildPrompt must reference the mcpToolName 'issue_write', got:\n\(prompt)"
        )
    }

    func testBuildPromptContainsMethodCreate() {
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "test",
            ownerRepo: nil,
            config: .claudeGitHub
        )
        XCTAssertTrue(
            prompt.contains("method=create"),
            "buildPrompt must instruct the model to use method=create, got:\n\(prompt)"
        )
    }

    func testBuildPromptContainsIssueURLMarker() {
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "test",
            ownerRepo: nil,
            config: .claudeGitHub
        )
        XCTAssertTrue(
            prompt.contains("Issue URL:"),
            "buildPrompt must include 'Issue URL:' instruction for reliable prose fallback, got:\n\(prompt)"
        )
    }

    func testBuildPromptWithNilOwnerRepoUsesCWDPhrase() {
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "test",
            ownerRepo: nil,
            config: .claudeGitHub
        )
        XCTAssertTrue(
            prompt.contains("current working directory"),
            "When ownerRepo is nil, prompt must reference 'current working directory' so model infers owner/repo, got:\n\(prompt)"
        )
    }

    func testBuildPromptWithOwnerRepoEmbeddsIt() {
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "test",
            ownerRepo: "acme/widget",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            prompt.contains("acme/widget"),
            "When ownerRepo is provided, prompt must embed it, got:\n\(prompt)"
        )
    }

    func testBuildPromptInstructsFileDirectly() {
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "test",
            ownerRepo: nil,
            config: .claudeGitHub
        )
        // Per accepted_v1_behavior: no confirmation gate — "file it directly"
        XCTAssertTrue(
            prompt.contains("Do not ask for confirmation"),
            "buildPrompt must instruct 'Do not ask for confirmation; file it directly', got:\n\(prompt)"
        )
    }

    // MARK: - shellEscape

    func testShellEscapeWrapsInSingleQuotes() {
        let result = IssueFilingRunner.shellEscape("hello world")
        XCTAssertEqual(result, "'hello world'")
    }

    func testShellEscapeHandlesSingleQuote() {
        // Input: it's — Output: 'it'\''s'
        let result = IssueFilingRunner.shellEscape("it's")
        XCTAssertEqual(result, "'it'\\''s'")
    }

    func testShellEscapeHandlesSpecialShellCharacters() {
        // Dollar, backtick, semicolon, etc. are all inert inside single quotes.
        let result = IssueFilingRunner.shellEscape("$PATH; `rm -rf /`")
        XCTAssertEqual(result, "'$PATH; `rm -rf /`'")
    }

    // MARK: - assembleCommand

    func testCommandAssemblyContainsStrictMCPConfig() {
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: "test prompt",
            mcpConfigPath: "/tmp/test.json",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            cmd.contains("--strict-mcp-config"),
            "Command must contain --strict-mcp-config, got:\n\(cmd)"
        )
    }

    func testCommandAssemblyContainsStreamJSON() {
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: "test prompt",
            mcpConfigPath: "/tmp/test.json",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            cmd.contains("--output-format stream-json"),
            "Command must contain --output-format stream-json, got:\n\(cmd)"
        )
    }

    func testCommandAssemblyContainsVerbose() {
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: "test prompt",
            mcpConfigPath: "/tmp/test.json",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            cmd.contains("--verbose"),
            "Command must contain --verbose (Pitfall 8 — required for tool_result events), got:\n\(cmd)"
        )
    }

    func testCommandAssemblyContainsScopedAllowedTools() {
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: "test prompt",
            mcpConfigPath: "/tmp/test.json",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            cmd.contains("--allowedTools mcp__github__issue_write Read Grep Glob"),
            "Command must include scoped --allowedTools grant, got:\n\(cmd)"
        )
    }

    func testCommandAssemblyDoesNotContainBypassPermissions() {
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: "test prompt",
            mcpConfigPath: "/tmp/test.json",
            config: .claudeGitHub
        )
        XCTAssertFalse(
            cmd.contains("bypassPermissions"),
            "Command must NOT contain 'bypassPermissions' (T-04-06), got:\n\(cmd)"
        )
        XCTAssertFalse(
            cmd.contains("dangerously-skip"),
            "Command must NOT contain 'dangerously-skip' (T-04-06), got:\n\(cmd)"
        )
    }

    func testCommandAssemblyEscapesTranscriptWithSingleQuote() {
        // A transcript containing a single quote must be escaped as '\'' in the output.
        let prompt = IssueFilingRunner.buildPrompt(
            transcript: "it's broken",
            ownerRepo: nil,
            config: .claudeGitHub
        )
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: prompt,
            mcpConfigPath: "/tmp/test.json",
            config: .claudeGitHub
        )
        XCTAssertTrue(
            cmd.contains("'\\''"),
            "Command must POSIX-escape single quotes as '\\'' in the shell command, got:\n\(cmd)"
        )
        // Also confirm there is no raw unescaped single-quote that would break shell parsing.
        // A correctly-escaped shell word can only have '\'' between outer single-quoted segments.
        // The simplest structural check: after stripping '\'' the remaining content has no lone '.
        let stripped = cmd.replacingOccurrences(of: "'\\''", with: "ESCAPED")
        // Remove the outer shell-word wrapping single quotes (they come in pairs around word segments).
        // The remaining string should not contain any lone single-quote characters.
        let remainingQuotes = stripped.filter { $0 == "'" }
        // Each outer single-quote pair contributes 2 characters — count must be even.
        XCTAssertEqual(
            remainingQuotes.count % 2, 0,
            "Remaining single quotes must be balanced (even count), got \(remainingQuotes.count) in:\n\(stripped)"
        )
    }

    func testCommandAssemblyContainsMCPConfigFlag() {
        let configPath = "/tmp/make-an-issue-mcp-abc.json"
        let cmd = IssueFilingRunner.assembleCommand(
            prompt: "test",
            mcpConfigPath: configPath,
            config: .claudeGitHub
        )
        XCTAssertTrue(
            cmd.contains("--mcp-config"),
            "Command must contain --mcp-config flag, got:\n\(cmd)"
        )
        XCTAssertTrue(
            cmd.contains(configPath),
            "Command must embed the config path, got:\n\(cmd)"
        )
    }

    // MARK: - file() token-failure path

    func testFileThrowsTokenAcquisitionFailedWhenTokenCommandFails() async throws {
        // "false" is a POSIX shell builtin that exits non-zero immediately.
        // It is universally available and makes gh auth optional in this test.
        let failConfig = IssueFilingConfig(
            cliCommand: "claude",
            mcpServerName: "github",
            mcpToolName: "issue_write",
            tokenEnvKey: "MAI_NONEXISTENT_TOKEN_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            tokenCommand: "false",
            mcpServerJSON: IssueFilingConfig.claudeGitHub.mcpServerJSON
        )

        let repo = try makeTemporaryRepo()
        defer { try? FileManager.default.removeItem(at: repo.rootURL) }

        do {
            _ = try await IssueFilingRunner.file(
                transcript: "Test transcript",
                repo: repo,
                config: failConfig
            )
            XCTFail("Expected tokenAcquisitionFailed to be thrown")
        } catch let error as IssueFilingError {
            XCTAssertEqual(
                error, .tokenAcquisitionFailed,
                "Expected .tokenAcquisitionFailed, got: \(error)"
            )
        }
    }

    func testFileWithFailingTokenCommandLeavesNoTempFile() async throws {
        // Verify that the MCP tempfile cleanup defer runs even when token acquisition fails
        // (which happens before the tempfile is written). Also verify no stale make-an-issue-mcp-*
        // files appear from a previous failed run.
        let uniqueTokenKey = "MAI_NONEXISTENT_TOKEN_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let failConfig = IssueFilingConfig(
            cliCommand: "claude",
            mcpServerName: "github",
            mcpToolName: "issue_write",
            tokenEnvKey: uniqueTokenKey,
            tokenCommand: "false",
            mcpServerJSON: IssueFilingConfig.claudeGitHub.mcpServerJSON
        )

        let repo = try makeTemporaryRepo()
        defer { try? FileManager.default.removeItem(at: repo.rootURL) }

        let tempDir = FileManager.default.temporaryDirectory
        let existingMCPFiles = (try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("make-an-issue-mcp-") } ?? []

        // Attempt filing — must fail at token acquisition
        _ = try? await IssueFilingRunner.file(
            transcript: "Test transcript",
            repo: repo,
            config: failConfig
        )

        // No new make-an-issue-mcp-* files should have been created (token fails before tempfile write).
        let afterMCPFiles = (try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("make-an-issue-mcp-") } ?? []

        XCTAssertEqual(
            afterMCPFiles.count, existingMCPFiles.count,
            "No MCP tempfiles should remain after a token-acquisition failure. Before: \(existingMCPFiles.count), after: \(afterMCPFiles.count)"
        )
    }

    // MARK: - Private helpers

    /// Create a minimal temporary git repo for use as a `RepoBinding`.
    private func makeTemporaryRepo() throws -> RepoBinding {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mai-test-repo-\(UUID().uuidString)", isDirectory: true)
        let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        return RepoBinding(
            rootURL: tmpDir,
            displayName: tmpDir.lastPathComponent,
            displayPath: tmpDir.path
        )
    }
}
