# Phase 4: Voice → AI CLI Drafts & Files Issue (via MCP) + Spoken Confirmation - Pattern Map

**Mapped:** 2026-06-25
**Files analyzed:** 8 (5 new, 3 extended)
**Analogs found:** 8 / 8

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Sources/MakeAnIssue/IssueFilingConfig.swift` | config/model | transform | `Sources/MakeAnIssue/Transcriber.swift` (error enum + static default) | role-match |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | service | request-response (subprocess) | `Sources/MakeAnIssue/Transcriber.swift` (CLIRunner caller) | exact |
| `Sources/MakeAnIssue/IssueResultParser.swift` | utility | transform (JSONL → struct) | `Sources/MakeAnIssue/Transcriber.swift` (pure static func, throws typed error) | role-match |
| `Sources/MakeAnIssue/CLIRunner.swift` | service | request-response (subprocess) | itself — minimal additive change | exact |
| `Sources/MakeAnIssue/AppState.swift` | state/controller | event-driven | itself (existing seam pattern) | exact |
| `Sources/MakeAnIssue/MenuView.swift` | component | event-driven | itself (existing `@AppStorage` field pattern) | exact |
| `Tests/MakeAnIssueTests/IssueResultParserTests.swift` | test | — | `Tests/MakeAnIssueTests/TranscriberTests.swift` | exact |
| `Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift` | test | — | `Tests/MakeAnIssueTests/AppStateTests.swift` | exact |

---

## Pattern Assignments

### `Sources/MakeAnIssue/IssueFilingConfig.swift` (config, transform)

**Analog:** `Sources/MakeAnIssue/Transcriber.swift` — error enum declaration style; `AppState.swift` — `static let` default pattern.

**Error enum pattern** (`Transcriber.swift` lines 4–15):
```swift
enum TranscriberError: Error, Equatable {
    case emptyCommand
    case missingWavToken
    case asrFailed(exitCode: Int32, stderr: String)
    case asrTimedOut
    case emptyTranscript
}
```
Copy this pattern for `IssueFilingError` and `IssueParseError`: typed enum, `Error` conformance, associated values for context.

**Static default pattern** (`AppState.swift` lines 82–85):
```swift
onRunTranscription: @escaping (URL) async throws -> String = { url in
    let cmd = UserDefaults.standard.string(forKey: AppState.asrCommandKey) ?? ""
    return try await Transcriber.run(command: cmd, wavURL: url)
}
```
`IssueFilingConfig.claudeGitHub` follows the same "named static default, caller can override" convention. Declare it as `static let claudeGitHub = IssueFilingConfig(...)`.

**No imports needed** — `IssueFilingConfig` is a pure Swift value type (`struct`, `Equatable`). No `import` line required beyond the implicit `Swift` module.

---

### `Sources/MakeAnIssue/IssueFilingRunner.swift` (service, request-response)

**Analog:** `Sources/MakeAnIssue/Transcriber.swift` — exact shape: static methods, calls `CLIRunner().run(...)`, switches on `CLIResult`, throws typed error.

**Imports pattern** (`Transcriber.swift` line 1):
```swift
import Foundation
```
`IssueFilingRunner` uses `Foundation` for `FileManager`, `URL`, `UUID`, `Data`, `JSONSerialization`. No other imports needed.

**CLIRunner call + result switch pattern** (`Transcriber.swift` lines 61–78):
```swift
let result = await CLIRunner().run(command: substituted)

switch result {
case .timeout:
    throw TranscriberError.asrTimedOut

case .failed(let exitCode, let stderr):
    throw TranscriberError.asrFailed(exitCode: exitCode, stderr: stderr)

case .success(let stdout, _, _):
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw TranscriberError.emptyTranscript
    }
    return trimmed
}
```
`IssueFilingRunner.file()` uses this exact switch structure. Replace the `TranscriberError` cases with `IssueFilingError` equivalents. Pass the extended `environment:` param and `timeout: .seconds(300)`.

**POSIX single-quote escaping** (`Transcriber.swift` lines 43–45):
```swift
let escapedPath = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")
let quoted = "'\(escapedPath)'"
```
Reuse this pattern verbatim in `IssueFilingRunner` to shell-escape the transcript before embedding it in the `claude -p` command string. Apply to the transcript string, not the MCP config path (which is passed as a separate flag argument — POSIX-quote it too).

**Tempfile pattern** — no direct codebase analog, but `CLIRunnerTests.swift` lines 89–101 show the canonical temp-dir + cleanup idiom:
```swift
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }
```
Use `FileManager.default.temporaryDirectory.appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")` for the MCP config file. Use `defer { try? FileManager.default.removeItem(at: mcpConfigURL) }`.

---

### `Sources/MakeAnIssue/IssueResultParser.swift` (utility, transform)

**Analog:** `Sources/MakeAnIssue/Transcriber.swift` — pure static function that throws a typed error; no I/O beyond what's passed in. This is the "fully unit-testable without spawning a process" pattern.

**Pure static func pattern** (`Transcriber.swift` lines 34–46):
```swift
static func prepare(command: String, wavURL: URL) throws -> String {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TranscriberError.emptyCommand
    }
    // ...
    return command.replacingOccurrences(of: "{wav}", with: quoted)
}
```
`IssueResultParser.parse(stdout:)` follows this shape: `static func parse(stdout: String) throws -> IssueFilingResult`. No stored state. Fully synchronous. No `Process` or I/O.

**Imports pattern:**
```swift
import Foundation
```
`NSRegularExpression` and `JSONSerialization` are both in `Foundation`. No other imports.

**Static regex declaration** — declare as `static let` properties on the struct (initialized once, not per-call). If using `try!` for a hard-coded pattern that is always valid, that matches the project's tolerance for force-try on compile-time-constant patterns (no existing example in codebase, but this is the Swift convention for regex literals with known-good patterns).

---

### `Sources/MakeAnIssue/CLIRunner.swift` — `environment` parameter addition (service, request-response)

**Analog:** itself. This is a minimal additive change — one new optional parameter on `run()`.

**Existing `run()` signature** (`CLIRunner.swift` lines 69–73):
```swift
func run(
    command: String,
    workingDirectory: URL? = nil,
    timeout: Duration = .seconds(120)
) async -> CLIResult {
```
Add `environment: [String: String]? = nil` between `workingDirectory` and `timeout`. All existing call sites pass no `environment:` label and are unaffected (default is `nil`).

**Process setup pattern** (`CLIRunner.swift` lines 75–81):
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/zsh")
process.arguments = ["-lc", command]
if let wd = workingDirectory {
    process.currentDirectoryURL = wd
}
```
Add the environment merge immediately after the `currentDirectoryURL` block, before the pipe setup:
```swift
if let extra = environment {
    var env = ProcessInfo.processInfo.environment
    for (k, v) in extra { env[k] = v }
    process.environment = env
}
```
Everything after this point in `CLIRunner.run()` is **unchanged**.

---

### `Sources/MakeAnIssue/AppState.swift` — `.filing` state + TTS (state/controller, event-driven)

**Analog:** itself. Extends the existing `CaptureState` enum and `AppState` designated init seam pattern.

**CaptureState enum** (`AppState.swift` lines 6–12):
```swift
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
    case finished
}
```
Add `case filing` after `case finished`. No associated values needed.

**Seam injection pattern** (`AppState.swift` lines 41–43 and 82–85):
```swift
/// Seam for transcription — the default wires the real Transcriber; tests inject a stub.
private let onRunTranscription: (URL) async throws -> String
```
```swift
onRunTranscription: @escaping (URL) async throws -> String = { url in
    let cmd = UserDefaults.standard.string(forKey: AppState.asrCommandKey) ?? ""
    return try await Transcriber.run(command: cmd, wavURL: url)
}
```
Add `private let onRunIssueFiling: (String, RepoBinding) async throws -> IssueFilingResult` as a stored property using the same comment style. Add the matching parameter to the designated `init` with the same `= { transcript, repo in ... }` default wiring.

**beginTranscription() → beginFiling() trigger pattern** (`AppState.swift` lines 173–207):
The transcription Task pattern is the template for the filing Task:
```swift
Task {
    do {
        let text = try await onRunTranscription(wavURL)
        await MainActor.run {
            self.transcript = text
            self.captureState = .finished
        }
    } catch let error as TranscriberError {
        let message = Self.message(for: error)
        await MainActor.run {
            self.transcriptError = message
            self.statusText = message
            self.captureState = .idle
        }
    } catch { ... }
}
```
`beginFiling()` follows this exact structure: enter `.filing` synchronously, spawn a `Task`, call `await onRunIssueFiling(transcript, repo)`, on success call `speak("created issue #\(result.number)")` then set `captureState = .idle`, on error set `statusText` and `captureState = .idle`.

**AVSpeechSynthesizer stored property** (`AppState.swift` lines 37–41 — property declaration block):
```swift
private let audioRecorder: AudioRecorder
private let onStartRecording: () -> Bool
private let onStopRecording: () -> Void
private let onRunTranscription: (URL) async throws -> String
```
Add alongside these:
```swift
private let speechSynthesizer = AVSpeechSynthesizer()
```
`AVFoundation` is already imported at line 1 of `AppState.swift`. No new import needed.

**`message(for:)` pattern** (`AppState.swift` lines 210–224):
```swift
private static func message(for error: TranscriberError) -> String {
    switch error {
    case .emptyCommand:
        return "Set your ASR command in the menu to transcribe"
    // ...
    }
}
```
Add `private static func message(for error: IssueFilingError) -> String` with the same switch structure, mapping each `IssueFilingError` case to a short user-facing string.

---

### `Sources/MakeAnIssue/MenuView.swift` — `.filing` label + CLI Command field (component, event-driven)

**Analog:** itself. Two additive changes to `captureStateLabel` and the field list.

**captureStateLabel pattern** (`MenuView.swift` lines 71–78):
```swift
private var captureStateLabel: String {
    switch appState.captureState {
    case .idle:          return "Idle"
    case .recording:     return "Recording…"
    case .transcribing:  return "Transcribing…"
    case .finished:      return "Done"
    }
}
```
Add `case .filing: return "Filing issue…"` to exhaust the new enum case.

**`@AppStorage` field pattern** (`MenuView.swift` lines 10 and 53–55):
```swift
@AppStorage(AppState.asrCommandKey) private var asrCommand: String = ""
```
```swift
LabeledContent("ASR Command") {
    TextField("e.g. whisper {wav} --model base", text: $asrCommand)
}
```
Add a parallel `@AppStorage` var for the CLI command key (e.g. `AppState.cliCommandKey`), and a matching `LabeledContent("CLI Command") { TextField("e.g. claude", text: $cliCommand) }` field below the ASR Command field. Define `AppState.cliCommandKey = "cliCommand"` as a `static let` alongside `asrCommandKey`.

---

### `Tests/MakeAnIssueTests/IssueResultParserTests.swift` (test, pure unit)

**Analog:** `Tests/MakeAnIssueTests/TranscriberTests.swift` — pure unit tests for a static function that throws typed errors; no process spawn; fixed input strings as test fixtures.

**File header + import pattern** (`TranscriberTests.swift` lines 1–6):
```swift
import XCTest
@testable import MakeAnIssue

/// Tests for `Transcriber.prepare()` — pure function, no process spawn.
/// Covers command validation (D-03, D-05) and POSIX single-quote path substitution (T-03-05).
final class TranscriberTests: XCTestCase {
```
Use identical structure:
```swift
import XCTest
@testable import MakeAnIssue

/// Tests for `IssueResultParser.parse()` — pure function, no process spawn.
/// Covers JSONL tool_result extraction, prose regex fallback, and permission_denials detection.
final class IssueResultParserTests: XCTestCase {
```

**XCTAssertThrowsError pattern** (`TranscriberTests.swift` lines 11–14):
```swift
XCTAssertThrowsError(try Transcriber.prepare(command: "", wavURL: wavURL)) { error in
    XCTAssertEqual(error as? TranscriberError, .emptyCommand)
}
```
Use the same pattern to assert `IssueParseError.permissionDenied` and `.noIssueFound` from `IssueResultParser.parse(stdout:)`.

**MARK sections** (`TranscriberTests.swift` lines 8, 19, 27, 42):
```swift
// MARK: - emptyCommand
// MARK: - missingWavToken
// MARK: - {wav} substitution
```
Use MARK sections per parse path: `// MARK: - tool_result extraction`, `// MARK: - prose regex fallback`, `// MARK: - permission_denials`.

**Test fixture pattern** — inline multiline JSONL strings as `let stdout = """..."""` local constants. No file I/O, no temp files.

---

### `Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift` (test, seam injection)

**Analog:** `Tests/MakeAnIssueTests/AppStateTests.swift` — seam injection tests using `@MainActor`, closure capture of call arguments, `Task.sleep` for async settling.

**File header + MainActor annotation** (`AppStateTests.swift` lines 4–6):
```swift
@MainActor
final class AppStateTests: XCTestCase {
```
`IssueFilingRunnerTests` tests `AppState.beginFiling()` state transitions, so it also needs `@MainActor`.

**Seam injection closure pattern** (`AppStateTests.swift` lines 115–129):
```swift
let state = AppState(
    onStartRecording: { true },
    onStopRecording: {},
    onRunTranscription: { _ in "Hello world" }
)
state.micPermissionGranted = true
state.startRecording()
state.stopRecording()

try? await Task.sleep(for: .milliseconds(100))
XCTAssertEqual(state.captureState, .finished)
```
Mirror with `onRunIssueFiling` stub:
```swift
let state = AppState(
    onStartRecording: { true },
    onStopRecording: {},
    onRunTranscription: { _ in "transcript" },
    onRunIssueFiling: { _, _ in IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42") }
)
```

**Call-argument capture pattern** (`AppStateTests.swift` lines 275–297):
```swift
var receivedURL: URL?
let state = AppState(
    onStartRecording: { true },
    onStopRecording: {},
    onRunTranscription: { url in
        receivedURL = url
        return "transcript text"
    }
)
```
Use the same `var receivedTranscript: String?` / `var receivedRepo: RepoBinding?` captures to verify the filing seam is called with the correct arguments.

**setUp/tearDown tempdir** (`AppStateTests.swift` lines 7–14):
```swift
private var temporaryDirectory: URL!

override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
}

override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryDirectory)
}
```
Copy verbatim — used to create a fake git repo for `RepoBinding` construction in filing tests.

**makeRepo helper** (`AppStateTests.swift` lines 372–377):
```swift
private func makeRepo(named name: String) throws -> URL {
    let repo = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    return repo
}
```
Copy verbatim — needed to construct a valid `RepoBinding` to pass to `onRunIssueFiling`.

---

## Shared Patterns

### Typed error enum
**Source:** `Sources/MakeAnIssue/Transcriber.swift` lines 4–15
**Apply to:** `IssueFilingConfig.swift` (IssueFilingError + IssueParseError)
```swift
enum TranscriberError: Error, Equatable {
    case emptyCommand
    case missingWavToken
    case asrFailed(exitCode: Int32, stderr: String)
    case asrTimedOut
    case emptyTranscript
}
```

### POSIX single-quote shell escaping
**Source:** `Sources/MakeAnIssue/Transcriber.swift` lines 43–45
**Apply to:** `IssueFilingRunner.swift` — escape transcript before embedding in `claude -p` command string; escape MCP config path before passing as `--mcp-config` flag argument
```swift
let escapedPath = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")
let quoted = "'\(escapedPath)'"
```

### Task-based async state transition with MainActor.run hop
**Source:** `Sources/MakeAnIssue/AppState.swift` lines 183–207
**Apply to:** `AppState.swift` `beginFiling()` method
```swift
Task {
    do {
        let text = try await onRunTranscription(wavURL)
        await MainActor.run {
            self.transcript = text
            self.captureState = .finished
        }
    } catch let error as TranscriberError {
        let message = Self.message(for: error)
        await MainActor.run {
            self.transcriptError = message
            self.statusText = message
            self.captureState = .idle
        }
    } catch {
        let message = "Transcription failed — \(error.localizedDescription)"
        await MainActor.run {
            self.captureState = .idle
            self.statusText = message
        }
    }
}
```

### CLIResult switch
**Source:** `Sources/MakeAnIssue/Transcriber.swift` lines 63–78
**Apply to:** `IssueFilingRunner.swift` — same three cases (`.timeout`, `.failed`, `.success`)

### Temp directory + defer cleanup
**Source:** `Tests/MakeAnIssueTests/CLIRunnerTests.swift` lines 89–92
**Apply to:** `IssueFilingRunner.swift` MCP config tempfile write
```swift
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: tempDir) }
```

### @AppStorage + LabeledContent + TextField field
**Source:** `Sources/MakeAnIssue/MenuView.swift` lines 10, 53–55
**Apply to:** `MenuView.swift` new CLI Command field
```swift
@AppStorage(AppState.asrCommandKey) private var asrCommand: String = ""
// ...
LabeledContent("ASR Command") {
    TextField("e.g. whisper {wav} --model base", text: $asrCommand)
}
```

---

## No Analog Found

All files have close analogs in this codebase. No files require falling back to RESEARCH.md patterns alone.

| File | Note |
|------|------|
| `IssueResultParser.swift` (NSRegularExpression + JSONSerialization) | No existing JSONL parser in codebase; use RESEARCH.md Pattern 3 for the parse algorithm. The file structure and error-throwing conventions are fully covered by the `Transcriber.swift` analog. |

---

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/`, `Tests/MakeAnIssueTests/`
**Files scanned:** 10 source + 6 test = 16
**Pattern extraction date:** 2026-06-25
