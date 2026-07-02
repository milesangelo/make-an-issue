/// Provider seam for AI-CLI issue filing.
///
/// `IssueFilingConfig` captures everything that varies per provider (CLI command, MCP server
/// name/tool name, token env key, token acquisition command, MCP server JSON block).
/// The rest of `IssueFilingRunner` is generic over this config.
///
/// ## Validated v1 leg
///
/// Only the **claude + GitHub** leg (`IssueFilingConfig.claudeGitHub`) is validated in v1:
/// it is proven end-to-end by Spike 002 (real issue filed, ~30s, no interaction).
///
/// ## Deferred legs (PROVIDER-01)
///
/// - **codex + GitHub**: `codex exec` non-interactive MCP writes are broken upstream
///   (stdin-EOF auto-cancel). Codex remains configurable but is NOT the default and is
///   NOT validated in v1. Revisit after an upstream fix is confirmed.
/// - **Atlassian/Jira**: Zero-token non-interactive Jira write may require interactive OAuth.
///   Deferred per REQUIREMENTS.md PROVIDER-01. Revisit after a spike confirms feasibility.
///
/// These legs can be expressed as custom `IssueFilingConfig` instances once validated, without
/// any changes to the runner or parser.
struct IssueFilingConfig: Equatable {

    // MARK: - Fields

    /// The AI CLI binary to invoke (e.g. `"claude"`).
    let cliCommand: String

    /// The MCP server name as registered in `--allowedTools` and the mcp-config JSON
    /// (e.g. `"github"`).
    let mcpServerName: String

    /// The MCP tool name to grant (e.g. `"issue_write"`).
    let mcpToolName: String

    /// The environment variable key that carries the bearer token passed to the subprocess
    /// (e.g. `"GITHUB_PERSONAL_ACCESS_TOKEN"`). The token is passed via `Process.environment`,
    /// never embedded in the command string.
    let tokenEnvKey: String

    /// Shell command that prints the raw token to stdout (e.g. `"gh auth token"`).
    /// The runner invokes this via `CLIRunner` before the main filing call.
    let tokenCommand: String

    /// The JSON value for this provider's entry in `mcpServers`. Combined with `mcpServerName`
    /// to produce the full `mcpConfigJSON`.
    let mcpServerJSON: String

    // MARK: - Computed properties

    /// The scoped `--allowedTools` argument value for this config.
    ///
    /// Grants least-privilege: only the specific issue-write tool for this provider, plus the
    /// built-in repo-read tools (`Read`, `Grep`, `Glob`) so the model can investigate the repo.
    /// Never uses `--permission-mode bypassPermissions`. [Spike 001]
    var allowedToolsArgument: String {
        "mcp__\(mcpServerName)__\(mcpToolName) Read Grep Glob"
    }

    /// The complete MCP config JSON body to write to the per-invocation tempfile.
    ///
    /// Format: `{"mcpServers":{"<mcpServerName>":<mcpServerJSON>}}`.
    /// The tempfile is written to `FileManager.default.temporaryDirectory` and deleted
    /// after each `CLIRunner.run()` call via `defer`.
    var mcpConfigJSON: String {
        #"{"mcpServers":{"\#(mcpServerName)":\#(mcpServerJSON)}}"#
    }

    // MARK: - Default

    /// Validated v1 default: `claude -p` + GitHub MCP server via Docker, scoped to issues.
    ///
    /// - `--allowedTools`: `mcp__github__issue_write Read Grep Glob` (least privilege).
    /// - MCP server: `ghcr.io/github/github-mcp-server` over stdio via Docker.
    /// - Token: acquired from `gh auth token`, passed as `GITHUB_PERSONAL_ACCESS_TOKEN`
    ///   in `Process.environment` — NOT embedded in the command string.
    /// - `GITHUB_TOOLSETS=issues` scopes Docker's MCP session to the issues tool only.
    ///
    /// Proven end-to-end in Spike 002 (real issue #89 filed in pulsedemon/netshooter, ~30s).
    static let claudeGitHub = IssueFilingConfig(
        cliCommand: "claude",
        mcpServerName: "github",
        mcpToolName: "issue_write",
        tokenEnvKey: "GITHUB_PERSONAL_ACCESS_TOKEN",
        tokenCommand: "gh auth token",
        mcpServerJSON: """
        {"command":"docker","args":["run","-i","--rm","-e","GITHUB_PERSONAL_ACCESS_TOKEN","-e","GITHUB_TOOLSETS=issues","ghcr.io/github/github-mcp-server"]}
        """
    )

    // MARK: - Default drafting instructions (D-06)

    /// The single canonical default drafting-guidance text: the persona/investigation prose
    /// extracted from `IssueFilingRunner.buildPrompt()`'s original step 1. This is the ONE
    /// source of truth for both the initial `@AppStorage` default in SettingsView's Instructions
    /// tab and the "Reset to Default" button (D-07), and the value `buildPrompt` substitutes
    /// when the persisted instructions are blank/whitespace-only (D-08).
    ///
    /// Deliberately excludes the app-owned `method=create` directive (interpolates
    /// `config.mcpToolName`, not user-editable) and the URL trailer (owned by
    /// `IssueFilingRunner.enforcedTrailer`, D-02/D-03) — those stay structural, not guidance.
    static let defaultInstructions = "Briefly investigate the repo (README, relevant source files) to write a specific, accurate issue."
}

// MARK: - IssueFilingError

/// Errors that `IssueFilingRunner` can throw during the filing pipeline.
///
/// Mirrors the `TranscriberError` declaration style (typed enum, `Error, Equatable`).
enum IssueFilingError: Error, Equatable {
    /// `gh auth token` (or the configured `tokenCommand`) failed or returned an empty string.
    case tokenAcquisitionFailed
    /// The AI CLI subprocess did not complete within the allowed timeout (default 300s).
    case timeout
    /// The AI CLI subprocess exited with a non-zero status.
    case cliFailed(exitCode: Int32, stderr: String)
    /// The `permission_denials` array was non-empty — the issue tool was not granted.
    case permissionDenied(tools: [String])
    /// The AI CLI exited 0 but the stdout could not be parsed for an issue url.
    case parseFailed
}
