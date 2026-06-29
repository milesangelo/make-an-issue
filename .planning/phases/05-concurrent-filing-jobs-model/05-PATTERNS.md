# Phase 5: Concurrent Filing Jobs Model - Pattern Map

**Mapped:** 2026-06-28
**Files analyzed:** 3 (1 new, 2 modified)
**Analogs found:** 3 / 3

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Sources/MakeAnIssue/FilingJob.swift` | model | event-driven | `Sources/MakeAnIssue/IssueResultParser.swift` (`IssueFilingResult`) + `IssueFilingConfig.swift` (`IssueFilingError`) | role-match |
| `Sources/MakeAnIssue/AppState.swift` | service/state-machine | event-driven | itself (existing `beginFiling()` Task at lines 257-296 is the analog to generalize) | exact |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | test | request-response | itself (existing seam-injection pattern, `waitUntil` helper, `makeRepo` helper at lines 683-699) | exact |

---

## Pattern Assignments

### `Sources/MakeAnIssue/FilingJob.swift` (NEW — model, event-driven)

**Analog:** `Sources/MakeAnIssue/IssueResultParser.swift` lines 4-10 for the result struct shape; `Sources/MakeAnIssue/IssueFilingConfig.swift` lines 97-108 for the error enum style.

**Model struct pattern** (IssueResultParser.swift lines 4-10):
```swift
struct IssueFilingResult {
    let number: Int
    let url: String
}
```
- Plain `struct`, no `class`
- `let` for immutable fields, `var` for mutable state
- No `import` needed for Foundation-only types; add `import Foundation` only for `UUID`

**Error enum pattern** (IssueFilingConfig.swift lines 97-108):
```swift
enum IssueFilingError: Error, Equatable {
    case tokenAcquisitionFailed
    case timeout
    case cliFailed(exitCode: Int32, stderr: String)
    case permissionDenied(tools: [String])
    case parseFailed
}
```
- `Error, Equatable` conformance — mirror for `FilingJobState`
- Typed associated values on failure cases

**New `FilingJob` struct pattern to write** (derived from the above + RESEARCH.md Pattern 1):
```swift
import Foundation

enum FilingJobState: Equatable {
    case filing
    case done
    case failed
    case cancelled   // Phase 6 forward-prep — mechanics owned by Phase 6
}

struct FilingJob: Identifiable {
    let id: UUID
    let transcript: String          // D-06: originating transcript (captured by value at spawn)
    let repo: RepoBinding           // D-06: bound repo at filing time
    var state: FilingJobState       // D-06
    var result: IssueFilingResult?  // D-06: set on success
    var error: IssueFilingError?    // D-06: set on failure
    var task: Task<Void, Never>?    // Phase 6 forward-prep — .cancel() hook
}
```
- `Identifiable` required for Phase 9's `ForEach` job list (JOBS-01) — add now
- `Task<Void, Never>?` is `Sendable`; stores cleanly in a `struct` under Swift 5.10 non-strict concurrency

---

### `Sources/MakeAnIssue/AppState.swift` (MODIFIED — service/state-machine, event-driven)

**Analog:** itself — the existing `beginFiling()` Task pattern (lines 257-296) is the direct template to generalize from 1→N.

#### A. `CaptureState` enum — remove `.filing` case

**Current** (AppState.swift lines 6-14):
```swift
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
    case finished
    case filing         // ← REMOVE
}
```

**Target** (remove `.filing`, optionally remove `.finished` per RESEARCH.md open question 1):
```swift
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
    // .finished and .filing removed — filing state now lives in FilingJob.state
}
```

#### B. New `@Published` jobs array and pending-announcement buffer — add to class body

**Pattern source:** existing `@Published` properties (AppState.swift lines 25-35):
```swift
@Published var statusText: String
@Published var captureState: CaptureState = .idle
@Published var transcript: String?
```

**Add to class body** (after existing `@Published` block):
```swift
/// Active and terminal filing jobs for this session. Retained per D-06/D-07.
@Published var jobs: [FilingJob] = []

/// Announcements deferred while captureState == .recording (D-02/D-03).
private var pendingAnnouncements: [String] = []
```

#### C. `spawnFilingJob(transcript:repo:)` — the generalized `beginFiling()` replacement

**Analog:** existing `beginFiling()` Task (AppState.swift lines 257-296):
```swift
private func beginFiling() {
    guard let repo = boundRepo else {
        statusText = "No repository bound — cannot file"
        captureState = .idle
        return
    }
    guard let transcript = transcript else {
        statusText = "No transcript available — cannot file"
        captureState = .idle
        return
    }
    captureState = .filing   // synchronous transition visible to callers

    Task {
        do {
            let result = try await onRunIssueFiling(transcript, repo)
            await MainActor.run {
                let text = "created issue #\(result.number)"
                if let onSpeak = self.onSpeak {
                    onSpeak(text)
                } else {
                    self.speak(text)
                }
                self.captureState = .idle
            }
        } catch let error as IssueFilingError {
            let message = Self.message(for: error)
            await MainActor.run {
                self.statusText = message
                self.captureState = .idle
            }
        } catch {
            let message = "Filing failed — \(error.localizedDescription)"
            await MainActor.run {
                self.statusText = message
                self.captureState = .idle
            }
        }
    }
}
```

**Write as** (generalizes the above to N concurrent jobs — RESEARCH.md Pattern 2):
```swift
@MainActor
private func spawnFilingJob(transcript: String, repo: RepoBinding) {
    let id = UUID()
    jobs.append(FilingJob(id: id, transcript: transcript, repo: repo, state: .filing))

    let task = Task { [weak self, id, transcript, repo] in
        guard let self else { return }
        do {
            let result = try await onRunIssueFiling(transcript, repo)
            // @MainActor-inherited Task — no MainActor.run needed after await
            if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                self.jobs[idx].state = .done
                self.jobs[idx].result = result
            }
            self.announce("created issue #\(result.number)")   // D-01
        } catch let filingError as IssueFilingError {
            if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                self.jobs[idx].state = .failed
                self.jobs[idx].error = filingError
            }
            self.announce("issue filing failed")   // D-04
        } catch {
            if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                self.jobs[idx].state = .failed
            }
            self.announce("issue filing failed")   // D-04
        }
    }

    // Store task handle for Phase 6 cancellation (forward-prep)
    if let idx = jobs.firstIndex(where: { $0.id == id }) {
        jobs[idx].task = task
    }
}
```

Key differences from `beginFiling()`:
- Receives `transcript` and `repo` as value parameters — NOT read from `self.transcript`/`self.boundRepo` inside the Task (Pitfall 1 in RESEARCH.md)
- Uses `[weak self, id, transcript, repo]` capture list (Pitfall 4)
- No `captureState = .filing` — that case no longer exists
- No `await MainActor.run {}` inside the Task — `@MainActor` isolation is inherited (Pitfall 2)
- Routes TTS through `announce()` not directly to `onSpeak`/`speak()`

#### D. `announce(_:)` + `flushPendingAnnouncements()` helpers — RESEARCH.md Pattern 3

**Pattern source:** existing `onSpeak` seam routing (AppState.swift lines 275-279):
```swift
if let onSpeak = self.onSpeak {
    onSpeak(text)
} else {
    self.speak(text)
}
```

**Write as three helpers** (RESEARCH.md Pattern 3):
```swift
private func announce(_ text: String) {
    if captureState == .recording {
        pendingAnnouncements.append(text)
    } else {
        speakText(text)
    }
}

private func flushPendingAnnouncements() {
    let pending = pendingAnnouncements
    pendingAnnouncements = []
    for text in pending {
        speakText(text)
    }
}

/// Routes through onSpeak seam — preserves test injection (no real TTS in tests).
private func speakText(_ text: String) {
    if let onSpeak = onSpeak {
        onSpeak(text)
    } else {
        speak(text)
    }
}
```

#### E. `beginTranscription()` success path — replace `.finished` + `beginFiling()` chain

**Current** (AppState.swift lines 226-232):
```swift
await MainActor.run {
    self.transcript = text
    NSLog("MakeAnIssue transcript: \(text)")
    // .finished is transient — immediately flow into filing
    self.captureState = .finished
    self.beginFiling()
}
```

**Write as:**
```swift
self.transcript = text
NSLog("MakeAnIssue transcript: \(text)")
self.captureState = .idle   // D-08: capture returns to idle immediately
if let repo = self.boundRepo {
    self.spawnFilingJob(transcript: text, repo: repo)
} else {
    self.statusText = "No repository bound — cannot file"
}
```

Note: This is already in a `Task { }` body that inherits `@MainActor`, so no `await MainActor.run {}` wrapper is needed.

#### F. `beginTranscription()` opening — add flush call

**Current** (AppState.swift lines 213-215):
```swift
private func beginTranscription() {
    captureState = .transcribing
    transcriptError = nil
```

**Write as** (RESEARCH.md Pattern 3, flush call site rationale):
```swift
private func beginTranscription() {
    captureState = .transcribing
    flushPendingAnnouncements()   // D-02/D-03: drain announcements deferred during .recording
    transcriptError = nil
```

Flush placed here (not in `stopRecording()`) because `recordingDidTimeout()` also calls `beginTranscription()` directly — both paths are covered without duplication.

#### G. `startRecording()` guard comment update

**Current** (AppState.swift lines 174-179):
```swift
// Only allow starting from .idle. This blocks re-entry during .recording
// (D-04: ignore key repeats), .transcribing, and .filing (CR-01: a PTT
// press during the up-to-300 s filing window must not start a new capture
// and corrupt the in-flight state machine). .finished is transient and
// flows straight into .filing, so it is also correctly excluded here.
guard captureState == .idle else { return }
```

**Update comment only** — guard code is unchanged, its meaning changes because `.filing` no longer exists in `captureState`:
```swift
// Only allow starting from .idle. This blocks re-entry during .recording
// (D-04: ignore key repeats) and .transcribing. Under the jobs model,
// filings run concurrently in the background and do not block PTT (D-09).
guard captureState == .idle else { return }
```

---

### `Tests/MakeAnIssueTests/AppStateTests.swift` (MODIFIED — test, request-response)

**Analog:** itself — existing seam-injection test pattern and `waitUntil` helper.

#### Existing seam-injection pattern to mirror for all new tests

**Pattern source:** AppStateTests.swift lines 426-452 (`testSuccessfulFilingSpeaksIssueNumber`):
```swift
func testSuccessfulFilingSpeaksIssueNumber() async throws {
    let repoURL = try makeRepo(named: "speak-repo")
    let binding = RepoBinding(rootURL: repoURL, displayName: "speak-repo", displayPath: repoURL.path)
    var spokenText: String?
    let state = AppState(
        boundRepo: binding,
        boundRepoDisplayText: "speak-repo",
        onStartRecording: { true },
        onStopRecording: {},
        onRunTranscription: { _ in "create issue" },
        onRunIssueFiling: { _, _ in
            IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42")
        },
        onSpeak: { text in spokenText = text }
    )
    state.micPermissionGranted = true
    state.startRecording()
    state.stopRecording()

    await waitUntil { spokenText != nil }

    XCTAssertNotNil(spokenText)
    XCTAssertTrue(spokenText?.contains("42") == true, ...)
}
```

All new tests follow exactly this structure: designated init with all seams injected, `micPermissionGranted = true`, start/stop recording, `await waitUntil { condition }`, then assertions.

#### `waitUntil` helper — use unchanged

**Source:** AppStateTests.swift lines 682-693:
```swift
@discardableResult
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
```

`waitUntil` is sufficient for all new concurrency tests — no new test infrastructure needed.

#### `makeRepo` helper — use unchanged

**Source:** AppStateTests.swift lines 695-699:
```swift
private func makeRepo(named name: String) throws -> URL {
    let repo = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    return repo
}
```

#### Tests to REWRITE (existing tests that break under D-08/D-09)

**`testFilingEntersFilingState`** (lines 603-639) — rewrite:
- Remove: `await waitUntil { state.captureState == .filing }` — `.filing` no longer exists in `captureState`
- Write: after transcription seam completes, assert `state.captureState == .idle && state.jobs.count == 1 && state.jobs[0].state == .filing` while the slow `onRunIssueFiling` seam is still in-flight
- `waitUntil` condition: `state.jobs.count == 1` (jobs array populated when spawnFilingJob is called)

**`testPushToTalkDuringFilingIsIgnored`** (lines 641-675) — rewrite as "PTT during filing is NOW ALLOWED":
- Remove: all assertions that `captureState` stays `.filing` during re-entry
- Write: while `state.jobs[0].state == .filing`, call `state.startRecording()` and assert `state.captureState == .recording` (re-entry is now allowed per D-09); assert `state.jobs.count == 2` after second transcription

**`testStartRecordingAfterFilingReturnsToIdleStartsNewRecording`** (lines 113-132) — verify still passes:
- This test already waits for `captureState == .idle` before the second `startRecording()`; it has no `boundRepo` so `spawnFilingJob` is never called; behavior unchanged

**`.filing` assertion in `testSuccessfulTranscriptionStoresText`** (lines 312-337) — currently no direct `.filing` assertion but does use `onRunIssueFiling` seam; verify still passes after refactor since it already asserts `captureState == .idle` as the final state

#### New test patterns (from RESEARCH.md Validation Architecture)

**Pattern for in-flight job observation** (for CONCUR-01, CONCUR-02 tests):
```swift
// Use a slow onRunIssueFiling seam with a continuation to hold the job in-flight
let filingStarted = AsyncStream<Void>.makeStream()
let state = AppState(
    ...
    onRunIssueFiling: { _, _ in
        filingStarted.continuation.yield(())
        try? await Task.sleep(for: .milliseconds(500))
        return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
    }
)
```

**Pattern for concurrent job spawning** (for CONCUR-02 tests):
```swift
// Two full record/transcribe/file cycles with a slow seam
state.startRecording(); state.stopRecording()
await waitUntil { state.jobs.count == 1 }
state.startRecording(); state.stopRecording()
await waitUntil { state.jobs.count == 2 }
XCTAssertEqual(state.jobs[0].transcript, "first transcript")
XCTAssertEqual(state.jobs[1].transcript, "second transcript")
```

**Pattern for defer/flush tests** (for D-02/D-03 tests):
```swift
// Hold state in .recording while a job completes — check onSpeak NOT called
var spokenTexts: [String] = []
let state = AppState(
    ...
    onRunIssueFiling: { _, _ in
        IssueFilingResult(number: 1, url: "...")
    },
    onSpeak: { text in spokenTexts.append(text) }
)
state.micPermissionGranted = true
state.startRecording()   // captureState = .recording
// Manually trigger spawnFilingJob while in .recording to test deferral
// (use a second start/stop cycle that returns from transcription while first is .recording)
```

---

## Shared Patterns

### Seam routing for TTS (apply to `speakText` helper and all `announce()` call sites)

**Source:** AppState.swift lines 275-279 (existing pattern in `beginFiling()`):
```swift
if let onSpeak = self.onSpeak {
    onSpeak(text)
} else {
    self.speak(text)
}
```

**Apply to:** `speakText(_:)` helper — consolidates this check in one place instead of repeating it at each TTS call site.

### `Task { [weak self] in guard let self else { return } }` closure pattern

**Source:** AppState.swift lines 154-161 (startup mic permission task):
```swift
Task { [weak self] in
    let granted = await AppState.requestMicrophonePermission()
    if granted {
        self?.micPermissionGranted = true
    } else {
        self?.statusText = "..."
    }
}
```

**Apply to:** `spawnFilingJob` Task closure — use `[weak self, id, transcript, repo]` capture list. `transcript` and `repo` captured by value prevent stale-`self.transcript` read (Pitfall 1 in RESEARCH.md).

### Error catch hierarchy in Task body (apply to `spawnFilingJob`)

**Source:** AppState.swift lines 282-295 (existing `beginFiling()` catch structure):
```swift
} catch let error as IssueFilingError {
    let message = Self.message(for: error)
    await MainActor.run { self.statusText = message; self.captureState = .idle }
} catch {
    let message = "Filing failed — \(error.localizedDescription)"
    await MainActor.run { self.statusText = message; self.captureState = .idle }
}
```

**Apply to:** `spawnFilingJob` Task — keep same two-catch hierarchy (`IssueFilingError` first, generic `Error` second). Replace `captureState = .idle` mutations with `jobs[idx].state = .failed` + `announce("issue filing failed")`.

---

## No Analog Found

All files have close analogs. No entries.

---

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/`, `Tests/MakeAnIssueTests/`
**Files scanned:** 4 source files read in full
**Pattern extraction date:** 2026-06-28
