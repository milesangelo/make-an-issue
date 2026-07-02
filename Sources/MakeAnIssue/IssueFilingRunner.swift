import Foundation

/// Orchestration layer above `CLIRunner` that turns a transcript + bound repo + provider config
/// into a filed GitHub issue.
///
/// Responsibilities (in call order):
/// 1. Acquire the GitHub token (env-var-first, `gh auth token` fallback).
/// 2. Write a per-invocation MCP config tempfile and delete it on every exit path.
/// 3. Build the scoped `claude -p` command (prompt + flags from spike constraints).
/// 4. Run via `CLIRunner` with `cwd = repo.rootURL`, token in environment, 300s timeout.
/// 5. Parse the result through `IssueResultParser` and map errors to `IssueFilingError`.
///
/// All spike-locked constraints are enforced here:
/// - `--strict-mcp-config` prevents global MCP config leakage.
/// - `--allowedTools` is scoped (never `bypassPermissions`).
/// - `--output-format stream-json --verbose` for reliable tool_result parsing (Pitfall 8).
/// - Token passed via environment, never in the command string (T-04-05, Pitfall 2).
/// - Absolute `--mcp-config` path (Pitfall 5 — relative resolves relative to repo cwd).
/// - 300s timeout (Pitfall 7 — AI-CLI path is far slower than transcription).
struct IssueFilingRunner {

    // MARK: - Pure helpers (fully unit-testable, no I/O)

    /// POSIX single-quote escaping for embedding a string as a shell word.
    ///
    /// Replaces each `'` with `'\''` (end-quote, literal single-quote, re-open-quote),
    /// then wraps the result in single quotes. The output is safe to embed directly in a
    /// `/bin/zsh -lc` command string — spaces, dollar signs, backticks, and all special
    /// characters become inert inside single quotes. (T-04-04)
    ///
    /// Reused verbatim from `Transcriber.prepare` — same POSIX single-quote method.
    static func shellEscape(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// App-owned, non-editable trailer appended to every prompt regardless of the user's
    /// drafting instructions (D-02/D-03/SETTINGS-04). Carries the "Issue URL on the LAST line"
    /// output-format contract that `IssueResultParser`'s prose fallback depends on, plus the
    /// no-confirmation directive. Extracted out of the editable prompt body so no user edit —
    /// including adversarial/injection-style guidance — can suppress it; `buildPrompt` always
    /// appends this last.
    static let enforcedTrailer = """
        On the LAST line of your response, output ONLY the new issue URL in this exact format:
        Issue URL: https://github.com/<owner>/<repo>/issues/<NUMBER>

        Do not ask for confirmation; file it directly.
        """

    /// Build the prompt that instructs the AI CLI to investigate the repo and file the issue.
    ///
    /// The prompt embeds the transcript shell-escaped within the text body (the transcript is
    /// shown as a quoted string in prose — the shell escaping happens in `assembleCommand`
    /// when the whole prompt is embedded as a shell argument). `ownerRepo` is optional: when
    /// nil the prompt says "the repository in the current working directory" so the model can
    /// discover the owner/repo from the cwd `.git/config` (v1 assumption — Open Q1).
    ///
    /// `instructions` (D-02) is the user-editable drafting guidance persisted via
    /// `AppState.instructionsKey`. Blank/whitespace-only input falls back to
    /// `IssueFilingConfig.defaultInstructions` (D-08). The prompt is assembled as four ordered
    /// segments — app framing + transcript, then the guidance, then the app-owned file-it
    /// directive (interpolates `config.mcpToolName`), then `enforcedTrailer` last — so the
    /// enforced contract always survives arbitrary edits to `instructions` (SETTINGS-04).
    ///
    /// Output format instruction: "Issue URL: https://…/issues/N" on the last line (now part of
    /// `enforcedTrailer`) provides a reliable prose fallback for `IssueResultParser` when the
    /// structured tool_result parse fails (Pattern 6 in 04-RESEARCH.md).
    static func buildPrompt(
        transcript: String,
        ownerRepo: String?,
        instructions: String = "",
        config: IssueFilingConfig
    ) -> String {
        let repoRef: String
        if let ownerRepo = ownerRepo {
            repoRef = "the repository \(ownerRepo) (current working directory)"
        } else {
            repoRef = "the repository in the current working directory"
        }

        // D-08: blank/whitespace-only instructions fall back to the single canonical default.
        let guidance = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? IssueFilingConfig.defaultInstructions
            : instructions

        return """
        You are make-an-issue: you turn a developer's spoken thought into a GitHub issue for \(repoRef).

        Spoken transcript: "\(transcript)"

        \(guidance)

        File the issue using the \(config.mcpToolName) tool with method=create.

        \(enforcedTrailer)
        """
    }

    /// Assemble the complete `/bin/zsh -lc` command string for the AI CLI invocation.
    ///
    /// Both `--output-format stream-json` AND `--verbose` are required — without `--verbose`
    /// the tool_result events are dropped and the primary parse path never triggers (Pitfall 8).
    /// Never includes `--permission-mode bypassPermissions` or `--dangerously-skip-permissions`
    /// (T-04-06; asserted absent in tests).
    static func assembleCommand(
        prompt: String,
        mcpConfigPath: String,
        config: IssueFilingConfig
    ) -> String {
        let escapedPrompt = shellEscape(prompt)
        let escapedConfigPath = shellEscape(mcpConfigPath)
        return "\(config.cliCommand) -p \(escapedPrompt)"
            + " --mcp-config \(escapedConfigPath) --strict-mcp-config"
            + " --allowedTools \(config.allowedToolsArgument)"
            + " --output-format stream-json --verbose"
    }

    // MARK: - Main entry point

    /// File a GitHub issue from a voice transcript via the AI CLI + MCP.
    ///
    /// - Parameters:
    ///   - transcript: The speech-to-text transcript to turn into an issue.
    ///   - repo: The bound repository (`rootURL` becomes the subprocess's cwd).
    ///   - config: Provider config (default: `IssueFilingConfig.claudeGitHub`).
    ///   - ownerRepo: Optional "owner/repo" string for the prompt. When nil the model
    ///     infers owner/repo from the cwd `.git/config` (v1 Open Q1 assumption).
    /// - Returns: `IssueFilingResult` with the new issue number and URL.
    /// - Throws: `IssueFilingError` — one of:
    ///   - `.tokenAcquisitionFailed` — env var absent/empty and `gh auth token` failed.
    ///   - `.timeout` — AI CLI did not complete within 300s.
    ///   - `.cliFailed(exitCode:stderr:)` — AI CLI exited non-zero.
    ///   - `.permissionDenied(tools:)` — exit 0 but `permission_denials` non-empty.
    ///   - `.parseFailed` — AI CLI exited 0 but no parseable issue URL found.
    ///   - `CancellationError` — the enclosing Task was cancelled; the MCP tempfile
    ///     is still removed by the existing `defer` on this throw path (CANCEL-02).
    static func file(
        transcript: String,
        repo: RepoBinding,
        config: IssueFilingConfig = .claudeGitHub,
        ownerRepo: String? = nil,
        instructions: String = "",
        onProcessStarted: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> IssueFilingResult {

        // Step 1: Acquire token — env-var-first (Open Q3 / AUTH-01).
        // Check the process environment before shelling out to `gh`, making `gh` optional
        // for users who export GITHUB_PERSONAL_ACCESS_TOKEN in their shell profile.
        let token: String
        let envToken = ProcessInfo.processInfo.environment[config.tokenEnvKey]
        if let envToken = envToken, !envToken.isEmpty {
            token = envToken
        } else {
            // Fall back: acquire from the configured token command (e.g. "gh auth token").
            let tokenResult = await CLIRunner().run(command: config.tokenCommand)
            switch tokenResult {
            case .success(let stdout, _, _):
                let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw IssueFilingError.tokenAcquisitionFailed
                }
                token = trimmed
            case .failed, .timeout:
                throw IssueFilingError.tokenAcquisitionFailed
            }
        }
        // Never log the token value. (T-04-05)

        // Step 2: Write MCP config to an absolute tempfile with a UUID suffix.
        // Use absolute path — a relative path would resolve against repo.rootURL (Pitfall 5).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
        try config.mcpConfigJSON.write(to: tempURL, atomically: true, encoding: .utf8)
        // Defer deletion so the file is removed on every exit path — success, throw, or timeout.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Step 3: Assemble command.
        // instructions (D-02/SETTINGS-02) is threaded through from the caller — AppState's
        // default filing closure reads it fresh from UserDefaults per invocation.
        let prompt = buildPrompt(transcript: transcript, ownerRepo: ownerRepo, instructions: instructions, config: config)
        let command = assembleCommand(
            prompt: prompt,
            mcpConfigPath: tempURL.path,
            config: config
        )

        // Step 4: Run via CLIRunner.
        // - cwd = repo.rootURL (ANALYZE-01 — model investigates real code).
        // - Token in environment, never in the command string (AUTH-01 / Pitfall 2).
        // - 300s timeout (Pitfall 7 — AI-CLI path is far slower than transcription).
        // - onSpawn forwarded so the caller can store the pgid for quit-time SIGKILL (CANCEL-03).
        let result = await CLIRunner().run(
            command: command,
            workingDirectory: repo.rootURL,
            environment: [config.tokenEnvKey: token],
            timeout: .seconds(300),
            onSpawn: onProcessStarted
        )

        // Surface CancellationError before interpreting the CLI result. If the enclosing
        // Task was cancelled, CLIRunner's onCancel will have sent SIGTERM to the process
        // group; the process exits and terminationHandler delivers a .failed result. We
        // throw CancellationError here instead of treating the forced-exit as a real
        // filing outcome. The defer { removeItem(tempURL) } above still runs on this
        // throw path, so the MCP tempfile is cleaned up on cancel (CANCEL-02).
        try Task.checkCancellation()

        // Step 5: Map CLIResult → IssueFilingResult (mirrors Transcriber.run switch shape).
        switch result {
        case .timeout:
            throw IssueFilingError.timeout

        case .failed(let exitCode, let stderr):
            throw IssueFilingError.cliFailed(exitCode: exitCode, stderr: stderr)

        case .success(let stdout, _, _):
            do {
                return try IssueResultParser.parse(stdout: stdout)
            } catch let parseError as IssueParseError {
                // Translate IssueParseError → IssueFilingError so callers see one error type.
                switch parseError {
                case .permissionDenied(let tools):
                    throw IssueFilingError.permissionDenied(tools: tools)
                case .noIssueFound, .malformedOutput:
                    throw IssueFilingError.parseFailed
                }
            }
        }
    }
}
