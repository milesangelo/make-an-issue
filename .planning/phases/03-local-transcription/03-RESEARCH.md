# Phase 3: Local Transcription - Research

**Researched:** 2026-06-24
**Domain:** macOS Foundation Process, Swift Concurrency, UserDefaults/AppStorage, SwiftUI TextField
**Confidence:** MEDIUM (architecture HIGH from code inspection; Process concurrency patterns LOW from web, no authoritative Apple sample)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** ASR command configured via text field in MenuView, persisted with UserDefaults — mirrors KeyboardShortcuts.Recorder field.
- **D-02:** Command executed through login shell: `/bin/zsh -lc "<command>"`.
- **D-03:** No default command. Empty field → "set your ASR command" message; nothing is spawned.
- **D-04:** User writes `{wav}` placeholder in their command; app substitutes the quoted absolute path to `latest.wav` before running.
- **D-05:** Non-empty command with no `{wav}` token → clear error; do not run (no silent append fallback).
- **D-06:** stdout is the transcript.
- **D-07:** Post-process with trim of leading/trailing whitespace only — verbatim otherwise.
- **D-08:** stderr captured separately for diagnostics; never merged into transcript.
- **D-09:** On success, show transcript in MenuView (selectable text block) AND NSLog it.
- **D-10:** Add `.transcribing` state to CaptureState; ASR runs async off main actor.
- **D-11:** On failure show clear short reason + tail of stderr; reset state so new push-to-talk works.
- **D-12:** CLIRunner enforces 120s timeout; on timeout terminate the process, show "ASR timed out after 120s", reset state.

### Claude's Discretion

- Internal API shape of CLIRunner (return type, async mechanism).
- Exact placeholder-substitution/quoting implementation.
- Working directory for the ASR run (cwd is not significant for Phase 3; design so Phase 4 can pass a repo directory).
- Exact wording of user-facing status/error strings.

### Deferred Ideas (OUT OF SCOPE)

- None — discussion stayed within phase scope. A user-configurable timeout was considered for D-12 and deliberately declined.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TRANSCRIBE-01 | App invokes the user-configured local ASR CLI on the recorded WAV | CLIRunner + Transcriber design; {wav} substitution; /bin/zsh -lc pattern |
| TRANSCRIBE-02 | ASR CLI output is captured as transcript text for the request | stdout pipe capture; trim; AppState integration; MenuView display |
</phase_requirements>

---

## Summary

Phase 3 adds two new components: `CLIRunner` (a Foundation `Process` wrapper that runs `/bin/zsh -lc "<command>"`, captures stdout + stderr, enforces a 120s timeout, and is designed for reuse by Phases 4 and 5), and `Transcriber` (which validates the command, substitutes the `{wav}` path, calls `CLIRunner`, and trims the transcript). Both components plug into the existing `AppState` closure-seam and add a `.transcribing` state to the existing `CaptureState` enum.

The phase's technical complexity is concentrated in two areas: (1) safe concurrent pipe-draining — reading both stdout and stderr from a running `Process` without deadlocking when either exceeds the OS pipe buffer (typically 64 KB on macOS); and (2) a timeout/termination race — a 120s Swift Task fires `process.terminate()` and both the timeout Task and the `terminationHandler` could attempt to resume the same `withCheckedContinuation`, which must only be resumed once. Both have well-understood patterns that mirror what Phase 2 already established.

No new Swift Package dependencies are introduced. Foundation `Process`, `Pipe`, and `FileHandle` cover all runtime needs. `@AppStorage` (SwiftUI) or `UserDefaults.standard` (AppState) handle persistence.

**Primary recommendation:** Model `CLIRunner` on the existing `scheduleRecordingTimeout` / `recordingDidTimeout` Task pattern. Use `readabilityHandler` on separate `Pipe` instances for stdout and stderr (concurrent drain, no deadlock). Prevent double-resume with a local `nonisolated(unsafe) var resumed = false` flag guarded inside `terminationHandler`. Surface the transcript via the existing `AppState` closure-seam injected at init.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| ASR command storage | App state (UserDefaults) | MenuView (binding) | Persisted setting owned by app; UI reads/writes via AppStorage |
| {wav} path substitution + validation | Transcriber (business logic) | — | Pure string transformation; no I/O; unit-testable in isolation |
| Process execution + pipe management | CLIRunner (Foundation) | Background thread (GCD/Dispatch) | Foundation Process runs on background thread; stdout/stderr handlers fire on Dispatch queues |
| Timeout enforcement | CLIRunner Task | AppState (cancel) | Mirrors scheduleRecordingTimeout; Task is cancelled by AppState on new recording start |
| .transcribing state + result dispatch | AppState (@MainActor) | — | All @Published mutations happen on MainActor; background results hop via Task { @MainActor } |
| Transcript display | MenuView (SwiftUI) | — | Observes @Published appState.transcript; pattern mirrors LabeledContent repo-path block |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation Process | macOS 13+ built-in | Spawn subprocess, capture stdout/stderr | Apple's only non-sandboxed subprocess API; no dependency required |
| Foundation Pipe / FileHandle | macOS 13+ built-in | Pipe stdout/stderr to Swift | Pairs with Process; readabilityHandler pattern is canonical |
| Swift Concurrency (async/await, Task) | Swift 6.3.2 (in use) | Wrap blocking Process as async call; timeout | Already used in AppState for recording timeout |
| SwiftUI @AppStorage | macOS 13+ built-in | Persist ASR command text across launches | Zero-boilerplate UserDefaults binding; first persisted setting in app (D-01) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| UserDefaults.standard | macOS 13+ built-in | Read ASR command in AppState (non-View context) | When you need the value outside a SwiftUI view |
| XCTest | Swift 6.3.2 (in use) | Extend existing AppStateTests with transcription cases | Existing framework; 38 tests passing |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Foundation Process | Swift Subprocess (SE-0007 proposal) | Subprocess is a proposal/not yet in stdlib; Process is the only shipping macOS API |
| @AppStorage in MenuView | UserDefaults.standard in AppState | Both work; AppStorage in the View is simpler for binding to TextField; AppState reads via UserDefaults.standard |
| readabilityHandler | readDataToEndOfFile() | readDataToEndOfFile() BLOCKS indefinitely while pipe is open — deadlock guaranteed |

**Installation:** No new packages. Phase 3 uses only built-in Foundation + Swift Concurrency.

**Version verification:** Package.swift already at swift-tools-version 5.10; Swift 6.3.2 available (`swift --version`). [VERIFIED: local environment]

---

## Package Legitimacy Audit

> No external packages are installed in this phase. Package.swift requires no additions — Foundation `Process`, `Pipe`, `FileHandle`, and Swift Concurrency are all built into the platform. [VERIFIED: local environment — Package.swift inspection]

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| (none) | — | — | — | — | — | No packages added |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

---

## Architecture Patterns

### System Architecture Diagram

```
[KeyboardShortcut key-up]
        |
        v
[AppState.stopRecording()] ──► [captureState = .finished]
        |
        v  (immediately after stop)
[AppState.startTranscription()]
        |──► captureState = .transcribing (MainActor)
        |
        v
[Transcriber.transcribe(wavURL:command:)]  ← pure; unit-testable
   |── validate command not empty
   |── validate {wav} token present
   |── substitute {wav} → single-quoted absolute path
        |
        v
[CLIRunner.run(command:workingDirectory:timeout:)]  ← async; off MainActor
   |── create Pipe(stdout), Pipe(stderr)
   |── attach readabilityHandler to each (concurrent drain)
   |── process.launch()
   |── withCheckedContinuation {
   |       terminationHandler: resume once (guarded flag)
   |       timeout Task: process.terminate() → resume with .timeout
   |   }
   |── return CLIResult(stdout, stderr, exitCode)
        |
        v
[Transcriber: trim stdout → transcript text]
        |
        v  (Task { @MainActor })
[AppState: captureState = .idle OR .finished]
[AppState: transcript = trimmed text  OR  statusText = error]
        |
        v
[MenuView: LabeledContent / selectable Text for transcript]
[NSLog: transcript for background-app verification]
```

### Recommended Project Structure
```
Sources/MakeAnIssue/
├── CLIRunner.swift          # Process wrapper; reused by Phases 4 & 5
├── Transcriber.swift        # {wav} substitution + CLIRunner call; pure logic
├── AppState.swift           # extend: .transcribing state, transcript property, startTranscription()
├── MenuView.swift           # extend: ASR command TextField, transcript display
└── AudioRecorder.swift      # unchanged (provides latestWavURL)

Tests/MakeAnIssueTests/
├── CLIRunnerTests.swift     # timeout, exit code, stdout capture — real /bin/echo; no ASR
├── TranscriberTests.swift   # substitution, validation, trim — pure; no process
└── AppStateTests.swift      # extend: .transcribing state, transcript, error paths — closure seam
```

### Pattern 1: Safe Concurrent Pipe Drain (readabilityHandler)

**What:** Attach separate `readabilityHandler` closures to stdout and stderr `Pipe` instances. Foundation runs each handler on a background Dispatch queue, draining data as it arrives. Empty `availableData` signals the pipe was closed (EOF).

**When to use:** Any time a Process could produce more than ~64 KB on stdout or stderr (ASR transcripts of long recordings; model output; gh output). Using `readDataToEndOfFile()` instead DEADLOCKS if the pipe buffer fills before the process exits.

```swift
// Source: Apple Developer Forums thread/669842 — DTS engineer guidance [CITED]
let stdoutPipe = Pipe()
let stderrPipe = Pipe()

var stdoutData = Data()
var stderrData = Data()

// Both handlers run concurrently on background threads — no deadlock.
stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    if !chunk.isEmpty { stdoutData.append(chunk) }
}
stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    if !chunk.isEmpty { stderrData.append(chunk) }
}

process.standardOutput = stdoutPipe
process.standardError = stderrPipe
try process.run()
```

**Important:** Set handlers BEFORE calling `process.run()`. Detach handlers (set to nil) after process exits to avoid handler firing with stale state.

### Pattern 2: Async Process Wrapper with timeout (withCheckedContinuation)

**What:** Wrap blocking Process termination as an async call. The `terminationHandler` resumes a `CheckedContinuation` exactly once. A parallel Task enforces the 120s timeout. A `resumed` flag (using `nonisolated(unsafe)` or actor) prevents double-resume.

**When to use:** Every time CLIRunner runs a process — enables `await`-based callers and integrates with Swift Concurrency task cancellation.

```swift
// [ASSUMED] — pattern derived from Swift Forums guidance and Apple DTS recommendations;
// exact API surface confirmed against Swift 6.3.2 stdlib.
enum CLIResult {
    case success(stdout: String, stderr: String, exitCode: Int32)
    case timeout
    case failed(exitCode: Int32, stderr: String)
}

func run(command: String, workingDirectory: URL? = nil, timeout: Duration = .seconds(120)) async -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    if let wd = workingDirectory {
        process.currentDirectoryURL = wd
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    var stdoutData = Data()
    var stderrData = Data()
    // readabilityHandler runs on Foundation's background dispatch queue
    stdoutPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData; if !d.isEmpty { stdoutData.append(d) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData; if !d.isEmpty { stderrData.append(d) }
    }

    // Prevent double-resume: terminationHandler and timeout Task both call resume().
    // nonisolated(unsafe) is safe here because only one path wins (flag is checked
    // and set inside terminationHandler which Foundation calls exactly once).
    // The timeout Task checks the flag before resuming.
    nonisolated(unsafe) var resumed = false

    return await withCheckedContinuation { continuation in
        process.terminationHandler = { p in
            // Detach handlers first so no more data arrives after exit.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            guard !resumed else { return }
            resumed = true
            let out = String(data: stdoutData, encoding: .utf8) ?? ""
            let err = String(data: stderrData, encoding: .utf8) ?? ""
            if p.terminationStatus == 0 {
                continuation.resume(returning: .success(stdout: out, stderr: err, exitCode: 0))
            } else {
                continuation.resume(returning: .failed(exitCode: p.terminationStatus, stderr: err))
            }
        }

        do {
            try process.run()
        } catch {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: .failed(exitCode: -1, stderr: error.localizedDescription))
            return
        }

        // 120s timeout Task — mirrors AppState.scheduleRecordingTimeout
        Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, !resumed else { return }
            resumed = true
            process.terminate()
            // Drain remaining data after terminate() before returning.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(returning: .timeout)
        }
    }
}
```

### Pattern 3: {wav} Substitution with POSIX Single-Quote Escaping

**What:** Replace the literal `{wav}` token in the user's command string with the absolute path to `latest.wav`, enclosed in POSIX single-quotes to survive spaces in the path (e.g. "Application Support").

**When to use:** Every call to CLIRunner from Transcriber.

```swift
// [ASSUMED] — POSIX shell quoting; confirmed correct for paths with spaces.
func quotePath(_ url: URL) -> String {
    // POSIX single-quote escaping: end quote, insert literal ', reopen quote.
    let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

func substitute(command: String, wavURL: URL) -> String? {
    guard command.contains("{wav}") else { return nil }  // D-05: missing token → nil = error
    return command.replacingOccurrences(of: "{wav}", with: quotePath(wavURL))
}
```

The resulting command string (e.g. `whisper '/Users/me/Library/Application Support/MakeAnIssue/latest.wav' --model base`) is passed as the single `-lc` argument to `/bin/zsh`, which tokenises it correctly.

### Pattern 4: AppState Closure-Seam Extension for Transcription

**What:** Extend the existing designated init to accept an `onRunTranscription` closure. The app wires the real `CLIRunner`+`Transcriber`; tests inject a stub without spawning a process.

**When to use:** Matches the existing `onStartRecording`/`onStopRecording` seam pattern; makes the transcription state machine unit-testable.

```swift
// [ASSUMED] — follows exact seam pattern from existing AppState.init
// onRunTranscription: (wavURL) async throws -> String
// throws → used for error classification (timeout vs non-zero exit vs empty)

// In designated init:
init(
    ...,
    onRunTranscription: @escaping (URL) async throws -> String = { url in
        // Default: real Transcriber call
        let cmd = UserDefaults.standard.string(forKey: "asrCommand") ?? ""
        return try await Transcriber.run(command: cmd, wavURL: url)
    }
) { ... }

// In tests:
let state = AppState(
    onStartRecording: { true },
    onStopRecording: {},
    onRunTranscription: { _ in return "Hello world" }   // stub
)
```

### Pattern 5: CaptureState Extension

**What:** Add `.transcribing` to the existing `CaptureState` enum and a `.transcript(String)` associated value or a separate `@Published var transcript: String?` on AppState.

**When to use:** D-10 requires a visible "Transcribing…" state. Keeping transcript as a separate `@Published` property (not embedded in CaptureState) lets the menu show the last successful transcript independently of the current capture state.

```swift
// Extend existing enum — [ASSUMED] design, matches project style
enum CaptureState: Equatable {
    case idle
    case recording
    case finished
    case transcribing   // NEW: ASR in progress
}

// AppState additions:
@Published var transcript: String?      // last successful transcript
@Published var transcriptError: String? // last failure reason (clears on next start)
```

### Anti-Patterns to Avoid

- **`readDataToEndOfFile()` on a live pipe:** Blocks the calling thread until the pipe is closed. If the other pipe (stdout or stderr) fills up and is not being read, the process blocks on write → mutual deadlock. Use `readabilityHandler` + `availableData`.
- **`waitUntilExit()` on the main thread:** Blocks the main runloop; UI freezes. Always call from a Task or background queue.
- **Resuming a continuation more than once:** Crashes at runtime with "SWIFT TASK CONTINUATION MISUSE". Guard with a `resumed` flag; check before every `continuation.resume(...)` call.
- **Merging stderr into stdout:** D-08 prohibits this. Keep pipes separate; stderr is diagnostics-only.
- **Appending path rather than substituting token:** D-05 prohibits silent append; if `{wav}` is absent, return an error immediately.
- **Not using login shell (`-l`):** Without `-l`, `/bin/zsh -c` gets a stripped PATH. Homebrew tools (`whisper`, `mlx_whisper`, etc.) installed in `/usr/local/bin` or `/opt/homebrew/bin` will not be found. Always use `-lc` (D-02).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Subprocess execution | Custom posix_spawn wrapper | Foundation `Process` | Foundation handles file descriptor setup, environment inheritance, termination callbacks |
| Pipe buffer drain | Manual read loops with `read()` syscall | `Pipe` + `FileHandle.readabilityHandler` | Foundation manages the Dispatch source; avoids manual fd bookkeeping |
| Shell PATH resolution | Custom PATH lookup | `/bin/zsh -lc` (login shell, D-02) | zsh's login sequence reads `/etc/paths`, `~/.zshrc`, etc.; exact same env as user's terminal |
| UserDefaults persistence | Custom property list file | `@AppStorage` / `UserDefaults.standard` | Built-in; zero boilerplate; survives app restart automatically |
| Shell quoting | Regex or manual escape | POSIX single-quote pattern (`'` → `'\''`) | Correct for all macOS paths including those with spaces, parens, brackets |

**Key insight:** The only novel engineering in this phase is the double-resume guard for the timeout+termination race. Everything else reuses existing Foundation APIs and the AppState seam pattern already established in Phases 1 and 2.

---

## Common Pitfalls

### Pitfall 1: Pipe buffer deadlock when reading stdout and stderr sequentially
**What goes wrong:** If you call `stdoutPipe.fileHandleForReading.readDataToEndOfFile()` first, then do the same for stderr, and the process writes > ~64 KB to the unread pipe, the process blocks on `write()` and never finishes. Neither `readDataToEndOfFile()` call returns. App hangs.

**Why it happens:** macOS pipe buffer limit is approximately 64 KB. A full buffer blocks the writer. Sequential reading means one pipe sits full while you read the other.

**How to avoid:** Always use `readabilityHandler` on both pipes simultaneously. Foundation drains each pipe from its own background Dispatch source.

**Warning signs:** App hangs after starting transcription; no timeout fires because `waitUntilExit()` never returns (or the continuation never resumes). Only triggered by large outputs, so may not appear in simple tests.

### Pitfall 2: Double-resume of CheckedContinuation on timeout + normal exit race
**What goes wrong:** The 120s timeout Task fires `process.terminate()` and calls `continuation.resume(returning: .timeout)`. Milliseconds later, Foundation's `terminationHandler` also fires (because `terminate()` caused the process to exit) and calls `continuation.resume(returning: .failed(...))`. Second resume crashes: "SWIFT TASK CONTINUATION MISUSE".

**Why it happens:** `process.terminate()` sends SIGTERM; Foundation calls `terminationHandler` shortly after. Both code paths reach `continuation.resume()`.

**How to avoid:** Use a `nonisolated(unsafe) var resumed = false` flag in the `withCheckedContinuation` closure. Each resume path checks-then-sets this flag. Because `terminationHandler` is called on a single GCD thread (Foundation serialises it), and the timeout Task checks `!Task.isCancelled` first, exactly one path wins.

**Warning signs:** "SWIFT TASK CONTINUATION MISUSE" crash in logs when the 120s timeout fires on a long-running ASR command.

### Pitfall 3: readabilityHandler fires after process exits with stale/empty data
**What goes wrong:** After the process exits, `readabilityHandler` may fire one final time with `availableData` returning empty `Data`. If you treat empty data as an error or append it, you corrupt the accumulated output.

**Why it happens:** Foundation fires the handler when the pipe's file descriptor closes (EOF signal). Empty data is the EOF sentinel, not an error.

**How to avoid:** Check `!chunk.isEmpty` before appending in the handler. Set `readabilityHandler = nil` in `terminationHandler` before reading final stdout/stderr to prevent post-exit calls.

### Pitfall 4: Login shell startup time adds latency
**What goes wrong:** `/bin/zsh -lc` reads login scripts (`/etc/zprofile`, `~/.zprofile`, `~/.zshrc`). If those scripts are slow (conda initialisation, nvm, rbenv), the ASR command may take 1–3 seconds before the ASR tool even starts. Combined with model load time, this can push total latency high.

**Why it happens:** Login shell (`-l`) runs all startup files. Non-login shell is faster but loses Homebrew PATH.

**How to avoid:** This is a known trade-off for D-02; no workaround needed in Phase 3. Document in the status display if latency seems surprising to the user. The 120s timeout is generous enough to accommodate even slow login scripts + large models.

### Pitfall 5: UserDefaults value not available when AppState reads at recording stop
**What goes wrong:** The ASR command TextField in MenuView writes via `@AppStorage`; AppState reads via `UserDefaults.standard.string(forKey:)`. If the two use different key strings, one writes and the other reads nothing → "set your ASR command" message even after user typed a command.

**Why it happens:** `@AppStorage("keyA")` and `UserDefaults.standard.string(forKey: "keyB")` must use the identical key string.

**How to avoid:** Define a single constant for the key: `static let asrCommandKey = "asrCommand"`. Use it in both the View (`@AppStorage(AppState.asrCommandKey)`) and in AppState (`UserDefaults.standard.string(forKey: AppState.asrCommandKey)`).

---

## Code Examples

### Transcriber: Validate + Substitute

```swift
// [ASSUMED] — follows project style; pure function, unit-testable
enum TranscriberError: Error, Equatable {
    case emptyCommand
    case missingWavToken
    case asrFailed(exitCode: Int32, stderr: String)
    case asrTimedOut
    case emptyTranscript
}

struct Transcriber {
    static func prepare(command: String, wavURL: URL) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriberError.emptyCommand        // D-03
        }
        guard command.contains("{wav}") else {
            throw TranscriberError.missingWavToken     // D-05
        }
        let quoted = "'" + wavURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return command.replacingOccurrences(of: "{wav}", with: quoted)
    }
}
```

### AppState: startTranscription flow

```swift
// [ASSUMED] — mirrors stopRecording()/scheduleRecordingTimeout() pattern
func stopRecordingAndTranscribe() {
    guard captureState == .recording else { return }
    recordingTimeoutTask?.cancel()
    recordingTimeoutTask = nil
    onStopRecording()
    captureState = .transcribing    // D-10

    guard let wavURL = audioRecorder.latestWavURL else {
        captureState = .idle
        statusText = "Transcription failed — recording not found"
        return
    }

    Task {
        let result = await onRunTranscription(wavURL)  // closure seam
        await MainActor.run {
            switch result {
            case .success(let text):
                self.transcript = text
                self.captureState = .finished
                NSLog("MakeAnIssue transcript: \(text)")  // D-09
            case .failure(let message):
                self.transcriptError = message
                self.captureState = .idle     // D-11: reset so next PTT works
                self.statusText = message
            }
        }
    }
}
```

### MenuView: ASR Command TextField + Transcript Display

```swift
// [CITED: developer.apple.com/documentation/swiftui/persistent-storage]
// @AppStorage in a View body — automatic UserDefaults persistence
@AppStorage("asrCommand") private var asrCommand: String = ""

// In VStack:
LabeledContent("ASR Command") {
    TextField("e.g. whisper {wav} --model base", text: $asrCommand)
}

if let transcript = appState.transcript {
    LabeledContent("Transcript") {
        Text(transcript)
            .textSelection(.enabled)   // mirrors repo-path pattern (D-09)
    }
}
```

---

## Runtime State Inventory

> This is a greenfield feature addition, not a rename/refactor/migration phase. The only persisted state introduced is one new UserDefaults key (`asrCommand`). No existing stored data, live service config, OS-registered state, secrets, or build artifacts are affected.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None pre-existing; Phase 3 introduces `asrCommand` UserDefaults key (first use of UserDefaults in app) | Code only — no migration |
| Live service config | None | None |
| OS-registered state | None | None |
| Secrets/env vars | None | None |
| Build artifacts | None — no new package; existing build output is still valid | None |

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (Swift 6.3.2 / Xcode 26.5) |
| Config file | Package.swift `.testTarget("MakeAnIssueTests")` |
| Quick run command | `swift test` |
| Full suite command | `swift test` |
| Current baseline | 38 tests, 0 failures [VERIFIED: local run] |

### Nyquist Boundary: Automatable vs Manual

**Automatable via closure-seam (no real process, no real ASR):**

- `.transcribing` state transition when `stopRecording()` triggers transcription
- `onRunTranscription` seam receives the correct WAV URL
- Empty command → `TranscriberError.emptyCommand` / correct status text
- Missing `{wav}` token → `TranscriberError.missingWavToken` / correct status text
- Successful transcription stub → `transcript` property set, `captureState` returns to `.finished`
- Failed transcription stub (throws) → `captureState` resets to `.idle`, `statusText` shows error
- Timeout path (stub throws `TranscriberError.asrTimedOut`) → "ASR timed out after 120s" message
- `Transcriber.prepare()` substitution correctness: paths with spaces, single-quotes in path
- `Transcriber.prepare()` whitespace-trim of stdout output
- New recording starts from `.idle` (not blocked by prior `.transcribing` state)

**Automatable with real `/bin/echo` (CLIRunner functional test; no ASR binary):**

- CLIRunner stdout capture: `echo hello` → stdout == "hello\n"
- CLIRunner stderr capture: `echo err >&2` → stderr == "err\n", stdout == ""
- CLIRunner exit code: `exit 1` → exitCode == 1
- CLIRunner timeout: `sleep 200` with timeout=0.1s → `.timeout` result
- CLIRunner working directory: `pwd` → stdout == expected directory

**Manual-only (hardware + real ASR binary required):**

- Real speech → WAV → real `whisper` (or other ASR CLI) → transcript text produced
- Login shell PATH: Homebrew-installed ASR tool found via `/bin/zsh -lc` when run from GUI app
- End-to-end: hold shortcut → speak → release → "Transcribing…" appears → transcript appears in menu
- NSLog output visible in Console.app during background-app testing
- "Transcribing…" status visible in menu during a real slow model run

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TRANSCRIBE-01 | Empty command → no spawn, clear error | Unit | `swift test --filter AppStateTests/testEmptyCommandShowsError` | ❌ Wave 0 |
| TRANSCRIBE-01 | Missing {wav} → no spawn, clear error | Unit | `swift test --filter TranscriberTests/testMissingWavTokenError` | ❌ Wave 0 |
| TRANSCRIBE-01 | Valid command → CLIRunner invoked with substituted path | Unit (seam) | `swift test --filter AppStateTests/testTranscriptionInvokesSeamWithWavURL` | ❌ Wave 0 |
| TRANSCRIBE-01 | Real ASR binary finds WAV and runs | Manual | — | — |
| TRANSCRIBE-01 | .transcribing state shown after key-up | Unit | `swift test --filter AppStateTests/testStopRecordingTransitionsToTranscribing` | ❌ Wave 0 |
| TRANSCRIBE-02 | stdout trimmed and stored in transcript | Unit | `swift test --filter AppStateTests/testSuccessfulTranscriptionStoresText` | ❌ Wave 0 |
| TRANSCRIBE-02 | stderr NOT in transcript | Unit | `swift test --filter CLIRunnerTests/testStderrSeparateFromStdout` | ❌ Wave 0 |
| TRANSCRIBE-02 | Transcript text visible in menu (selectable) | Manual | — | — |
| TRANSCRIBE-02 | NSLog shows transcript | Manual | Console.app | — |
| TRANSCRIBE-02 | Timeout → "ASR timed out" message, state reset | Unit + manual | `swift test --filter AppStateTests/testTimeoutResetsState` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green (38 + new tests) before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `Tests/MakeAnIssueTests/CLIRunnerTests.swift` — covers CLIRunner stdout/stderr/exit/timeout with real `/bin/echo`
- [ ] `Tests/MakeAnIssueTests/TranscriberTests.swift` — covers prepare(), substitution, trim, validation errors
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` additions — covers state machine for transcription paths

*(No new framework needed — XCTest already configured)*

---

## Security Domain

> `security_enforcement: true`, `security_asvs_level: 1` per .planning/config.json.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Not applicable — local desktop app, no auth |
| V3 Session Management | No | Not applicable |
| V4 Access Control | No | Not applicable |
| V5 Input Validation | Yes | `Transcriber.prepare()` validates command is non-empty and contains `{wav}` before any Process spawn |
| V6 Cryptography | No | Not applicable |

### Known Threat Patterns for Foundation Process + zsh -lc

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Command injection via `{wav}` path | Tampering | POSIX single-quote escaping (`'...'`); single-quotes prevent shell expansion of path contents |
| User command contains shell metacharacters (e.g. `;rm -rf`) | Tampering | By design (D-02), the user controls the command string entirely — this is intentional. The app executes only what the user configured in their own menu. No third-party input reaches the command. |
| Process inherits app's file access | Elevation of Privilege | Non-sandboxed by design (PROJECT.md); accepted v1 trade-off. App already has filesystem access. No additional exposure from CLIRunner. |
| Stdout data from untrusted process | Spoofing | Phase 3 only reads and displays text. No code execution. Transcript is shown in a `Text` view — not parsed as code. |
| Process timeout evasion (SIGTERM ignored) | Denial of Service | CLIRunner uses `process.terminate()` (SIGTERM). If ignored, the Task's timeout fires and the app resets state regardless. The background process may continue; app moves on. `SIGKILL` escalation is v2 hardening, not needed for v1 happy path. |

**Security posture note:** The primary risk surface is the user-configured shell command, which by explicit product design (D-02) is treated as trusted user input — equivalent to a terminal command the user typed themselves. No sanitisation is applied to the command string itself, and this is correct. Only the `{wav}` path substitution must be shell-safe.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `NSTask` / `launchPath` | `Foundation.Process` + `executableURL` + `run()` | macOS 10.13 / Swift 3 | `launchPath` deprecated; use `executableURL` URL and `try process.run()` |
| `readDataToEndOfFile()` for full stdout | `readabilityHandler` + `availableData` | Long-standing best practice | Avoids pipe deadlock for large outputs |
| `waitUntilExit()` on calling thread | `withCheckedContinuation` + `terminationHandler` | Swift 5.5+ async/await | Non-blocking; composable with timeout Task |
| `UserDefaults.standard` direct read/write in Views | `@AppStorage` property wrapper | SwiftUI (macOS 11+) | Automatic view invalidation; zero boilerplate |

**Deprecated/outdated:**
- `Process.launchPath`: Use `executableURL` instead. App already targets macOS 13+.
- `Process.launch()`: Use `try process.run()` instead (throws on executable-not-found rather than crashing).

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `nonisolated(unsafe) var resumed = false` correctly prevents double-resume in the terminationHandler+timeout race | Pattern 2, Pitfall 2 | Runtime crash "SWIFT TASK CONTINUATION MISUSE" on timeout; mitigation: use an actor-isolated flag instead if this proves unreliable |
| A2 | Foundation calls `terminationHandler` exactly once, even after `process.terminate()` | Pattern 2 | If called twice, the `resumed` flag handles it; no crash risk, but the pattern is belt-and-suspenders |
| A3 | POSIX single-quote escaping (`'` → `'\''`) is correct for all macOS Application Support paths | Pattern 3 | Path with single-quote in username could break — extremely rare on macOS; acceptable v1 risk |
| A4 | `onRunTranscription` closure shape `(URL) async throws -> String` is the right seam for unit-testing | Pattern 4 | If the transcription result needs richer data (multiple fields), the closure return type must change; this is Claude's Discretion territory |
| A5 | `/bin/zsh` always exists at that path on macOS 13+ | Pattern 2 | Has been at `/bin/zsh` since macOS 10.15; extremely stable; acceptable assumption |
| A6 | macOS pipe buffer is approximately 64 KB | Pitfall 1 | If larger, deadlock risk is lower but pattern is still correct |

---

## Open Questions

1. **`onRunTranscription` return type**
   - What we know: The seam must return either a transcript string (success) or a description of failure (error).
   - What's unclear: Should the closure return a `Result<String, TranscriberError>` or throw? Throwing is idiomatic Swift async but requires `try` at every call site.
   - Recommendation: Use `throws` — matches the async pattern already used in `requestMicrophonePermission()`. Tests can use `{ _ in return "text" }` (success) or `{ _ in throw TranscriberError.emptyCommand }` (error).

2. **`captureState` after successful transcription**
   - What we know: D-11 says failure → `.idle` so new PTT works. D-09 says success → show transcript.
   - What's unclear: After success, should state be `.finished` (recording done, transcript shown) or `.idle` (fully reset)?
   - Recommendation: `.finished` on success (transcript visible in menu); next key-down transitions to `.recording` from `.finished` (which `startRecording()` already permits — `guard captureState != .recording`).

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Swift | Build | ✓ | 6.3.2 | — |
| Xcode | Build | ✓ | 26.5 | — |
| /bin/zsh | CLIRunner runtime | ✓ | macOS built-in | — |
| swift test | Test runner | ✓ | Works (38 tests pass) | — |
| Real ASR binary (whisper, etc.) | Manual verification only | User-supplied | — | Skip; test with /bin/echo |

**Missing dependencies with no fallback:** None for automated tests.
**Missing dependencies for manual test:** Real ASR CLI (whisper, mlx_whisper, etc.) is user-supplied; not available in automated CI.

---

## Sources

### Primary (MEDIUM confidence — Context7 / official Apple docs)
- `/websites/developer_apple_swiftui` — `@AppStorage` property wrapper, `defaultAppStorage`, `TextField` binding patterns [CITED: developer.apple.com/documentation/swiftui/persistent-storage]
- `/swiftlang/swift-foundation` — Subprocess/Process proposal SF-0007 and SF-0037 (readabilityHandler patterns, async stream design)

### Secondary (LOW confidence — Web)
- Apple Developer Forums thread/669842 — DTS engineer guidance on `readabilityHandler` vs `readDataToEndOfFile()`, EOF semantics, buffering
- Swift Forums: "Right way to Asynchronously wait for a Process to terminate" — `withCheckedContinuation` + `terminationHandler` pattern
- Swift Forums: "How to prevent SWIFT TASK CONTINUATION MISUSE" — double-resume prevention
- smittytone.net/2024/09/14 — `readabilityHandler` + `availableData` implementation example

### Tertiary (VERIFIED: local environment)
- `swift test` — 38 existing tests pass; infrastructure confirmed working [VERIFIED: local run]
- `swift --version` — Swift 6.3.2 / Xcode 26.5 [VERIFIED: local run]
- `Package.swift` — No new dependencies needed; Foundation is built-in [VERIFIED: file inspection]
- `AppState.swift`, `AudioRecorder.swift`, `MenuView.swift`, `AppStateTests.swift` — Exact symbol names, seam patterns, and CaptureState enum confirmed by file inspection [VERIFIED: file inspection]

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Foundation Process/Pipe is the only viable API; no alternatives (SwiftSubprocess not yet released)
- Architecture (component boundaries, seam shape): HIGH — derived from actual codebase inspection
- Process concurrency patterns (readabilityHandler, double-resume guard): MEDIUM — Apple developer forum guidance + community patterns; no official Apple sample app confirms exact combination
- Exact `nonisolated(unsafe)` idiom for the resume flag: LOW — ASSUMED from Swift 6 concurrency; alternative: use actor

**Research date:** 2026-06-24
**Valid until:** 2026-07-24 (Foundation API is stable; Swift Subprocess proposal not yet in stdlib)
