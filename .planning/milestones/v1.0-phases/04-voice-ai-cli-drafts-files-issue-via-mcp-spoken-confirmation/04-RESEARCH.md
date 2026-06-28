# Phase 4: Voice → AI CLI Drafts & Files Issue (via MCP) + Spoken Confirmation - Research

**Researched:** 2026-06-25
**Domain:** Swift subprocess invocation, claude CLI stream-json parsing, AVSpeechSynthesizer, provider-agnostic command seam
**Confidence:** MEDIUM (spike-validated for the CLI/MCP leg; ASSUMED for some Swift-side details)

---

## Summary

Phase 4 is the final v1 integration step: it wires the transcript produced by Phase 3 into the user's `claude` CLI, which investigates the bound repo, drafts and files the issue via its own MCP session, and reports back. The app then parses the issue number from the CLI's stdout and speaks "created issue #N" using native macOS TTS.

The CLI/MCP mechanics are **fully validated by Spike 001 and Spike 002** — scoped `--allowedTools` grant, `--output-format stream-json --verbose`, parsing the `url` field (never `id`), and inspecting `permission_denials`. These are locked decisions and the research cites the spike findings rather than re-deriving them.

The open implementation work is entirely on the **Swift side**: extending `CLIRunner` to pass a generated `mcp-config.json`, populating `Process.environment` for token passthrough, parsing the JSONL stdout in Swift, wiring `AVSpeechSynthesizer` for spoken confirmation, and providing a provider-agnostic command seam (PROVIDER-01).

**Primary recommendation:** Reuse `CLIRunner` as-is (it already supports `workingDirectory` and separate stdout/stderr). Add an `IssueFilingRunner` layer above it that generates the per-invocation MCP config JSON, assembles the `claude -p` command string, calls `CLIRunner.run`, and parses the result. Keep `AVSpeechSynthesizer` in `AppState` as a stored property to avoid premature deallocation.

---

## Project Constraints (from CLAUDE.md)

- Think before coding; state assumptions; push back when warranted.
- Minimum code that solves the problem. No speculative features.
- Touch only what is needed; match existing style.
- Skill routing: spike findings → `spike-findings-make-an-issue` skill.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ANALYZE-01 | Invoke the user's AI CLI with transcript and working directory = bound repo | CLIRunner already accepts `workingDirectory`; IssueFilingRunner assembles the `claude -p` command with prompt and flags |
| ANALYZE-02 | The AI CLI drafts the issue from transcript + repo context | No Swift work — the model does this autonomously when cwd = bound repo and Read/Grep/Glob are in `--allowedTools` |
| ISSUE-01 | CLI files the issue through its own MCP server; app holds no token | MCP config written to a temp file; token passed via `Process.environment`; never written to a persistent file |
| ISSUE-02 | Parse the created issue's number/URL from CLI stdout | Two-pass Swift parser: walk `tool_result` blocks in JSONL for the `url` field; fall back to prose regex on the `result` string |
| FEEDBACK-01 | App speaks "created issue #NUMBER" via native macOS TTS | `AVSpeechSynthesizer` + `AVSpeechUtterance`; stored on `AppState`; no entitlements needed |
| PROVIDER-01 | Provider-agnostic command seam (claude/codex × GitHub/Jira) | `IssueFilingConfig` struct holds command, mcp-server name, tool name, env key; GitHub/claude is the only validated leg in v1 |
| AUTH-01 | App never stores or transmits tokens; relies on CLI's pre-authenticated session | Token sourced from `gh auth token` at invocation time, passed as `GITHUB_PERSONAL_ACCESS_TOKEN` in `Process.environment` |
</phase_requirements>

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Issue drafting & filing | CLI / MCP (external) | — | The user's `claude` process owns this; it runs as a subprocess with cwd = bound repo |
| Subprocess invocation | App (CLIRunner) | — | Swift `Process` via `CLIRunner`; already proven for Transcriber |
| Output parsing (JSONL) | App (IssueFilingRunner) | — | Swift walks the stdout JSONL; MCP config is transient |
| Spoken confirmation | App (AppState / AVFoundation) | — | `AVSpeechSynthesizer` on the main actor; no entitlement |
| Token acquisition | App invocation path | gh CLI | App calls `gh auth token` via `CLIRunner` or reads from env; result passed as subprocess env var |
| MCP config persistence | Temp file (per-invocation) | — | Written to a temp path before `Process.run()`, deleted after; never stored in UserDefaults/keychain |
| Provider seam | App config / UserDefaults | — | `IssueFilingConfig` persisted; user can swap command/server/tool; Jira deferred |

---

## Standard Stack

### Core

No new external packages needed for this phase. All required capabilities come from Apple frameworks already in the project or trivially available.

| Library | Source | Purpose | Notes |
|---------|--------|---------|-------|
| `AVFoundation` (AVSpeechSynthesizer) | Apple SDK | Native macOS TTS | Already imported for AVFoundation audio; no new dependency |
| `Foundation` (Process, URL, FileManager) | Apple SDK | Subprocess, temp file I/O | Already in project |
| `CLIRunner` (project) | Existing source | Subprocess with stdout/stderr + timeout | Phase 3 Wave 1; already has `workingDirectory` param |

### Supporting

| Capability | Approach | Notes |
|------------|----------|-------|
| JSON parsing | `JSONSerialization` or `Codable` structs | Only for the JSONL result parser; no external lib needed |
| MCP config generation | String interpolation or `JSONEncoder` | Produces the `mcp-config.json` tempfile |
| Token acquisition | `CLIRunner.run("gh auth token")` | One-shot before issuing the main call; or read from env var if pre-set |

### Installation

No `npm install` or `swift package add` needed. This phase adds only new Swift source files.

---

## Package Legitimacy Audit

No external packages are being installed in this phase. All implementation uses Apple system frameworks (`AVFoundation`, `Foundation`) and existing project code (`CLIRunner`).

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious:** none

---

## Architecture Patterns

### System Architecture Diagram

```
[User releases PTT]
        |
        v
 AppState.stopRecording()
        |  (existing)
        v
 Phase 3: Transcriber
        |
        v
 AppState.transcript (String)
        |
        v
 IssueFilingRunner.file(transcript:repo:config:)   ← NEW
    |
    |-- generates mcp-config.json → temp path
    |-- builds claude -p command string
    |-- populates env dict (token + inherited)
    |-- calls CLIRunner.run(command:workingDirectory:timeout:)
    |       cwd = bound repo
    |
    v
 [claude subprocess]
    |-- reads repo (Read/Grep/Glob)
    |-- calls mcp__github__issue_write
    |-- GitHub MCP server (Docker stdio)
    v
 stdout: JSONL stream
    |
    v
 IssueResultParser.parse(stdout:)                  ← NEW
    |-- Walk JSONL for tool_result blocks → url field → /issues/N
    |-- Fallback: regex result string
    |-- Check permission_denials (non-empty = failure)
    v
 IssueFilingResult: .filed(number:url:) | .failed(reason:)
    |
    v
 AppState: spoken confirmation
    |-- AVSpeechSynthesizer.speak("created issue #N")
    |-- captureState → .idle
```

### Recommended Project Structure

```
Sources/MakeAnIssue/
├── CLIRunner.swift              # existing — unchanged
├── Transcriber.swift            # existing — unchanged
├── IssueFilingConfig.swift      # NEW: IssueFilingConfig struct (provider seam)
├── IssueFilingRunner.swift      # NEW: orchestrates claude invocation
├── IssueResultParser.swift      # NEW: JSONL parser + prose regex fallback
├── AppState.swift               # EXTENDED: .filing state, onRunIssueFilingSeam, TTS
└── MenuView.swift               # EXTENDED: .filing state label, CLI Command field (PROVIDER-01)
Tests/MakeAnIssueTests/
├── IssueResultParserTests.swift # NEW: unit tests for parser (no subprocess)
├── IssueFilingRunnerTests.swift # NEW: seam-injection tests
└── AppStateTests.swift          # EXTENDED: .filing state machine tests
```

### Pattern 1: IssueFilingConfig — Provider Seam (PROVIDER-01)

**What:** A value type that captures everything that varies per provider (command prefix, MCP server name, tool name, env key, MCP server command). The rest of `IssueFilingRunner` is generic.

**When to use:** Instantiated from UserDefaults on each filing call; default is `IssueFilingConfig.claudeGitHub`.

```swift
// Source: [ASSUMED] — modeled on Transcriber pattern in this codebase
struct IssueFilingConfig: Equatable {
    /// The AI CLI binary to invoke (e.g. "claude").
    let cliCommand: String
    /// MCP server name as it appears in --allowedTools (e.g. "github").
    let mcpServerName: String
    /// MCP tool name (e.g. "issue_write").
    let mcpToolName: String
    /// The environment variable key that carries the bearer token (e.g. "GITHUB_PERSONAL_ACCESS_TOKEN").
    let tokenEnvKey: String
    /// Shell command that prints the raw token to stdout (e.g. "gh auth token").
    let tokenCommand: String
    /// The mcp-server JSON block written to the tempfile.
    let mcpServerJSON: String

    /// Validated v1 leg: claude + GitHub remote MCP via Docker.
    static let claudeGitHub = IssueFilingConfig(
        cliCommand: "claude",
        mcpServerName: "github",
        mcpToolName: "issue_write",
        tokenEnvKey: "GITHUB_PERSONAL_ACCESS_TOKEN",
        tokenCommand: "gh auth token",
        mcpServerJSON: """
        {
          "command": "docker",
          "args": ["run","-i","--rm",
                   "-e","GITHUB_PERSONAL_ACCESS_TOKEN",
                   "-e","GITHUB_TOOLSETS=issues",
                   "ghcr.io/github/github-mcp-server"]
        }
        """
    )
}
```

[ASSUMED] — pattern derived from existing Transcriber/CLIRunner seam style in this project.

### Pattern 2: IssueFilingRunner.file() — Subprocess Orchestration

**What:** Generates a per-invocation MCP config tempfile, assembles the `claude -p` command with all required flags, sets `Process.environment` for token passthrough, runs via `CLIRunner`, then delegates to `IssueResultParser`. Cleans up the tempfile in all code paths.

**Key details (all from spike findings):**
- `--mcp-config <absolute-path>` — absolute path to the tempfile; CLIRunner sets `process.currentDirectoryURL` so relative paths would resolve relative to the repo, not the config. Use `FileManager.default.temporaryDirectory`.
- `--strict-mcp-config` — prevents the user's global `~/.claude/mcp.json` from leaking in additional tools.
- `--allowedTools "mcp__github__issue_write" "Read" "Grep" "Glob"` — least-privilege; Read/Grep/Glob let the model investigate the repo.
- `--output-format stream-json --verbose` — emits JSONL including `tool_use`/`tool_result` events and the `result` envelope.
- `cwd = boundRepo.rootURL` — this is where the value comes from.
- Token in `Process.environment`: set `config.tokenEnvKey` to the token string in the env dict. `CLIRunner` currently passes no explicit environment; it would need to accept an optional `environment` parameter, or the command string can export the variable inline (`export TOKEN=...; claude ...`). The inline approach avoids modifying `CLIRunner`'s signature but exposes the token in a shell string visible in `ps`. **Recommended: add an `environment: [String:String]?` parameter to `CLIRunner.run()`** — it merges with `ProcessInfo.processInfo.environment` (which `/bin/zsh -lc` inherits anyway) to pass the token without it appearing in the command string.

```swift
// Source: [ASSUMED] — modeled on spike 002 run.sh and CLIRunner patterns
struct IssueFilingRunner {
    static func file(
        transcript: String,
        repo: RepoBinding,
        config: IssueFilingConfig,
        ownerRepo: String   // "owner/repo" for the prompt
    ) async throws -> IssueFilingResult {
        // 1. Acquire token via CLIRunner
        let tokenResult = await CLIRunner().run(command: config.tokenCommand)
        guard case .success(let tokenOut, _, _) = tokenResult else {
            throw IssueFilingError.tokenAcquisitionFailed
        }
        let token = tokenOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw IssueFilingError.tokenAcquisitionFailed }

        // 2. Write tempfile mcp-config.json
        let mcpConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
        let mcpJSON = """
        {"mcpServers":{"\(config.mcpServerName)":\(config.mcpServerJSON)}}
        """
        try mcpJSON.write(to: mcpConfigURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: mcpConfigURL) }

        // 3. Build prompt (instructs "use issue_write, method=create, URL on last line")
        let prompt = buildPrompt(transcript: transcript, ownerRepo: ownerRepo, config: config)

        // 4. Build command string
        let allowedTools = "mcp__\(config.mcpServerName)__\(config.mcpToolName) Read Grep Glob"
        let cmd = """
        \(config.cliCommand) -p \(shellescape(prompt)) \
          --mcp-config \(shellescape(mcpConfigURL.path)) --strict-mcp-config \
          --allowedTools \(allowedTools) \
          --output-format stream-json --verbose
        """

        // 5. Run via CLIRunner with env passthrough and 300s timeout
        let env = [config.tokenEnvKey: token]
        let result = await CLIRunner().run(
            command: cmd,
            workingDirectory: repo.rootURL,
            environment: env,
            timeout: .seconds(300)
        )

        // 6. Map CLIResult → IssueFilingResult
        switch result {
        case .timeout:
            throw IssueFilingError.timeout
        case .failed(let exitCode, let stderr):
            throw IssueFilingError.cliFailed(exitCode: exitCode, stderr: stderr)
        case .success(let stdout, _, _):
            return try IssueResultParser.parse(stdout: stdout)
        }
    }
}
```

[ASSUMED] — `CLIRunner.run()` needs an `environment: [String:String]? = nil` parameter added.

### Pattern 3: IssueResultParser.parse() — JSONL Walking + Fallback

**What:** Walks the JSONL stdout produced by `claude -p --output-format stream-json --verbose`. Two passes:
1. Walk `assistant` message content blocks for `tool_result` blocks → extract `url` matching `/issues/(\d+)`.
2. Fall back to regex over the `result` event's `result` string.
3. Check `permission_denials` — if non-empty, the tool was blocked; return `.failed(.permissionDenied)`.

**JSON shapes to handle** [CITED: code.claude.com/docs/en/agent-sdk/streaming-output] [CITED: spike-findings-make-an-issue/references/github-issue-filing.md]:

```
// result event (last line of stream-json output)
{"type":"result","subtype":"success","is_error":false,
 "result":"<final assistant text>","session_id":"...","total_cost_usd":0.01,
 "num_turns":3,"permission_denials":[...]}

// permission_denials entry (when tool was not granted)
{"tool_name":"mcp__github__issue_write","tool_use_id":"toolu_...","tool_input":{...}}

// assistant message carrying tool_result (--verbose emits these)
{"type":"assistant","message":{"role":"assistant","content":[
  {"type":"tool_result","tool_use_id":"toolu_...","content":"{\"id\":\"<node-id>\",\"url\":\"https://github.com/owner/repo/issues/89\"}"}
]}}
```

**Critical parser rule** [CITED: spike-findings-make-an-issue/references/github-issue-filing.md]:
The `issue_write` result JSON has `id` (GitHub internal node id) and `url`. The issue NUMBER lives only in the `url` path — extract it as `/issues/(\d+)`. Never use `id`.

```swift
// Source: [ASSUMED] — Swift port of parse-issue.js from spike 002 sources
struct IssueFilingResult {
    let number: Int
    let url: String
}

enum IssueParseError: Error {
    case permissionDenied([String])   // tool names that were denied
    case noIssueFound                 // tool ran but no url parseable
    case malformedOutput
}

struct IssueResultParser {
    static let githubIssueURLRegex = try! NSRegularExpression(
        pattern: #""url"\s*:\s*"(https?://github\.com/[^"]+/issues/(\d+))""#
    )
    static let proseURLRegex = try! NSRegularExpression(
        pattern: #"https?://github\.com/[^\s)"']+/issues/(\d+)"#
    )
    static let prosePoundRegex = try! NSRegularExpression(
        pattern: #"#(\d+)"#
    )

    static func parse(stdout: String) throws -> IssueFilingResult {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        var fromToolResult: IssueFilingResult? = nil
        var finalResultText: String = ""
        var deniedTools: [String] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Result envelope
            if obj["type"] as? String == "result" {
                finalResultText = obj["result"] as? String ?? ""
                if let denials = obj["permission_denials"] as? [[String: Any]] {
                    deniedTools = denials.compactMap { $0["tool_name"] as? String }
                }
            }

            // Assistant message content blocks
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_result" {
                    let text: String
                    if let s = block["content"] as? String { text = s }
                    else if let arr = block["content"] as? [[String: Any]] {
                        text = arr.compactMap { $0["text"] as? String }.joined()
                    } else { continue }

                    if let result = extractFromToolResultText(text) {
                        fromToolResult = result
                    }
                }
            }
        }

        // Permission denial takes priority: no issue was filed
        if !deniedTools.isEmpty {
            throw IssueParseError.permissionDenied(deniedTools)
        }

        if let r = fromToolResult { return r }

        // Fallback: prose regex
        if let r = extractFromProseText(finalResultText) { return r }

        throw IssueParseError.noIssueFound
    }

    private static func extractFromToolResultText(_ text: String) -> IssueFilingResult? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = githubIssueURLRegex.firstMatch(in: text, range: range),
           let urlRange = Range(m.range(at: 1), in: text),
           let numRange = Range(m.range(at: 2), in: text),
           let number = Int(text[numRange]) {
            return IssueFilingResult(number: number, url: String(text[urlRange]))
        }
        return nil
    }

    private static func extractFromProseText(_ text: String) -> IssueFilingResult? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = proseURLRegex.firstMatch(in: text, range: range),
           let urlRange = Range(m.range(at: 0), in: text),
           let numRange = Range(m.range(at: 1), in: text),
           let number = Int(text[numRange]) {
            return IssueFilingResult(number: number, url: String(text[urlRange]))
        }
        return nil
    }
}
```

[ASSUMED] — Swift port of spike 002 `parse-issue.js` patterns.

### Pattern 4: CLIRunner.run() — Environment Parameter Addition

**What:** `CLIRunner` currently calls `/bin/zsh -lc` and inherits the full process environment. To pass the GitHub token without embedding it in the shell command string (visible in `ps`), add an optional `environment` parameter that merges into the inherited env.

```swift
// Source: [ASSUMED] — minimal change to existing CLIRunner API
func run(
    command: String,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,   // NEW: merged into inherited env
    timeout: Duration = .seconds(120)
) async -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    if let wd = workingDirectory {
        process.currentDirectoryURL = wd
    }
    if let extra = environment {
        // Start from the inherited environment, overlay the caller's keys
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        process.environment = env
    }
    // ... rest unchanged
}
```

[ASSUMED] — `Process.environment` merging pattern for Swift.

### Pattern 5: AppState — .filing State + TTS

**What:** Add `.filing` to `CaptureState`, an `onRunIssueFiling` seam (same injection pattern as `onRunTranscription`), and a stored `AVSpeechSynthesizer` property. The synthesizer MUST be a stored property — if it's a local variable, it gets deallocated before speaking completes.

```swift
// Source: [ASSUMED] — AVSpeechSynthesizer macOS usage
import AVFoundation

// In AppState (stored property — not a local):
private let speechSynthesizer = AVSpeechSynthesizer()

func speak(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    // Optionally set utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    // utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    speechSynthesizer.speak(utterance)
}
```

CaptureState gains `.filing` between `.finished` (transcript available) and return to `.idle` after speaking. State machine flow: `.idle` → `.recording` → `.transcribing` → `.finished` → `.filing` → `.idle`.

[ASSUMED] — AVSpeechSynthesizer must be retained; pattern from Apple docs and community knowledge.

### Pattern 6: Prompt Construction

**What:** The prompt instructs the model precisely how to file the issue and how to format the output. These instructions are what make the parsing reliable.

```swift
// Source: [CITED: spike-findings-make-an-issue/references/github-issue-filing.md]
static func buildPrompt(transcript: String, ownerRepo: String, config: IssueFilingConfig) -> String {
    """
    You are make-an-issue: you turn a developer's spoken thought into a GitHub issue \
    for the repository in the current working directory (\(ownerRepo)).

    Spoken transcript: "\(transcript)"

    Steps:
    1. Briefly investigate the repo (README, relevant source files) to write a specific, accurate issue.
    2. File the issue using the \(config.mcpToolName) tool with method=create.
    3. On the LAST line of your response, output ONLY the new issue URL in this exact format:
       Issue URL: https://github.com/\(ownerRepo)/issues/<NUMBER>

    Do not ask for confirmation; file it directly.
    """
}
```

The "Issue URL on the last line" instruction provides a reliable prose fallback if the structured tool_result parse fails.

[CITED: spike-findings-make-an-issue/references/github-issue-filing.md]

### Anti-Patterns to Avoid

- **Never use `--permission-mode bypassPermissions` or `--dangerously-skip-permissions`.** Grants every tool including Bash shell-write — large attack surface. Scoped `--allowedTools` is sufficient and proven. [CITED: spike 001]
- **Never speak the `id` field** from the GitHub MCP `issue_write` result. `id` is a 10-digit internal node id (e.g. `4747398171`). The human-facing issue number lives only in the `url` path (`/issues/89`). [CITED: spike 002]
- **Never trust exit code 0 alone as proof of filing.** A denied tool returns exit 0 with `permission_denials` populated. Always inspect `permission_denials` on the result event. [CITED: spike 001]
- **Never trust the model's prose.** The model may say "I filed the issue" without actually calling the tool. Verify by checking whether `mcp__github__issue_write` appears in a `tool_use` block in the JSONL stream. [CITED: spike 002]
- **Never embed the token in the command string.** It appears in `ps` output. Pass it via `Process.environment`. [ASSUMED — standard OS security practice]
- **Never use a local variable for `AVSpeechSynthesizer`.** It will be deallocated before speaking completes. Store it as a property on `AppState`. [ASSUMED — known AVFoundation lifetime pitfall]
- **Never write the mcp-config.json to a project directory or UserDefaults.** Write it to `FileManager.default.temporaryDirectory` with a UUID suffix; delete it in a `defer` block. [CITED: spike 002 security guidance]

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GitHub issue filing | Custom GitHub API client | `claude -p` + GitHub MCP via Docker | App holds no token; zero GitHub API surface; already proven in spike 002 |
| Text-to-speech | Custom audio synthesis | `AVSpeechSynthesizer` | Native, zero dependencies, no entitlement, works in background apps |
| JSON parsing | Custom JSONL tokenizer | `JSONSerialization` line-by-line | stdlib; no external dep; JSONL is newline-delimited complete objects |
| Subprocess spawning | Direct `posix_spawn` | `CLIRunner` (existing) | Single-resume guarantee, pipe deadlock prevention, timeout — all already solved |
| Shell escaping | Custom escaping | POSIX single-quote method (existing in `Transcriber.prepare`) | Handles spaces and quotes in paths; already proven in the codebase |

---

## Common Pitfalls

### Pitfall 1: AVSpeechSynthesizer Deallocation
**What goes wrong:** The synthesizer is created as a local `let synthesizer = AVSpeechSynthesizer()` inside a function or `Task` closure. It is released at the end of the closure before speaking completes. The app appears to speak nothing.
**Why it happens:** `speak()` is async/fire-and-forget; the synthesizer must remain alive for the duration.
**How to avoid:** Store `AVSpeechSynthesizer` as a property on `AppState` (or any object with sufficient lifetime).
**Warning signs:** `speechSynthesizer(_:didFinish:)` delegate method is never called; no audio output on first invocation.
[ASSUMED]

### Pitfall 2: Token in Command String (ps visibility)
**What goes wrong:** Token is embedded in the command string via `"export TOKEN=\(token); claude ..."`. It appears in `ps aux` output on the user's machine.
**Why it happens:** `/bin/zsh -lc` command is visible to other processes via the process table.
**How to avoid:** Pass via `Process.environment`, not the command string.
**Warning signs:** `ps aux | grep claude` reveals the token value.
[ASSUMED]

### Pitfall 3: permission_denials Ignored (Silent Non-Filing)
**What goes wrong:** App reads exit code 0 + non-empty `result` text, calls it success, speaks "created issue #?" — but no issue was filed because the tool grant was missing or wrong.
**Why it happens:** `claude -p` exits 0 when a tool is denied; the denial is recorded in `permission_denials`, not the exit code.
**How to avoid:** Check `permission_denials` in the result event before attempting to parse the URL.
**Warning signs:** Exit code 0, no issue appears on GitHub, but `result` text contains "I was unable to call the tool".
[CITED: spike-findings-make-an-issue/references/headless-cli-invocation.md]

### Pitfall 4: Parsing the `id` Field Instead of `url`
**What goes wrong:** Parser extracts the `id` field (`"id":"MDU6SXNzdWU0NzQ3Mzk4MTcx"` or a numeric node id) and speaks it instead of the issue number.
**Why it happens:** The `issue_write` result JSON has both `id` (node id or base64 node id) and `url`. Programmers expect `id` to be the issue number.
**How to avoid:** Always regex for `"url":"https://github.com/.../issues/(\d+)"` and extract the capture group.
**Warning signs:** TTS speaks a very large number (4,747,398,171) or a base64 string.
[CITED: spike-findings-make-an-issue/references/github-issue-filing.md]

### Pitfall 5: Relative Path for --mcp-config
**What goes wrong:** `--mcp-config ./mcp.json` is passed with `process.currentDirectoryURL = repoURL`. The config file is looked up relative to the repo, not where it was written.
**Why it happens:** `process.currentDirectoryURL` affects how the subprocess resolves relative paths.
**How to avoid:** Always use an absolute path for `--mcp-config`. Write to `FileManager.default.temporaryDirectory` (absolute) and pass `mcpConfigURL.path`.
[ASSUMED — from CLIRunner working-directory behavior]

### Pitfall 6: Docker Not Available
**What goes wrong:** The GitHub MCP server requires Docker. The invocation silently fails (MCP server fails to start; `claude` may report no MCP tools available).
**Why it happens:** Docker is an external dependency not bundled with the app.
**How to avoid:** Detect `docker` on PATH during first-run setup; surface a clear error if absent. In v1 it's acceptable to document this as a prerequisite.
**Warning signs:** `permission_denials` contains `mcp__github__issue_write` even though `--allowedTools` includes it (the tool was granted but the server never started).
[ASSUMED]

### Pitfall 7: CLIRunner 120s Timeout Too Short
**What goes wrong:** The AI CLI takes 2–5 minutes for a complex repo investigation + filing. `CLIRunner` returns `.timeout` at 120s. The issue may have been filed but the app can't parse it.
**Why it happens:** Default timeout inherited from the transcription path; the AI-CLI path is much slower (30s proven in spike; complex repos could be longer).
**How to avoid:** Pass `timeout: .seconds(300)` (5 minutes) to `IssueFilingRunner`'s `CLIRunner.run()` call.
[CITED: spike-findings-make-an-issue/references/headless-cli-invocation.md — spike timings ~30s, budget well above]

### Pitfall 8: `--verbose` Required for tool_result Events
**What goes wrong:** Without `--verbose`, the JSONL stream omits the per-turn `assistant` message events that contain `tool_result` blocks. Only the final `result` envelope is emitted. The primary parse path (tool_result) is never triggered; the parser falls back to prose regex.
**Why it happens:** `--output-format stream-json` without `--verbose` emits a compressed output.
**How to avoid:** Always pass both `--output-format stream-json --verbose`.
[CITED: code.claude.com/docs/en/headless — --verbose "shows full turn-by-turn output"]

---

## Provider-Agnostic Seam (PROVIDER-01)

### What Varies Per Provider

| Axis | claude + GitHub | codex + GitHub | claude + Jira (deferred) |
|------|-----------------|----------------|--------------------------|
| CLI command | `claude` | `codex` | `claude` |
| `-p` / print flag | `-p` | `exec` (non-interactive) | `-p` |
| MCP server name | `github` | TBD | TBD |
| Tool name | `issue_write` | TBD | TBD |
| Token env key | `GITHUB_PERSONAL_ACCESS_TOKEN` | `GITHUB_PERSONAL_ACCESS_TOKEN` | TBD |
| Token command | `gh auth token` | `gh auth token` | TBD |
| MCP server JSON | Docker `ghcr.io/github/github-mcp-server` | TBD | TBD |
| `--allowedTools` prefix | `mcp__github__issue_write` | TBD | TBD |

**codex status:** [ASSUMED] Codex non-interactive MCP writes are broken upstream (stdin-EOF auto-cancel per STATE.md blocker). Codex leg must remain configurable but is NOT the default and is NOT validated in v1.

**Jira status:** [ASSUMED] Atlassian/Jira zero-token non-interactive write may require interactive OAuth. Deferred per REQUIREMENTS.md PROVIDER-01 note.

### Recommended v1 UX for PROVIDER-01

Store `IssueFilingConfig` as a few UserDefaults keys (or a single JSON blob). Expose a "CLI Command" field in MenuView (similar to the ASR Command field that existed pre-rework). Default to `claude` + GitHub. Document the full `IssueFilingConfig` struct fields so a user can swap to Jira once that spike validates.

---

## AUTH-01: Token Passthrough

**How it works:**
1. App calls `CLIRunner.run("gh auth token")` — a fast call that reads from `gh`'s keychain credential store.
2. Trims the output → `token` string.
3. Passes it as `[config.tokenEnvKey: token]` in `Process.environment`.
4. Docker inherits it via `-e GITHUB_PERSONAL_ACCESS_TOKEN` (no `=value` in the docker args — Docker reads from the container's environment, which inherits from the subprocess).

**What the app NEVER does:**
- Stores the token in UserDefaults, Keychain, or any file.
- Logs the token (NSLog, print, stderr).
- Passes the token as a CLI argument.

**One-time interactive grant:** `gh auth login` is a prerequisite the user completes once, independently of this app. After that, `gh auth token` works non-interactively. This is the AUTH-01 "one-time interactive OAuth grant persisted in the CLI's own credential store" pattern.

[CITED: spike-findings-make-an-issue/references/github-issue-filing.md — `export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"`]

---

## Error / Exit-Code Mapping (ISSUE-02 / FEEDBACK-01)

| Failure Mode | Detection | IssueFilingError | User-Facing Message | Spoken? |
|---|---|---|---|---|
| `gh` not found / not authed | `CLIRunner` returns `.failed` on token command | `.tokenAcquisitionFailed` | "Sign in to GitHub first: gh auth login" | No (status text only) |
| `docker` not available | MCP server fails to start; `permission_denials` populated | `.permissionDenied(tools:)` | "Docker required: install Docker Desktop" | No |
| Tool not granted (wrong tool name) | `permission_denials` non-empty | `.permissionDenied(tools:)` | "Issue tool not granted — check CLI Command config" | No |
| CLI exited non-zero | `.failed(exitCode:stderr:)` from `CLIRunner` | `.cliFailed(exitCode:stderr:)` | "AI CLI failed (exit N) — see log" | No |
| Timeout | `.timeout` from `CLIRunner` | `.timeout` | "AI CLI timed out — check your internet connection" | No |
| Issue URL not parseable | `IssueParseError.noIssueFound` | wraps parse error | "Issue filed but couldn't parse number — check GitHub" | Yes, "issue filed" (partial) |
| Success | `IssueFilingResult` with number + url | — | none | Yes: "created issue #N" |

**Spoken failure:** For v1, only the success path speaks. All failure modes surface as `statusText` updates (same pattern as `TranscriberError` → `AppState.message(for:)`). This keeps the implementation simple and matches the existing error-surfacing contract.

---

## CaptureState Extension

Add `.filing` after `.finished`:

```swift
// Source: [ASSUMED] — extending existing CaptureState enum
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
    case finished      // transcript captured — begin filing
    case filing        // AI CLI in flight
    // returns to .idle after speak or error
}
```

AppState flow after `transcript` is set:
- `.finished` → immediately enter `.filing` → call `onRunIssueFiling(transcript, boundRepo)`
- On `IssueFilingResult.filed`: speak "created issue #N" → `.idle`
- On error: set `statusText` → `.idle`

Note: `.finished` will now be transient (immediately transitions to `.filing`). If the user needs to re-read the transcript, `AppState.transcript` remains set even after `.idle`.

---

## AppState Seam Pattern for Issue Filing

Follow the exact same injection pattern as `onRunTranscription`:

```swift
// Source: [ASSUMED] — modeled on existing onRunTranscription seam (AppState.swift)
private let onRunIssueFiling: (String, RepoBinding) async throws -> IssueFilingResult

// Default (production wiring):
onRunIssueFiling: { transcript, repo in
    let config = IssueFilingConfig.claudeGitHub   // TODO: load from UserDefaults
    let ownerRepo = ???   // need to discover owner/repo from git remote
    return try await IssueFilingRunner.file(
        transcript: transcript, repo: repo, config: config, ownerRepo: ownerRepo
    )
}
```

**Owner/repo discovery:** The app currently holds `RepoBinding.rootURL`. It needs to extract the GitHub `owner/repo` from the git remote to pass to the prompt and the MCP tool. Options:
1. Shell out: `git -C <repo> remote get-url origin` → parse `github.com/owner/repo` from the URL.
2. Include it in the prompt as `"the repository in the current working directory"` without naming owner/repo explicitly — the model can discover it from `.git/config`.

Option 2 requires no additional parsing and the model handles it. Option 1 is more explicit. **Recommend Option 2 for v1** (simpler; proven in spike 002 prompt which names the owner/repo but the model could infer it).

[ASSUMED] — owner/repo discovery approach is not covered by spikes.

---

## Runtime State Inventory

This is a greenfield addition (new IssueFilingRunner, new parser, new AppState state). No rename/refactor involved. No runtime state to migrate.

N/A — new feature, no existing stored data, no OS-registered tasks, no secrets held by the app currently.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `claude` CLI | ANALYZE-01, ISSUE-01 | ✓ | 2.1.191 | None in v1 — prerequisite |
| `docker` | GitHub MCP server (ghcr.io/github/github-mcp-server) | ✓ | 29.6.0 | None in v1 — prerequisite |
| `gh` CLI | AUTH-01 token acquisition | [ASSUMED] present | unknown | User sets `GITHUB_PERSONAL_ACCESS_TOKEN` env var directly |
| Swift 6 / Xcode | Build | ✓ | 6.3.2 / Xcode 26.5 | — |
| `AVFoundation` | FEEDBACK-01 TTS | ✓ | macOS 13+ | NSSpeechSynthesizer (legacy, not recommended) |
| `AVSpeechSynthesizer` | FEEDBACK-01 | ✓ | macOS 13+ | — |

**Missing dependencies with no fallback:**
- `docker` — required at runtime; must be installed (Docker Desktop). App should detect and surface a clear error if absent.
- `claude` CLI — required; must be installed and authenticated.

**Missing dependencies with fallback:**
- `gh` CLI — if absent, user can set `GITHUB_PERSONAL_ACCESS_TOKEN` in their shell environment and the app can read it from `ProcessInfo.processInfo.environment` as a secondary token source.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (Swift Package) |
| Config file | Package.swift (existing) |
| Quick run command | `swift test --filter IssueResultParserTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ANALYZE-01 | IssueFilingRunner calls CLIRunner with correct cwd | unit (seam injection) | `swift test --filter IssueFilingRunnerTests` | ❌ Wave 0 |
| ANALYZE-02 | Prompt string includes transcript and instructs issue_write | unit | `swift test --filter IssueFilingRunnerTests/testPromptContainsTranscript` | ❌ Wave 0 |
| ISSUE-01 | MCP config JSON is well-formed and uses token env key | unit | `swift test --filter IssueFilingRunnerTests/testMCPConfigJSON` | ❌ Wave 0 |
| ISSUE-02 | Parser extracts number from tool_result url (not id) | unit | `swift test --filter IssueResultParserTests` | ❌ Wave 0 |
| ISSUE-02 | Parser falls back to prose regex when no tool_result | unit | `swift test --filter IssueResultParserTests/testProseFallback` | ❌ Wave 0 |
| ISSUE-02 | permission_denials triggers IssueParseError.permissionDenied | unit | `swift test --filter IssueResultParserTests/testPermissionDeniedDetected` | ❌ Wave 0 |
| FEEDBACK-01 | AppState enters .filing after transcript and calls onRunIssueFiling seam | unit | `swift test --filter AppStateTests/testFilingSeamCalled` | ❌ Wave 0 |
| FEEDBACK-01 | Successful filing speaks "created issue #N" (seam verifiable) | unit | `swift test --filter AppStateTests/testSpeakOnSuccess` | ❌ Wave 0 |
| PROVIDER-01 | IssueFilingConfig.claudeGitHub builds correct --allowedTools string | unit | `swift test --filter IssueFilingConfigTests` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `swift test --filter IssueResultParserTests` (pure unit, < 1s)
- **Per wave merge:** `swift test` (full suite)
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `Tests/MakeAnIssueTests/IssueResultParserTests.swift` — covers ISSUE-02 parse paths
- [ ] `Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift` — covers ANALYZE-01, ISSUE-01 via seam injection (no real claude call)
- [ ] `Tests/MakeAnIssueTests/IssueFilingConfigTests.swift` — covers PROVIDER-01 command assembly
- [ ] AppStateTests.swift extensions — `.filing` state machine transitions

All existing tests remain green; this phase adds new test files only.

---

## Security Domain

`security_enforcement: true`, `security_asvs_level: 1`, `security_block_on: high`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | App holds no credentials; CLI owns auth |
| V3 Session Management | No | Stateless per-invocation |
| V4 Access Control | Yes (partial) | Least-privilege `--allowedTools` grant; no `bypassPermissions` |
| V5 Input Validation | Yes | Transcript shell-escaped before embedding in command string; POSIX single-quote method (reuse from Transcriber) |
| V6 Cryptography | No | App never handles tokens at rest |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Prompt injection via transcript | Tampering | POSIX single-quote escaping of transcript; model investigates repo independently |
| Token leakage in command string | Information Disclosure | Pass token via `Process.environment`, not command arg |
| Over-privileged tool grant | Elevation of Privilege | Scoped `--allowedTools`; never `bypassPermissions` [CITED: spike 001] |
| Docker image pull from malicious registry | Spoofing | Use pinned image `ghcr.io/github/github-mcp-server` from official GitHub registry [CITED: spike 002] |
| MCP config written to persistent location | Information Disclosure | Tempfile with UUID; deleted in `defer`; never logged |
| Runaway subprocess | Denial of Service | 300s hard timeout in CLIRunner; process.terminate() on timeout |

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `gh issue create` with app-held token | `claude -p` + MCP; app holds no token | 2026-06-25 realignment | No credential surface in app; zero GitHub API client code |
| User-configured ASR CLI command | Bundled whisper binary | 2026-06-25 realignment | Zero-config transcription (Phase 3 rework) |
| `--permission-mode bypassPermissions` (spike initial attempt) | Scoped `--allowedTools` | Spike 001 | Least privilege; no Bash/file-write access |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `AVSpeechSynthesizer` requires no entitlements in non-sandboxed macOS apps | Standard Stack / Pattern 5 | May need to add an entitlement key — low risk; easy fix |
| A2 | `AVSpeechSynthesizer` stored as property on AppState survives long enough to complete speaking | Pattern 5 | TTS silently produces no audio; fix: check lifetime |
| A3 | `Process.environment` dict merge with inherited env is the correct way to pass env vars to subprocess | Pattern 2 / CLIRunner extension | Token not passed; subprocess fails; fix: check Process docs |
| A4 | `--verbose` is required to get tool_result events in stream-json output | Pattern 3 / Pitfall 8 | Primary parse path never triggers; prose fallback used; functional but less reliable |
| A5 | The `result` event's `permission_denials` field is present even on `subtype: "success"` when tools were denied | Pattern 3 | Denied invocations may look like successes; risk: issue not filed but app speaks success |
| A6 | Option 2 (no explicit owner/repo in prompt) works for the model to discover the repo | AppState Seam section | Model may file to wrong repo or fail; fix: add git remote parsing |
| A7 | `codex exec` non-interactive MCP writes remain broken (STATE.md blocker at research time) | PROVIDER-01 table | If fixed, codex leg can be validated with a spike and added to config |
| A8 | `gh auth token` is the right command to acquire the GitHub PAT from gh's credential store | AUTH-01 | If `gh` uses OAuth tokens incompatible with the GitHub MCP server, auth fails; but spike 002 validated this exact pattern |

---

## Open Questions

1. **Owner/repo discovery for the prompt**
   - What we know: `RepoBinding.rootURL` gives the local path; the prompt needs `owner/repo` to be specific.
   - What's unclear: Should the app parse `.git/config` or shell out `git remote get-url origin`?
   - Recommendation: v1 uses Option 2 (no explicit owner/repo in prompt; model infers from cwd). Add `git remote get-url origin` parsing in v1.1 if model accuracy is insufficient.

2. **CaptureState .finished → .filing auto-transition**
   - What we know: In the current design `.finished` shows the transcript in MenuView. Immediately transitioning to `.filing` removes the `.finished` state from the user experience.
   - What's unclear: Should `.finished` be visible at all before filing, or should the menu show "Filing issue…" immediately?
   - Recommendation: Remove `.finished` visibility; go straight to `.filing` label "Filing issue…". The transcript remains readable in `AppState.transcript` and the status text can show it.

3. **`gh auth token` vs `GITHUB_PERSONAL_ACCESS_TOKEN` env var**
   - What we know: Spike 002 used `gh auth token` exported to env. Some users may prefer to set the env var directly.
   - What's unclear: What happens if the user has the env var set but not `gh` installed?
   - Recommendation: Check `ProcessInfo.processInfo.environment[config.tokenEnvKey]` first; fall back to `gh auth token` shell call. This makes `gh` optional.

---

## Sources

### Primary (HIGH confidence — spike-validated, run against real services)
- `.claude/skills/spike-findings-make-an-issue/references/headless-cli-invocation.md` — scoped `--allowedTools` invocation pattern, permission_denials behavior, exit 0 on denial
- `.claude/skills/spike-findings-make-an-issue/references/github-issue-filing.md` — `issue_write`, url vs id, Docker MCP config, prose + structured parse
- `.claude/skills/spike-findings-make-an-issue/sources/002-claude-github-file-issue/run.sh` — exact invocation flags, env passthrough pattern
- `.claude/skills/spike-findings-make-an-issue/sources/002-claude-github-file-issue/parse-issue.js` — two-pass parser algorithm (JS reference for Swift port)

### Secondary (MEDIUM confidence — official docs fetched this session)
- [code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless) — `-p`, `--output-format`, `--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `--verbose`, `--bare` flags
- [code.claude.com/docs/en/cli-reference](https://code.claude.com/docs/en/cli-reference) — complete CLI flag table
- [code.claude.com/docs/en/agent-sdk/streaming-output](https://code.claude.com/docs/en/agent-sdk/streaming-output) — stream-json event shapes, tool_use/tool_result structure

### Tertiary (LOW confidence — web search)
- [developer.apple.com/documentation/avfoundation/speech-synthesis](https://developer.apple.com/documentation/avfoundation/speech-synthesis) — AVSpeechSynthesizer vs NSSpeechSynthesizer; no entitlement needed for non-sandboxed
- [takopi.dev/reference/runners/claude/stream-json-cheatsheet](https://takopi.dev/reference/runners/claude/stream-json-cheatsheet/) — permission_denials field structure in result event

---

## Metadata

**Confidence breakdown:**
- CLI invocation pattern: HIGH — spike-validated against real GitHub, real issue filed (#89)
- stream-json parsing: MEDIUM — official docs + spike source code cross-referenced
- AVSpeechSynthesizer: LOW — official Apple docs (webfetch failed to load body; inferred from developer forums + training knowledge)
- Provider seam (IssueFilingConfig): MEDIUM — modeled directly on Transcriber/CLIRunner pattern in this codebase
- CLIRunner environment param: LOW — standard Swift `Process` usage, not verified against Apple docs this session

**Research date:** 2026-06-25
**Valid until:** 2026-07-25 (stable spike findings; claude CLI flags are stable but check --bare recommendation at plan time — it may become default in a future release per docs)
