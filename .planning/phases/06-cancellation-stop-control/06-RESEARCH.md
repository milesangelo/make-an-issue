# Phase 6: Cancellation / Stop Control — Research

**Researched:** 2026-06-29
**Domain:** macOS process-tree termination, Swift concurrency cancellation, NSApplicationDelegate lifecycle
**Confidence:** MEDIUM (all three discretion items resolved from code examination + verified patterns)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01 (Cancel trigger surface):** Mechanism-only. Build `cancel(jobID:)` and `cancelAll()` on the jobs model, proven via integration tests. No interim "Stop filing" menu item.
- **D-02 (Cancelled job state):** Cancelled jobs are marked `FilingJobState.cancelled` and retained in `jobs[]` — same as `.done`/`.failed`. Uses the `.cancelled` case Phase 5 already added.
- **D-03 (Roadmap "removes the job"):** Means removes from the active/in-flight set (no longer `.filing`), NOT literal deletion from `jobs[]`. Phase 5 retained-terminal-jobs model is authoritative.
- **D-04 (Quit-time cleanup):** Intercept `applicationShouldTerminate` → `.terminateLater`. Send each in-flight tree a graceful signal first (so Docker `--rm` can auto-remove), escalate to force-kill after a bounded grace window, sweep `make-an-issue-mcp-*.json` tempfiles, then allow app to terminate.
- **D-05 (Cancelled announcement):** Every cancel speaks `"filing cancelled"` through Phase 5's `announce()` defer-until-mic-idle queue.
- **D-06 (Quit-time TTS):** On actual app quit, spoken announcement realistically will not reach the speaker — accepted. CANCEL-02's spoken requirement is satisfied by the user-initiated cancel path.

### Claude's Discretion (routed to this research)

- **Process-tree termination mechanics** — how to kill the full `zsh → claude → docker run` tree, not just the zsh PID.
- **CLIRunner cancellation seam** — how `CLIRunner.run` observes Swift Task cancellation while preserving the single-resume `RunState` invariant.
- **Exact grace-window duration** for D-04's SIGTERM→SIGKILL escalation on quit.

### Deferred Ideas (OUT OF SCOPE)

- Per-job Stop button + jobs list UI — Phase 9 (JOBS-02).
- NSStatusItem shell / right-click menu — Phase 7.
- Per-type / detailed cancelled messaging — Phase 9 (RESIL-01).
- Cancel-all / dismiss-completed affordances for retained terminal jobs — Phase 9 (JOBS-04).
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CANCEL-01 | User can stop an in-flight filing, terminating its subprocess and the full `claude → docker` process tree — no orphaned `claude` process or leaked `--rm` Docker container. | Process-group kill pattern: `kill(-pgid, SIGTERM)` + grace + `kill(-pgid, SIGKILL)` reaches the whole tree. SIGTERM-first guarantees docker `--rm` cleanup. |
| CANCEL-02 | Cancelled filing surfaces "filing cancelled" outcome (spoken + status) and removes the job (from in-flight set); no issue is filed. | `withTaskCancellationHandler` bridges Swift cancel to process kill; `try Task.checkCancellation()` in `IssueFilingRunner.file` produces `CancellationError`; `AppState.spawnFilingJob` catches it, sets `.cancelled`, calls `announce("filing cancelled")`. |
| CANCEL-03 | Quitting the app while filings are in flight cleans up their subprocesses and per-invocation MCP tempfiles (no orphans). | `applicationShouldTerminate` → `.terminateLater`; `cancelAll()` sends SIGTERM immediately; bounded 2s Task cleans up and calls `replyToApplicationShouldTerminate(true)`; glob sweep removes tempfiles. |
</phase_requirements>

---

## Summary

Phase 6 ships the cancellation mechanism and quit-time teardown for the concurrent filing jobs model Phase 5 established. The central technical problem is that the existing `kill(process.processIdentifier, SIGKILL)` in `CLIRunner` signals only the `/bin/zsh -lc` child PID, leaving `claude` and `docker run --rm` as orphans. The fix is a two-part change: (1) replace the single-PID kill with a process-group kill (`kill(-pgid, SIGTERM)` then grace then `kill(-pgid, SIGKILL)`), and (2) add a `withTaskCancellationHandler` wrapper in `CLIRunner.run` that fires this kill when the enclosing Swift Task is cancelled.

All three success criteria are achievable without new dependencies. No new Swift packages are required — the entire implementation uses POSIX signal APIs (`kill`, `killpg`), Foundation's `Process`, Swift Concurrency's `withTaskCancellationHandler`, and `NSApplicationDelegate.applicationShouldTerminate`. The changes are localised to five files: `CLIRunner.swift`, `IssueFilingRunner.swift`, `AppState.swift`, `FilingJob.swift` (or just `AppState.swift`), and `AppDelegate.swift`.

The most critical ordering constraint is SIGTERM before SIGKILL. Docker `--rm` container cleanup is triggered by the docker daemon when `docker run` exits gracefully (SIGTERM path). If `docker run` is SIGKILL-ed, it cannot forward the signal, the container continues running as a daemon-managed detached container, and `--rm` never fires. [CITED: github.com/moby/moby/issues/46749]

**Primary recommendation:** Use `withTaskCancellationHandler` in `CLIRunner.run` to bridge `Task.cancel()` → `kill(-pgid, SIGTERM)` + grace + `kill(-pgid, SIGKILL)`. Use `try Task.checkCancellation()` in `IssueFilingRunner.file` to surface `CancellationError`. Catch `CancellationError` in `AppState.spawnFilingJob`. Set grace window to 2 seconds (matching the existing CLIRunner timeout escalation). For quit, use `applicationShouldTerminate` → `.terminateLater` + 2s bounded Task.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Process-group kill (SIGTERM + SIGKILL) | `CLIRunner` (subprocess layer) | `AppDelegate` (quit path, via PGID stored on job) | The process object lives in `CLIRunner.run`; it owns the kill. `AppDelegate` drives quit-time force-kill via stored PGIDs. |
| Swift Task cancel → kill bridge | `CLIRunner.run` (`withTaskCancellationHandler`) | — | Bridges Swift cooperative cancellation to POSIX signal without exposing process internals. |
| Cancel trigger (`cancel(jobID:)` / `cancelAll()`) | `AppState` | `AppDelegate` (calls `cancelAll()`) | Job lifecycle state machine lives on `AppState`; `AppDelegate` drives quit path. |
| Cancelled outcome (state + announcement) | `AppState.spawnFilingJob` | — | Catches `CancellationError`; sets `.cancelled`; routes through `announce()`. |
| Quit-time teardown + tempfile sweep | `AppDelegate.applicationShouldTerminate` | — | System delegate hook is the only correct intercept point for macOS quit. |
| Tempfile sweep | `AppDelegate` (quit sweep) + `IssueFilingRunner.file` (`defer`) | — | `defer` handles normal-exit paths; `AppDelegate` sweeps any survivors on quit. |

---

## Standard Stack

No new dependencies. This phase uses only:

| API | Source | Purpose |
|-----|--------|---------|
| `kill(pid_t, Int32)` — POSIX | Darwin / Foundation (`import Darwin`) | Send signal to PID or process group (negative PID = group). |
| `withTaskCancellationHandler(operation:onCancel:)` | Swift Concurrency stdlib | Bridge Task cancellation to synchronous cancel handler. |
| `Task.checkCancellation()` | Swift Concurrency stdlib | Throws `CancellationError` if the current task is cancelled. |
| `NSApplicationDelegate.applicationShouldTerminate(_:)` | AppKit | Intercept quit to run bounded teardown. |
| `NSApp.reply(toApplicationShouldTerminate:)` | AppKit | Resume quit after `.terminateLater`. |
| `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` | Foundation | Enumerate temp directory to glob-delete MCP tempfiles. |

**Installation:** None — all APIs are part of the Swift standard library, Foundation, and AppKit already linked by the target.

---

## Package Legitimacy Audit

Not applicable — this phase installs no external packages.

---

## Architecture Patterns

### System Architecture Diagram

```
cancel(jobID:) or cancelAll()  ←──────────── AppDelegate.applicationShouldTerminate
        │                                              │ .terminateLater
        │ task.cancel()                                │
        ▼                                              │ (same path)
  FilingJob.task (Task<Void,Never>)
        │
        │ Task cooperative cancel
        ▼
  withTaskCancellationHandler.onCancel
        │ kill(-pgid, SIGTERM)
        ▼
  [zsh ← claude ← docker run]  ← SIGTERM broadcast to whole process group
        │
        │ process exits
        ▼
  CLIRunner.terminationHandler
        │ state.claim() — atomic, first caller wins
        ▼
  continuation.resume(.failed(exitCode:...))
        │
        ▼
  IssueFilingRunner.file
        │ try Task.checkCancellation() → CancellationError
        │ (defer still runs: MCP tempfile deleted)
        ▼
  AppState.spawnFilingJob catch is CancellationError
        │ jobs[idx].state = .cancelled
        │ announce("filing cancelled")  ← via defer-until-mic-idle queue
        ▼
  (announce speaks or defers per Phase 5 D-02/D-03)

  ─── Parallel (2s after SIGTERM) ───────────────────────────────────────────

  Task.detached in onCancel (or AppDelegate cleanup Task)
        │ kill(-pgid, SIGKILL)  ← only if process still running
        ▼
  Process force-reaped (container may not be removed if SIGTERM window expired)

  ─── Quit path final step ───────────────────────────────────────────────────

  AppDelegate cleanup Task (2s after cancelAll)
        │ forceKillAll() — SIGKILL any remaining in-flight PGIDs
        │ sweepMCPTempfiles()
        ▼
  NSApp.reply(toApplicationShouldTerminate: true)
```

### Recommended Changes to Existing Structure

No new files required. All changes are modifications to existing files:

```
Sources/MakeAnIssue/
├── CLIRunner.swift            # Add withTaskCancellationHandler; fix kill to -pgid
├── IssueFilingRunner.swift    # Add try Task.checkCancellation() after CLIRunner.run
├── AppState.swift             # Add cancel(jobID:), cancelAll(), CancellationError catch
├── FilingJob.swift            # Add processGroupID: pid_t? (for quit-time forceKill)
└── AppDelegate.swift          # Add applicationShouldTerminate → .terminateLater
Tests/MakeAnIssueTests/
├── CLIRunnerTests.swift       # Add cancel + process-group tests
└── AppStateTests.swift        # Add cancel(jobID:) + cancelAll() + state tests
```

---

## Discretion Item 1: Process-Tree Termination Mechanics

### The Current Gap

`CLIRunner` line 183: `kill(process.processIdentifier, SIGKILL)` — sends SIGKILL to one PID (the `/bin/zsh` shell). The tree `zsh → claude → docker run` is not affected. `claude` and `docker run` survive as orphans.

### macOS Process Group Behavior (Foundation.Process)

Foundation's `Process` (formerly `NSTask`) on macOS places each spawned child in its own process group. The child's PGID equals its own PID — it becomes the process group leader. [ASSUMED — confirmed by runtime behavior in existing code + "NSTask spawns processes outside of the parent's process group" from community documentation. Verify with `ps -o pid,pgid` during Phase 6 implementation.]

In non-interactive shell mode (`/bin/zsh -lc "..."`), zsh does NOT create new process groups for commands it runs. So:
- zsh: PID=X, PGID=X (group leader, set by Foundation.Process)
- claude (spawned by zsh): PID=Y, PGID=X (inherited from zsh)
- docker run (spawned by claude): PID=Z, PGID=X (inherited from claude)

Therefore `kill(-X, SIGTERM)` sends SIGTERM to all three simultaneously.

### The Fix: Replace `kill(pid, ...)` with `kill(-pgid, ...)`

**Existing timeout path (lines 158–186) — the template:**
```swift
// Timeout Task — already present
guard state.claim() != nil else { return }
process.terminate()   // SIGTERM — only reaches zsh today
// ...
kill(process.processIdentifier, SIGKILL)   // ← line 183: only kills zsh
```

**Fix for line 183 and all future kill calls:**
```swift
// Use negative PID = send to process GROUP, not single process
kill(-process.processIdentifier, SIGKILL)   // reaches zsh + claude + docker run
```

And for the initial SIGTERM (line 167 `process.terminate()`):
- `process.terminate()` sends SIGTERM to the single PID (zsh only)
- Replace with `kill(-process.processIdentifier, SIGTERM)` for group-wide SIGTERM

**Why SIGTERM must precede SIGKILL:**

`docker run --rm` cleanup is performed by the `docker run` process on exit — it tells the Docker daemon to stop and remove the container. When `docker run` receives SIGTERM, it stops the container gracefully and the daemon removes it (the `--rm` semantics). When `docker run` receives SIGKILL, it cannot run any cleanup code; the container remains alive as a standalone daemon-managed container and `--rm` never fires. [CITED: github.com/moby/moby/issues/46749]

**Verification command (acceptance criterion):**
```sh
pgrep -f claude    # must return empty after cancel
docker ps          # must show no make-an-issue MCP containers
```

### Anti-Pattern to Avoid

```swift
// WRONG: signals only the zsh PID
kill(process.processIdentifier, SIGTERM)
// WRONG: SIGKILL before SIGTERM skips docker cleanup
kill(-process.processIdentifier, SIGKILL)  // sent immediately, no grace
```

---

## Discretion Item 2: CLIRunner Cancellation Seam

### Why `Task.cancel()` Alone Is Insufficient

`CLIRunner.run` resolves a `withCheckedContinuation`. Swift `Task.cancel()` marks the task cancelled but does NOT resume a pending `withCheckedContinuation` — the continuation remains suspended until the process exits and `terminationHandler` fires. A cancelled Task that is stuck waiting on the continuation hangs indefinitely. [ASSUMED — well-established Swift concurrency constraint; verified by code examination of CLIRunner.swift.]

### Recommended Pattern: `withTaskCancellationHandler` Bridge

```swift
// CLIRunner.swift — new wrapper around the existing withCheckedContinuation
func run(command: String, ...) async -> CLIResult {
    let process = Process()
    // ... existing setup ...

    // nonisolated(unsafe): written once after process.run(); read in onCancel.
    // Race is benign: if onCancel reads 0 (not yet written), kill is skipped.
    // The post-run Task.isCancelled check below handles that race.
    nonisolated(unsafe) var pgid: pid_t = 0

    return await withTaskCancellationHandler(
        operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<CLIResult, Never>) in
                // ... existing terminationHandler, readabilityHandlers ...

                do {
                    try process.run()
                    pgid = process.processIdentifier
                    // Handle race: task already cancelled before pgid was set
                    if Task.isCancelled {
                        kill(-pgid, SIGTERM)
                    }
                } catch { /* existing spawn-failure path */ }

                // ... existing timeoutTask ...
            }
        },
        onCancel: {
            // Runs immediately when calling Task is cancelled.
            // terminationHandler still owns the single claim + resume.
            let capturedPGID = pgid
            if capturedPGID > 0 {
                kill(-capturedPGID, SIGTERM)
                Task.detached {
                    try? await Task.sleep(for: .seconds(2))
                    kill(-capturedPGID, SIGKILL)
                }
            }
        }
    )
}
```

**Why the existing `RunState.claim()` invariant is preserved:**

The `onCancel` handler does NOT call `state.claim()` or resume the continuation. It only sends signals. The `terminationHandler` fires when the process exits (as it always does), calls `state.claim()` exactly once, and resumes the continuation. The `onCancel` SIGTERM merely ensures the process exits promptly so the `terminationHandler` can fire.

If `state.claim()` has already been claimed (timeout or natural exit raced the cancel), `onCancel` fires, sends SIGTERM to a dead process (POSIX returns ESRCH silently), and the `Task.detached` SIGKILL also hits a dead process. Zero double-resume. [ASSUMED — reasoning from `RunState.claim()` source at lines 51–58.]

### IssueFilingRunner.file Seam

Add `try Task.checkCancellation()` immediately after `CLIRunner().run(...)` returns, before the `switch result { ... }`:

```swift
// IssueFilingRunner.swift — add after the CLIRunner.run call (line ~165)
let result = await CLIRunner().run(
    command: command,
    workingDirectory: repo.rootURL,
    environment: [config.tokenEnvKey: token],
    timeout: .seconds(300)
)

// If the calling Task was cancelled, surface CancellationError.
// The defer { try? FileManager.default.removeItem(at: tempURL) } still runs.
try Task.checkCancellation()

switch result { ... }  // only reached on non-cancelled paths
```

The existing `defer { try? FileManager.default.removeItem(at: tempURL) }` runs on all exit paths including throws, so the MCP tempfile is cleaned up correctly on cancel. [VERIFIED: code at IssueFilingRunner.swift lines 147, defer semantics guaranteed by Swift language spec.]

### AppState.spawnFilingJob Cancel Catch

Add a `CancellationError` catch arm before the existing `IssueFilingError` arm:

```swift
// AppState.swift — in spawnFilingJob Task body
} catch is CancellationError {
    if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
        self.jobs[idx].state = .cancelled
    }
    self.announce("filing cancelled")   // D-05: routes through defer-until-mic-idle
} catch let filingError as IssueFilingError {
    // existing
}
```

### Cancel Trigger: AppState.cancel(jobID:) and cancelAll()

```swift
// AppState.swift — new methods
func cancel(jobID: UUID) {
    guard let idx = jobs.firstIndex(where: { $0.id == jobID && $0.state == .filing }) else { return }
    jobs[idx].task?.cancel()
    // Note: state transition to .cancelled happens in spawnFilingJob's catch arm,
    // not here — avoids a premature state update before the process is dead.
}

func cancelAll() {
    jobs.filter { $0.state == .filing }.forEach { $0.task?.cancel() }
}
```

### Where the Cancel Handle Lives

`FilingJob.task` already stores the `Task<Void, Never>` handle (Phase 5 forward-prep, `FilingJob.swift` line 35). No model change needed — `.cancel()` on this Task is the trigger that flows through the `withTaskCancellationHandler` chain.

For quit-time SIGKILL (see Discretion Item 3), `FilingJob` should also store the process group ID:

```swift
// FilingJob.swift — add alongside existing task property
var processGroupID: pid_t?   // Set by AppState once CLIRunner starts; used for quit-time SIGKILL
```

`AppState.spawnFilingJob` receives the PGID by having `IssueFilingRunner.file` surface it. The simplest approach: add an optional `onProcessStarted: ((pid_t) -> Void)?` callback parameter to `IssueFilingRunner.file`, called after `process.run()` with the PGID.

---

## Discretion Item 3: Grace Window and Quit Teardown

### Grace Window Duration: 2 Seconds

Use 2 seconds — matching the existing `CLIRunner` SIGTERM→SIGKILL escalation (lines 181–185: `Task.sleep(for: .seconds(2))`). This is sufficient for `docker run` to receive SIGTERM, forward it to the container, wait for container exit, and trigger `--rm` removal. For `ghcr.io/github/github-mcp-server` (a simple Go binary), graceful shutdown typically completes in under 1 second. [ASSUMED — no measurement performed; validate with an actual cancel during Phase 6 integration testing.]

### AppDelegate Quit Teardown Pattern

```swift
// AppDelegate.swift — add applicationShouldTerminate
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Fast path: no in-flight jobs
    guard appState.jobs.contains(where: { $0.state == .filing }) else {
        sweepMCPTempFiles()
        return .terminateNow
    }

    // Send SIGTERM to all in-flight process groups immediately
    appState.cancelAll()

    // Bounded teardown: wait 2s (SIGTERM grace), then SIGKILL stragglers,
    // sweep tempfiles, and allow quit.
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        // Force-kill any process groups that did not exit within the grace window.
        // Guarantees no orphaned claude processes, but may leave containers
        // if docker run didn't complete --rm cleanup in time (accepted edge case).
        appState.forceKillAllProcessTrees()
        sweepMCPTempFiles()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    return .terminateLater
}

// Glob-delete all per-invocation MCP tempfiles.
// defer{} in IssueFilingRunner.file handles normal exit; this handles app-exit survivors.
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

`AppState.forceKillAllProcessTrees()` sends `kill(-pgid, SIGKILL)` to each job with a stored `processGroupID` and `state == .filing`. This requires storing the PGID on `FilingJob` (see Discretion Item 2 above).

**Why `.terminateLater` is safe:** macOS enforces a hard quit timeout (system-defined, typically 5–20 seconds) after which it force-terminates the app regardless. Our 2-second grace + fast tempfile sweep completes well within this window. [CITED: developer.apple.com/documentation/appkit/nsapplicationdelegate/1428642-applicationshouldterminate]

### MCP Tempfile Sweep — Why `defer` Is Not Enough

`IssueFilingRunner.file` has `defer { try? FileManager.default.removeItem(at: tempURL) }` (line 147). This `defer` runs on all exit paths from the function (return, throw, Task cancellation). BUT: if the app process exits (e.g., from `applicationWillTerminate` advancing to actual termination), Swift `defer` blocks in in-progress Tasks do NOT run because the process is being torn down by the OS. The explicit sweep in `AppDelegate` is required for the quit path. [VERIFIED: code examination of IssueFilingRunner.swift lines 143–147; Swift defer-on-process-exit behavior is documented language behavior.]

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Kill whole process tree | Recursive `pgrep` + kill loop | `kill(-pgid, signal)` — POSIX group signal | Atomic, race-free, single syscall; process tree enumeration has TOCTOU races. |
| Observe Swift Task cancellation in callback-based code | Polling `Task.isCancelled` in a loop | `withTaskCancellationHandler` | Fires immediately on cancel, even when the Task is suspended at an await point. |
| Bounded async cleanup on quit | Custom timeout actor / semaphore | `applicationShouldTerminate` + `.terminateLater` + `Task` + `NSApp.reply` | System-provided hook with the correct lifecycle guarantees. |
| Tempfile sweep | Custom file registry with timestamps | `FileManager.contentsOfDirectory` + prefix/suffix filter | UUID-isolated names make a glob-delete safe; no registry to keep in sync. |

---

## Common Pitfalls

### Pitfall 1: SIGKILL Before SIGTERM — Leaked Docker Container

**What goes wrong:** Sending SIGKILL to the process group before SIGTERM means `docker run` is killed before it can tell the daemon to stop + remove the container. The container continues running as a detached daemon-managed container. `docker ps` shows it. `--rm` never fires.

**Why it happens:** `SIGKILL` cannot be caught or handled. `docker run` has no opportunity to call the Docker API to stop the container.

**How to avoid:** Always SIGTERM the process group first. Wait the grace window. Then SIGKILL only if the process is still running.

**Warning signs:** After a cancel, `docker ps` shows a `ghcr.io/github/github-mcp-server` container. `pgrep -f "github-mcp-server"` shows a process.

### Pitfall 2: `kill(pid, sig)` Instead of `kill(-pgid, sig)` — Orphaned claude

**What goes wrong:** Existing line 183 uses positive PID — kills only zsh. `claude` and `docker run` continue as orphans reparented to launchd. `pgrep -f claude` still shows the process.

**Why it happens:** POSIX: positive pid = kill that PID; negative pid = kill the process group. The distinction is one minus sign.

**How to avoid:** Always use `kill(-process.processIdentifier, signal)` for tree-wide signals. Verify with `pgrep` after cancel.

**Warning signs:** `pgrep -f claude` returns non-empty after a cancel.

### Pitfall 3: Double-Resume from Concurrent Claim Paths

**What goes wrong:** If the cancel `onCancel` handler also calls `state.claim()` and resumes the continuation, and the `terminationHandler` also fires (as it will), both claim, and Swift traps with `SWIFT TASK CONTINUATION MISUSE`.

**Why it happens:** The continuation is resumed twice.

**How to avoid:** The `onCancel` handler must ONLY kill the process. The `terminationHandler` (which fires when the process exits in response to SIGTERM) is the sole path through `state.claim()` → `continuation.resume()`. This exactly mirrors the existing timeout pattern (lines 158–186): the timeout Task claims BEFORE terminating; the cancel path lets the termination handler claim AFTER the process dies.

**Warning signs:** `SWIFT TASK CONTINUATION MISUSE` crash in tests or production.

### Pitfall 4: Missing `processGroupID` Storage — Quit-Time SIGKILL Skipped

**What goes wrong:** `AppDelegate.forceKillAllProcessTrees()` has no PIDs to SIGKILL. Processes that did not respond to SIGTERM survive the quit.

**Why it happens:** The PGID is available inside `CLIRunner.run` but not persisted to `FilingJob`.

**How to avoid:** Store `processGroupID: pid_t?` on `FilingJob`. Set it from `AppState.spawnFilingJob` via a callback from `IssueFilingRunner.file`.

### Pitfall 5: `withTaskCancellationHandler.onCancel` Fires Before `process.run()`

**What goes wrong:** Task is cancelled before `process.run()` completes. `pgid` is still 0. `onCancel` skips the kill (correct). But the process subsequently starts and runs without a kill signal. The job never transitions to `.cancelled`.

**Why it happens:** `onCancel` can fire before the subprocess is launched if the Task was already cancelled when `run` is called.

**How to avoid:** After `process.run()` writes `pgid`, synchronously check `Task.isCancelled` and send SIGTERM immediately if true. `try Task.checkCancellation()` in `IssueFilingRunner.file` also catches this at the next suspension point.

### Pitfall 6: `replyToApplicationShouldTerminate` Never Called — App Hangs on Quit

**What goes wrong:** If the `Task` in `applicationShouldTerminate` throws or exits without calling `NSApp.reply(...)`, the app hangs in a "Quit" state forever.

**Why it happens:** An unexpected error in the cleanup path skips the reply call.

**How to avoid:** Use `defer { NSApp.reply(toApplicationShouldTerminate: true) }` inside the Task body to guarantee the reply fires on all exit paths, including unexpected throws. `sweepMCPTempFiles` uses `try?` so it never throws.

---

## Code Examples

### Group-Wide Signal (replacing existing single-PID kill)

```swift
// Source: POSIX kill(2) — negative pid = signal process group
// Replaces: kill(process.processIdentifier, SIGKILL) at CLIRunner.swift line 183

// SIGTERM first (allows docker run to stop container + --rm)
kill(-process.processIdentifier, SIGTERM)

// SIGKILL escalation after grace (force-reap if SIGTERM was ignored)
// Only needed if process is still running
if process.isRunning {
    kill(-process.processIdentifier, SIGKILL)
}
```

### withTaskCancellationHandler Bridge Pattern

```swift
// Source: Swift Concurrency stdlib — withTaskCancellationHandler
// Used in CLIRunner.run to observe Task.cancel() while preserving RunState.claim() invariant

nonisolated(unsafe) var pgid: pid_t = 0

return await withTaskCancellationHandler(
    operation: {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                // ... existing drain + claim + resume logic ...
            }
            do {
                try process.run()
                pgid = process.processIdentifier   // set before checking isCancelled
                if Task.isCancelled { kill(-pgid, SIGTERM) }
            } catch { /* existing spawn-failure path */ }
            // ... existing timeoutTask ...
        }
    },
    onCancel: {
        let capturedPGID = pgid
        guard capturedPGID > 0 else { return }
        kill(-capturedPGID, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            kill(-capturedPGID, SIGKILL)
        }
    }
)
```

### IssueFilingRunner.file — CancellationError Surface

```swift
// Source: Swift stdlib — Task.checkCancellation()
// Add after CLIRunner().run(...) in IssueFilingRunner.file (~line 166)

let result = await CLIRunner().run(
    command: command,
    workingDirectory: repo.rootURL,
    environment: [config.tokenEnvKey: token],
    timeout: .seconds(300)
)

// Surface cancellation before interpreting the CLI result.
// defer { removeItem(tempURL) } runs even when this throws.
try Task.checkCancellation()   // throws CancellationError if task was cancelled

switch result { ... }          // unchanged
```

### AppState.spawnFilingJob — CancellationError Catch

```swift
// Source: project codebase pattern — AppState.swift
// Add before existing 'catch let filingError as IssueFilingError' arm

} catch is CancellationError {
    if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
        self.jobs[idx].state = .cancelled
    }
    self.announce("filing cancelled")   // D-05: defer-until-mic-idle (Phase 5 infrastructure)
} catch let filingError as IssueFilingError {
    // existing
```

### applicationShouldTerminate — Bounded Quit Teardown

```swift
// Source: AppKit — NSApplicationDelegate
// Add to AppDelegate.swift

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
```

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (already configured) |
| Config file | Package.swift (existing target `MakeAnIssueTests`) |
| Quick run command | `swift test --filter CLIRunnerTests` or `swift test --filter AppStateTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CANCEL-01 | `cancel(jobID:)` kills process group; `pgrep -f claude` empty afterwards | Integration (real subprocess) | `swift test --filter CLIRunnerTests.testCancelKillsProcessGroup` | ❌ Wave 0 |
| CANCEL-01 | No double-resume under cancel + natural-exit race | Unit | `swift test --filter CLIRunnerTests.testCancelAndExitBoundaryResolvesExactlyOnce` | ❌ Wave 0 |
| CANCEL-02 | Cancelled job reaches `.cancelled` state and speaks "filing cancelled" | Unit (stub filing) | `swift test --filter AppStateTests.testCancelJobIdTransitionsToCancel` | ❌ Wave 0 |
| CANCEL-02 | "filing cancelled" deferred when recording | Unit | `swift test --filter AppStateTests.testCancelAnnouncementDeferredDuringRecording` | ❌ Wave 0 |
| CANCEL-03 | `cancelAll()` + sweep removes tempfiles; `applicationShouldTerminate` replies | Unit + manual | `swift test --filter AppStateTests.testCancelAll` | ❌ Wave 0 |

**CANCEL-01 process-kill integration test note:** Testing `pgrep -f claude` requires a real `claude` process to be running, which is not feasible in CI. Instead, test with a long-running `sleep 60` command wrapped in a subprocess, cancel it, and assert the `sleep` subprocess is dead (via `kill(pid, 0)` returning `ESRCH`). This verifies the process-group kill mechanics without requiring the real `claude` binary.

### Sampling Rate

- **Per task commit:** `swift test --filter CLIRunnerTests`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green + manual `pgrep`/`docker ps` verification showing zero orphans

### Wave 0 Gaps

- [ ] `Tests/MakeAnIssueTests/CLIRunnerTests.swift` — add `testCancelKillsProcessGroup`, `testCancelAndExitBoundaryResolvesExactlyOnce`
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — add `testCancelJobId*`, `testCancelAll*`, `testCancelledJobStateAndAnnouncement`

---

## Security Domain

`security_enforcement: true`, `security_asvs_level: 1`, `security_block_on: high`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No — no new auth surfaces | — |
| V3 Session Management | No | — |
| V4 Access Control | No — cancel is internal API, not user-facing | — |
| V5 Input Validation | No — `jobID: UUID` is typed; no string parsing | — |
| V6 Cryptography | No | — |

### Known Threat Patterns for POSIX Signal Handling

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Signal sent to wrong process group (pgid=0 or app's own group) | Tampering | Guard `if capturedPGID > 0` before `kill(-pgid, signal)`; Foundation.Process ensures child is in its own group, not the parent's. |
| SIGKILL before SIGTERM leaves container running (resource leak) | Elevation of privilege (persistent container) | Enforce SIGTERM-first ordering; SIGKILL only after 2s grace. |
| Race: `applicationShouldTerminate` reply skipped — app hangs | Denial of service | `defer { NSApp.reply(toApplicationShouldTerminate: true) }` in cleanup Task guarantees reply. |

No new ASVS HIGH violations are introduced. The existing `--strict-mcp-config`, scoped `--allowedTools`, and token-in-environment protections are unchanged.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Foundation.Process (NSTask) places the spawned child in its own process group (PGID = child PID), so `kill(-process.processIdentifier, SIGTERM)` reaches zsh, claude, and docker run. | Discretion Item 1 | If the child inherits the parent's process group, `kill(-pgid, ...)` would signal the Swift app itself. Verify with `ps -o pid,pgid` before implementing. |
| A2 | zsh in non-interactive mode (`-lc`) does NOT create new process groups for commands it runs, so claude and docker run inherit zsh's PGID. | Discretion Item 1 | If zsh re-parents children into new process groups, each would need to be killed separately. Verify empirically. |
| A3 | 2-second grace window is sufficient for `docker run → SIGTERM → container stop → --rm removal`. | Discretion Item 3 | If container takes >2s to stop (e.g., heavy init), the SIGKILL fires before `--rm`, leaving a leaked container. Extend grace or measure actual stop latency. |
| A4 | `withTaskCancellationHandler.onCancel` fires synchronously when `task.cancel()` is called, even if the task is currently suspended in `withCheckedContinuation`. | Discretion Item 2 | If `onCancel` fires with a delay, the SIGTERM is delayed and docker has less time for cleanup. Mitigated by the SIGKILL-before-reply in `AppDelegate`. |
| A5 | The `nonisolated(unsafe) var pgid` race (onCancel reads 0 before process.run() writes it) is benign — the post-run `Task.isCancelled` check and `try Task.checkCancellation()` in IssueFilingRunner.file catch this case. | Discretion Item 2 | If both checks are omitted, a cancelled job where onCancel fired with pgid=0 would never kill the process and never transition to `.cancelled`. Risk is low with the two checks in place. |

---

## Open Questions

1. **Empirical verification of process group inheritance**
   - What we know: Strong circumstantial evidence that Foundation.Process creates a new process group for each spawned child; POSIX non-interactive shells inherit the parent's PGID.
   - What's unclear: Not directly confirmed via Apple documentation in this research session.
   - Recommendation: Wave 0 integration test — spawn a `sleep 60` subprocess, verify `ps -o pid,pgid` shows zsh PGID = zsh PID, then kill with `kill(-pgid, SIGTERM)` and verify sleep is also gone.

2. **PGID propagation to AppState — API shape**
   - What we know: `IssueFilingRunner.file` is a `static func`; it doesn't currently expose the process PID.
   - What's unclear: Cleanest way to surface the PGID to `AppState` for quit-time SIGKILL.
   - Recommendation: Add `onProcessStarted: ((pid_t) -> Void)? = nil` callback parameter to `IssueFilingRunner.file`. Called after `process.run()` with the PGID. `AppState.spawnFilingJob` injects a closure that sets `jobs[idx].processGroupID`. All existing call sites pass `nil` (source-compatible).

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Desktop | CANCEL-01 integration test (real process tree) | Assumed available on dev machine | — | Skip live docker test; test with `sleep` subprocess instead |
| `claude` CLI | CANCEL-01 end-to-end verification | Assumed available on dev machine | — | Use `sleep` subprocess as proxy for process-kill correctness test |

**Missing dependencies with no fallback:** None blocking Phase 6. Unit tests use stub filing seam (`onRunIssueFiling`) and do not require Docker or `claude`.

**Manual verification gate (Phase 6 success criterion):** Run the app, trigger a filing, cancel it mid-flight, then run `pgrep -f claude` and `docker ps` — both must return empty within the 2-second grace window.

---

## Sources

### Primary (code examination — HIGH confidence, source-cited)

- `Sources/MakeAnIssue/CLIRunner.swift` lines 32–59 (RunState.claim invariant), 82–92 (Process spawn), 158–186 (SIGTERM→SIGKILL timeout template)
- `Sources/MakeAnIssue/IssueFilingRunner.swift` lines 143–147 (MCP tempfile + defer), 161–166 (CLIRunner.run call site)
- `Sources/MakeAnIssue/AppState.swift` lines 260–292 (spawnFilingJob), 295–310 (announce/defer queue)
- `Sources/MakeAnIssue/FilingJob.swift` lines 8–36 (state enum + task handle)
- `Sources/MakeAnIssue/AppDelegate.swift` (existing delegate shell — no applicationShouldTerminate yet)
- `.planning/phases/06-cancellation-stop-control/06-CONTEXT.md` (locked decisions + canonical references)

### Secondary (web search — LOW confidence, cited where possible)

- [moby/moby#46749](https://github.com/moby/moby/issues/46749) — `docker run --rm` does not remove container when parent process is killed (SIGKILL vs SIGTERM distinction)
- [apple.com — applicationShouldTerminate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/1428642-applicationshouldterminate) — `.terminateLater` + `replyToApplicationShouldTerminate` pattern
- [jmmv.dev — Waiting for process groups, macOS edition](https://jmmv.dev/2019/11/wait-for-process-group-darwin.html) — macOS PGID behavior
- [Baeldung — docker stop vs kill](https://www.baeldung.com/ops/docker-stop-vs-kill) — SIGKILL cannot be forwarded by docker run
- Swift Forums / HackingWithSwift — `withTaskCancellationHandler` pattern for bridging continuation-based code

---

## Metadata

**Confidence breakdown:**
- Process group kill pattern: MEDIUM — reasoning from codebase + web sources; empirical verification recommended in Wave 0
- Docker `--rm` SIGTERM requirement: MEDIUM — confirmed via moby/moby#46749
- `withTaskCancellationHandler` bridge: MEDIUM — confirmed via Swift documentation references
- `applicationShouldTerminate` pattern: MEDIUM — confirmed via Apple developer documentation
- Grace window (2s): ASSUMED — matching existing code; validate empirically

**Research date:** 2026-06-29
**Valid until:** 2026-07-29 (APIs are stable; Docker `--rm` behavior is documented)
