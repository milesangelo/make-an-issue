# Phase 6: Cancellation / Stop Control — Pattern Map

**Mapped:** 2026-06-29
**Files analyzed:** 7 (5 source modifications + 2 new test files)
**Analogs found:** 7 / 7

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Sources/MakeAnIssue/CLIRunner.swift` | service | request-response | self (modify in place) | exact |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | service | request-response | self (modify in place) | exact |
| `Sources/MakeAnIssue/AppState.swift` | store | event-driven | self (modify in place) | exact |
| `Sources/MakeAnIssue/FilingJob.swift` | model | — | self (modify in place) | exact |
| `Sources/MakeAnIssue/AppDelegate.swift` | middleware | request-response | self (modify in place) | exact |
| `Tests/MakeAnIssueTests/CLIRunnerTests.swift` | test | request-response | self (extend in place) | exact |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | test | event-driven | self (extend in place) | exact |

---

## Pattern Assignments

### `Sources/MakeAnIssue/CLIRunner.swift` — add `withTaskCancellationHandler` cancel bridge

**Analog:** same file, existing timeout escalation pattern (lines 158–186)

**Core pattern to copy from — timeout escalation** (`CLIRunner.swift` lines 158–186):
```swift
// Timeout Task — mirrors AppState.scheduleRecordingTimeout (D-12).
timeoutTask = Task {
    try? await Task.sleep(for: timeout)
    guard !Task.isCancelled else { return }
    // Claim the resume slot BEFORE terminating, so we deterministically
    // win the race against the terminationHandler that terminate() will
    // fire. If the process already exited, claim() returns nil and we
    // leave the already-delivered result untouched.
    guard state.claim() != nil else { return }
    process.terminate()   // SIGTERM — ask the child to exit cleanly first.
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    continuation.resume(returning: .timeout)

    // Escalate to SIGKILL if the child ignores SIGTERM
    Task {
        try? await Task.sleep(for: .seconds(2))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)   // ← line 183: fix to kill(-pgid, SIGKILL)
        }
    }
}
```

**Single-resume invariant — `RunState.claim()` pattern** (`CLIRunner.swift` lines 51–58):
```swift
func claim() -> (stdout: String, stderr: String)? {
    lock.lock(); defer { lock.unlock() }
    guard !resumed else { return nil }
    resumed = true
    let out = String(data: stdoutData, encoding: .utf8) ?? ""
    let err = String(data: stderrData, encoding: .utf8) ?? ""
    return (out, err)
}
```

**`terminationHandler` resume path** (`CLIRunner.swift` lines 120–144) — **the sole resume path; cancel onCancel must NOT resume the continuation**:
```swift
process.terminationHandler = { p in
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    let restOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    if !restOut.isEmpty { state.appendStdout(restOut) }
    let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    if !restErr.isEmpty { state.appendStderr(restErr) }

    guard let (out, err) = state.claim() else { return }

    if p.terminationStatus == 0 {
        continuation.resume(returning: .success(stdout: out, stderr: err, exitCode: 0))
    } else {
        continuation.resume(returning: .failed(exitCode: p.terminationStatus, stderr: err))
    }
}
```

**What to add:**

Wrap the existing `withCheckedContinuation` inside `withTaskCancellationHandler`. The `onCancel` closure sends `kill(-pgid, SIGTERM)` + schedules a detached `Task` for `kill(-pgid, SIGKILL)` after 2s. It does NOT call `state.claim()` or resume the continuation — the `terminationHandler` remains the sole resume path. Also:
- Declare `nonisolated(unsafe) var pgid: pid_t = 0` before the wrapper.
- Set `pgid = process.processIdentifier` immediately after `try process.run()`.
- Synchronously check `if Task.isCancelled { kill(-pgid, SIGTERM) }` after setting `pgid` to handle the pre-launch cancel race (Pitfall 5 from RESEARCH.md).
- Fix line 183: change `kill(process.processIdentifier, SIGKILL)` to `kill(-process.processIdentifier, SIGKILL)` everywhere in the file (group kill, not single-PID).

---

### `Sources/MakeAnIssue/IssueFilingRunner.swift` — add `Task.checkCancellation()` seam

**Analog:** same file, `CLIRunner().run(...)` call site (lines 161–166) + existing `defer` tempfile cleanup (lines 143–147)

**`defer` tempfile cleanup pattern** (`IssueFilingRunner.swift` lines 143–147):
```swift
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
try config.mcpConfigJSON.write(to: tempURL, atomically: true, encoding: .utf8)
// Defer deletion so the file is removed on every exit path — success, throw, or timeout.
defer { try? FileManager.default.removeItem(at: tempURL) }
```

**`CLIRunner.run` call site** (`IssueFilingRunner.swift` lines 161–166):
```swift
let result = await CLIRunner().run(
    command: command,
    workingDirectory: repo.rootURL,
    environment: [config.tokenEnvKey: token],
    timeout: .seconds(300)
)
```

**What to add:**

Insert `try Task.checkCancellation()` immediately after the `CLIRunner().run(...)` call, before the `switch result { ... }`. The existing `defer { try? FileManager.default.removeItem(at: tempURL) }` runs on all throw paths — no change needed for tempfile cleanup on cancel.

Optionally add `onProcessStarted: ((pid_t) -> Void)? = nil` parameter to `file(...)` so `AppState.spawnFilingJob` can capture the PGID for quit-time `forceKillAllProcessTrees()` (RESEARCH.md Open Question 2).

---

### `Sources/MakeAnIssue/AppState.swift` — add `cancel(jobID:)`, `cancelAll()`, `forceKillAllProcessTrees()`, CancellationError catch

**Analog:** same file, existing `spawnFilingJob` Task body and error-catch pattern (lines 260–292)

**`spawnFilingJob` task body + error catch pattern** (`AppState.swift` lines 264–292):
```swift
let task = Task { [weak self, id, transcript, repo] in
    guard let self else { return }
    do {
        let result = try await onRunIssueFiling(transcript, repo)
        // @MainActor-inherited Task — no MainActor.run needed after await.
        if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
            self.jobs[idx].state = .done
            self.jobs[idx].result = result
        }
        self.announce("created issue #\(result.number)")
    } catch let filingError as IssueFilingError {
        if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
            self.jobs[idx].state = .failed
            self.jobs[idx].error = filingError
        }
        self.announce("issue filing failed")
    } catch {
        if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
            self.jobs[idx].state = .failed
        }
        self.announce("issue filing failed")
    }
}
```

**`announce(_:)` deferred-announcement pattern** (`AppState.swift` lines 295–310):
```swift
private func announce(_ text: String) {
    if captureState == .recording {
        pendingAnnouncements.append(text)
    } else {
        speakText(text)
    }
}
```

**Task handle storage pattern** (`AppState.swift` lines 288–291):
```swift
// Store the task handle for Phase 6 cancellation (forward-prep).
if let idx = jobs.firstIndex(where: { $0.id == id }) {
    jobs[idx].task = task
}
```

**What to add:**

1. Before the existing `catch let filingError as IssueFilingError` arm, insert:
```swift
} catch is CancellationError {
    if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
        self.jobs[idx].state = .cancelled
    }
    self.announce("filing cancelled")   // D-05: routes through defer-until-mic-idle queue
```

2. Add new `cancel(jobID:)` and `cancelAll()` methods (same `@MainActor` scope as `spawnFilingJob`):
```swift
func cancel(jobID: UUID) {
    guard let idx = jobs.firstIndex(where: { $0.id == jobID && $0.state == .filing }) else { return }
    jobs[idx].task?.cancel()
    // State transitions to .cancelled in spawnFilingJob's CancellationError catch arm,
    // not here — avoids a premature state update before the process is dead.
}

func cancelAll() {
    jobs.filter { $0.state == .filing }.forEach { $0.task?.cancel() }
}
```

3. Add `forceKillAllProcessTrees()` for quit-time SIGKILL:
```swift
func forceKillAllProcessTrees() {
    for job in jobs where job.state == .filing {
        if let pgid = job.processGroupID {
            kill(-pgid, SIGKILL)
        }
    }
}
```

---

### `Sources/MakeAnIssue/FilingJob.swift` — add `processGroupID: pid_t?`

**Analog:** same file, existing `task: Task<Void, Never>?` forward-prep field (line 35)

**Existing forward-prep field pattern** (`FilingJob.swift` lines 34–35):
```swift
/// Cancellation handle for Phase 6. Stored here; `.cancel()` is wired in Phase 6.
var task: Task<Void, Never>?
```

**What to add:**

Add `var processGroupID: pid_t?` directly below `task`, following the same doc-comment convention:
```swift
/// Process group ID of the filing subprocess. Set by AppState once CLIRunner starts;
/// used for quit-time SIGKILL in AppDelegate.forceKillAllProcessTrees().
var processGroupID: pid_t?
```

---

### `Sources/MakeAnIssue/AppDelegate.swift` — add `applicationShouldTerminate`

**Analog:** same file, existing delegate method pattern (lines 9–31) and `AppState` reference (`appState`, line 5)

**Existing delegate pattern** (`AppDelegate.swift` lines 4–31):
```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private let launchRequestStore = LaunchRequestStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        consumeLatestLaunchRequest()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        consumeLatestLaunchRequest()
        sender.activate(ignoringOtherApps: true)
        return true
    }
    // ...
}
```

**What to add:**

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard appState.jobs.contains(where: { $0.state == .filing }) else {
        sweepMCPTempFiles()
        return .terminateNow
    }
    appState.cancelAll()   // SIGTERM to all in-flight process groups immediately
    Task { @MainActor in
        defer { NSApp.reply(toApplicationShouldTerminate: true) }
        try? await Task.sleep(for: .seconds(2))   // 2s grace for docker --rm cleanup
        appState.forceKillAllProcessTrees()        // SIGKILL any SIGTERM survivors
        sweepMCPTempFiles()
    }
    return .terminateLater
}

private func sweepMCPTempFiles() {
    let tempDir = FileManager.default.temporaryDirectory
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: tempDir,
        includingPropertiesForKeys: nil
    ) else { return }
    for url in contents
        where url.lastPathComponent.hasPrefix("make-an-issue-mcp-")
           && url.lastPathComponent.hasSuffix(".json") {
        try? FileManager.default.removeItem(at: url)
    }
}
```

Note: `defer { NSApp.reply(toApplicationShouldTerminate: true) }` inside the Task guarantees the reply fires even if any sweep step throws. Pattern sourced from Pitfall 6 in RESEARCH.md.

---

### `Tests/MakeAnIssueTests/CLIRunnerTests.swift` — add cancel + process-group tests

**Analog:** same file, existing `testTimeoutAndExitBoundaryResolvesExactlyOnce` test (lines 67–85) and `testTimeoutTerminatesAndResolvesOnce` (lines 48–63)

**Timeout-resolves-exactly-once stress pattern** (`CLIRunnerTests.swift` lines 67–85):
```swift
func testTimeoutAndExitBoundaryResolvesExactlyOnce() async throws {
    // A double-resume would trap with SWIFT TASK CONTINUATION MISUSE
    // and crash this test process, so simply reaching the end of the loop
    // proves the single-resume guard held.
    for _ in 0..<40 {
        let result = await CLIRunner().run(
            command: "sleep 0.05",
            timeout: .milliseconds(50)
        )
        switch result {
        case .success, .failed, .timeout:
            break
        }
    }
}
```

**Timeout fires and resolves pattern** (`CLIRunnerTests.swift` lines 48–63):
```swift
func testTimeoutTerminatesAndResolvesOnce() async throws {
    let start = Date()
    let result = await CLIRunner().run(
        command: "sleep 5",
        timeout: .milliseconds(200)
    )
    let elapsed = Date().timeIntervalSince(start)

    if case .timeout = result { } else {
        XCTFail("Expected .timeout, got \(result)")
    }
    XCTAssertLessThan(elapsed, 4.0, "Timeout should resolve well before 5s; elapsed: \(elapsed)s")
}
```

**What to add:**

1. `testCancelKillsProcessGroup` — spawn `sleep 60` wrapped in a subprocess; cancel the enclosing Task; assert the child `sleep` PID (`kill(pid, 0)` returns `ESRCH`) is dead after cancel. Use `sleep` rather than the real `claude` binary (RESEARCH.md integration test note).

2. `testCancelAndExitBoundaryResolvesExactlyOnce` — same loop shape as `testTimeoutAndExitBoundaryResolvesExactlyOnce` but cancel the Task instead of relying on wall-clock timeout. A double-resume would produce `SWIFT TASK CONTINUATION MISUSE` crash; surviving the loop is the proof.

---

### `Tests/MakeAnIssueTests/AppStateTests.swift` — add cancel state + announcement tests

**Analog:** same file, existing filing-job state tests and stub-injection pattern (lines 113–150 and 312–350)

**Stub-injection + `waitUntil` pattern** (`AppStateTests.swift` lines 113–132):
```swift
func testStartRecordingAfterFilingReturnsToIdleStartsNewRecording() async {
    let state = AppState(
        onStartRecording: { true },
        onStopRecording: {},
        onRunTranscription: { _ in "Hello world" }
    )
    state.micPermissionGranted = true
    state.startRecording()
    state.stopRecording()

    await waitUntil { state.captureState == .idle }
    XCTAssertEqual(state.captureState, .idle)

    state.startRecording()
    XCTAssertEqual(state.captureState, .recording)
}
```

**`onSpeak` seam capture pattern** — used in existing Phase 4 / 5 tests:
```swift
var spoken: [String] = []
let state = AppState(
    onStartRecording: { true },
    onStopRecording: {},
    onRunTranscription: { _ in "text" },
    onRunIssueFiling: { _, _ in IssueFilingResult(number: 1, url: "https://example.com/issues/1") },
    onSpeak: { spoken.append($0) }
)
```

**What to add:**

1. `testCancelJobIdTransitionsToCancel` — inject a long-running `onRunIssueFiling` stub (never returns until cancelled); call `cancel(jobID:)`; use `waitUntil { state.jobs[0].state == .cancelled }`; assert state is `.cancelled`.

2. `testCancelAnnouncementDeferredDuringRecording` — inject filing stub that suspends; start recording; cancel job; assert spoken text is empty during recording, then `.cancelled` spoken after `stopRecording()` drains `pendingAnnouncements`. Uses `onSpeak` seam to capture spoken strings without audio.

3. `testCancelAll` — spawn two concurrent filing stubs; call `cancelAll()`; use `waitUntil` to assert both reach `.cancelled`.

4. `testCancelledJobRetainedInJobsList` — cancel a job; assert `state.jobs.count == 1` and `state.jobs[0].state == .cancelled` (D-02/D-03: retained, not deleted).

---

## Shared Patterns

### Single-Resume Invariant (`RunState.claim()`)
**Source:** `Sources/MakeAnIssue/CLIRunner.swift` lines 51–58
**Apply to:** `CLIRunner.swift` cancel `onCancel` handler — it must ONLY send signals, never call `state.claim()` or resume the continuation. The `terminationHandler` remains the sole resume path.

```swift
func claim() -> (stdout: String, stderr: String)? {
    lock.lock(); defer { lock.unlock() }
    guard !resumed else { return nil }
    resumed = true
    // ...
    return (out, err)
}
```

### Error Catch Arm Ordering in `spawnFilingJob`
**Source:** `Sources/MakeAnIssue/AppState.swift` lines 274–285
**Apply to:** New `CancellationError` catch arm — must appear BEFORE the existing `catch let filingError as IssueFilingError` arm, as `CancellationError` is not a subtype of `IssueFilingError`. The generic `catch` arm (lines 282–285) already exists as a fallback.

### `defer` on Async Cleanup
**Source:** `Sources/MakeAnIssue/IssueFilingRunner.swift` line 147
**Apply to:** `AppDelegate.applicationShouldTerminate` cleanup Task — use `defer { NSApp.reply(toApplicationShouldTerminate: true) }` inside the Task body so the reply fires on every exit path (Pitfall 6).

### `@MainActor` Task Pattern
**Source:** `Sources/MakeAnIssue/AppState.swift` lines 264–291
**Apply to:** All new methods on `AppState` (`cancel(jobID:)`, `cancelAll()`, `forceKillAllProcessTrees()`). The class is `@MainActor final class` — new methods inherit that isolation automatically without `await MainActor.run {}`.

### `waitUntil` Helper in Tests
**Source:** `Tests/MakeAnIssueTests/AppStateTests.swift` lines 127, 207, 236, 302
**Apply to:** All new `AppStateTests` async tests that must wait for Task-dispatched state changes. Use `await waitUntil { condition }` to poll rather than `Task.sleep`.

### Process-Group Kill (POSIX)
**Source:** RESEARCH.md Discretion Item 1 (replaces `CLIRunner.swift` line 183)
**Apply to:** Every `kill(...)` call in `CLIRunner.swift` and `AppDelegate.sweepMCPTempFiles` path:
```swift
// WRONG (existing line 183):
kill(process.processIdentifier, SIGKILL)
// CORRECT:
kill(-process.processIdentifier, SIGKILL)   // negative PID = signal process group
```

---

## No Analog Found

All files in this phase have direct in-codebase analogs. The `withTaskCancellationHandler` bridge and `applicationShouldTerminate` patterns are new code shapes not yet present in the codebase, but their internal structure follows directly from the existing `RunState.claim()` / timeout-Task pattern and the existing `applicationShouldHandleReopen` delegate method, respectively. Detailed code excerpts for these are provided in RESEARCH.md §Code Examples.

---

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/`, `Tests/MakeAnIssueTests/`
**Files read:** CLIRunner.swift, AppState.swift, FilingJob.swift, IssueFilingRunner.swift, AppDelegate.swift, CLIRunnerTests.swift, AppStateTests.swift (partial)
**Pattern extraction date:** 2026-06-29
