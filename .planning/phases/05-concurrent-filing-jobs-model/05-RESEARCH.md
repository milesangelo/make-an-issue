# Phase 5: Concurrent Filing Jobs Model - Research

**Researched:** 2026-06-28
**Domain:** Swift structured concurrency · `@MainActor` jobs model · AVSpeechSynthesizer queuing
**Confidence:** MEDIUM

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Spoken success text stays `"created issue #N"` — unchanged.
- **D-02:** Confirmations (and failures) MUST be deferred until the mic is idle; held in a pending-announcement queue and spoken when recording stops.
- **D-03:** Defer gate is `.recording` only. Multiple accumulated announcements fire back-to-back when recording stops.
- **D-04:** Failed background filing MUST speak a brief generic `"issue filing failed"`. Updates v1.0 success-only TTS contract.
- **D-05:** No per-type spoken failure reason in Phase 5; one phrase covers all failures.
- **D-06:** Jobs model retains terminal jobs (done/failed/cancelled). Each job stores: stable id, originating transcript, bound repo, state, outcome.
- **D-07:** Retained terminal jobs live in session memory only; no persistence across launches.
- **D-08:** `captureState` loses its `.filing` case. Capture transitions: recording → transcribing → idle. On successful transcription, spawn a filing job and return capture to `.idle` immediately.
- **D-09:** PTT re-entry guard changes meaning: re-pressing PTT while filings are in flight is NOW ALLOWED. Guard prevents only overlapping recordings.

### Claude's Discretion

- Where the jobs collection lives (`@Published var jobs` on `AppState` vs. dedicated manager/actor).
- Whether to keep a cancellation handle on each job now (Phase 6 forward-prep) or add it in Phase 6.
- The pending-announcement queue's exact implementation — a simple buffer flushed on `.recording → .idle` is sufficient.

### Deferred Ideas (OUT OF SCOPE)

- Enriched confirmations (repo name / title snippet in spoken text).
- Per-type spoken failure reasons — Phase 9 (RESIL-01).
- Dismiss / clear-completed / cancel-all — Phase 9.
- Cross-launch job history — out of scope for v1.1.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CONCUR-01 | After transcription completes, app returns to idle immediately so user can start new recording without waiting for filing | D-08 analysis: remove `.filing` from `captureState`; `beginTranscription()` success path sets `captureState = .idle` then spawns a background `Task` |
| CONCUR-02 | Multiple issue filings run concurrently — second/third can be in flight while first is still filing | Each transcription cycle spawns an independent `Task`; `AppState.jobs` grows to N entries; no task group or concurrency limit needed |
| CONCUR-03 | Each filing independently speaks its own "created issue #N" confirmation when it completes | Per-job `announce()` call on completion; pending-announcement queue defers if mic is recording; AVSpeechSynthesizer enqueues utterances in order |
</phase_requirements>

---

## Summary

Phase 5 is a pure Swift refactor of the existing serial filing pipeline. The v1.0 code has one `Task` that fires when `beginFiling()` is called and blocks `captureState` in `.filing` until done. Phase 5 generalizes this to N concurrent `Task` objects, each tracking an independent filing job, and removes `.filing` from the `captureState` enum entirely.

The key insight is that the existing `beginFiling()` method already has exactly the right skeleton — a `Task { do { let result = try await onRunIssueFiling(...) await MainActor.run { ... } } catch { ... } }` — and the jobs model is simply this pattern repeated N times with jobs tracked in a `@Published` array. No new concurrency primitives are needed.

The two areas requiring new design are: (1) the `FilingJob` model type with a `Task` handle stored per-job (Phase 6 forward-prep), and (2) the pending-announcement buffer that defers TTS during `.recording` and flushes it when the mic stops.

Success criterion 4 (per-invocation MCP tempfile isolation) is satisfied by construction — `IssueFilingRunner.file()` already creates a UUID-named tempfile and deletes it via `defer` on every exit path. Concurrent calls each get a distinct UUID; no change is needed.

**Primary recommendation:** Keep `@Published var jobs: [FilingJob]` directly on `AppState` (the existing `@MainActor` class). Store `Task<Void, Never>?` per job for Phase 6 forward-prep. Use a `private var pendingAnnouncements: [String]` buffer flushed from `stopRecording()`. Rename `beginFiling()` → `spawnFilingJob(transcript:repo:)`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Jobs collection & state mutations | `@MainActor` AppState | — | All `@Published` state for SwiftUI observation must be main-actor; no benefit from a separate actor when every mutation ends up back on main actor anyway |
| Concurrent filing work (I/O) | Background (inherited `@MainActor` Task) | — | `Task { }` spawned from `@MainActor` suspends on `await` and runs async I/O off the main thread; `@MainActor` mutations happen only at suspension points |
| Per-invocation MCP tempfile | `IssueFilingRunner.file()` (called from background Task) | — | Unchanged from v1.0; UUID isolation is in `IssueFilingRunner`, not in the jobs model |
| Pending-announcement queue | `@MainActor` AppState | — | Queue is read/written only from `@MainActor` context (job completion Task body, `stopRecording()`) |
| TTS delivery | `@MainActor` AppState (`speak()`) | — | `AVSpeechSynthesizer` is a stored property on `AppState`; all calls must be on main thread |
| Capture state machine | `@MainActor` AppState | — | Unchanged ownership; `.filing` case removed; idle immediately after transcription |

---

## Standard Stack

This phase installs **no new packages**. It is a pure Swift refactor of existing code.

### Existing Dependencies (unchanged)

| Library | Version | Purpose | Notes |
|---------|---------|---------|-------|
| Swift stdlib (structured concurrency) | 5.10 (Package.swift) | `Task`, `Task.cancel()`, `@MainActor` | Already in use |
| AVFoundation (`AVSpeechSynthesizer`) | macOS 13+ | TTS delivery | Already a stored property on `AppState` |
| XCTest | macOS 13+ | Unit testing | `AppStateTests.swift` pattern reused |
| KeyboardShortcuts | 3.0.1 | PTT shortcut | Unchanged |

### Package Legitimacy Audit

> **Not applicable** — Phase 5 installs zero external packages. This section is included for completeness.

**Packages removed due to SLOP verdict:** none  
**Packages flagged as suspicious (SUS):** none

---

## Architecture Patterns

### System Architecture Diagram

```
PTT key-down ──→ startRecording()
                   captureState = .recording
                        │
PTT key-up ─────→ stopRecording()
                   onStopRecording()
                   flushPendingAnnouncements()   ← NEW: drain buffer before transcribing
                   beginTranscription()
                   captureState = .transcribing
                        │
                   onRunTranscription(wavURL) [async, suspends]
                        │
                   transcript set
                   captureState = .idle          ← CHANGED: was .finished → .filing
                   spawnFilingJob(transcript, repo)
                        │
                   jobs.append(FilingJob(id:, state:.filing, …))
                   Task { [id] in                ← N concurrent Tasks possible
                     let r = try await onRunIssueFiling(transcript, repo)
                     jobs[idx].state = .done/.failed
                     jobs[idx].result = r
                     announce("created issue #N" or "issue filing failed")
                   }
                        │
                   announce(text):
                     captureState == .recording → pendingAnnouncements.append(text)
                     otherwise               → speak(text) immediately

                   ─ while first job is in-flight ─
PTT key-down ──→ startRecording()   ← ALLOWED (D-09: guard only blocks recording-on-recording)
                   captureState = .recording
                        │
PTT key-up ─────→ stopRecording()
                   flushPendingAnnouncements()   ← fires any announcement from job 1
                   … second job spawned, jobs.count == 2
```

### Recommended Project Structure (additions only)

```
Sources/MakeAnIssue/
├── AppState.swift           # Modified: remove .filing, add jobs array, spawnFilingJob, announce, pending queue
├── FilingJob.swift          # NEW: FilingJob struct + FilingJobState enum
├── IssueFilingRunner.swift  # Unchanged
├── IssueFilingConfig.swift  # Unchanged
├── IssueResultParser.swift  # Unchanged
└── …                        # All other files unchanged
```

### Pattern 1: `FilingJob` Model Type

**What:** A value type (`struct`) carrying all per-job state, stored in a `@Published` array on `@MainActor AppState`.

**When to use:** Any `@Published` array on a `@MainActor` class. `struct` elements are mutated by index reference (`jobs[idx].state = .done`) within the main actor context — safe and idiomatic.

```swift
// Source: derived from Swift stdlib Task docs + existing AppState patterns
// [ASSUMED] — struct design; Swift Task<Void,Never> storage is [CITED: swiftlang/swift docs]

enum FilingJobState: Equatable {
    case filing
    case done
    case failed
    case cancelled   // Phase 6 mechanics; model shape established here
}

struct FilingJob: Identifiable {
    let id: UUID
    let transcript: String       // D-06: originating transcript
    let repo: RepoBinding        // D-06: bound repo at filing time
    var state: FilingJobState    // D-06
    var result: IssueFilingResult? // D-06: set on success
    var error: IssueFilingError?   // D-06: set on failure
    var task: Task<Void, Never>?   // Phase 6 forward-prep — .cancel() hook
}
```

**Why `struct` (not `class`):** Consistent with `IssueFilingResult`, `RepoBinding`, and all other model types in the project. `Task<Void, Never>` is `Sendable` and stores cleanly in a `struct`. Array-element mutation by index is the idiomatic Swift pattern for `@Published` struct arrays.

**`Identifiable` conformance:** Required for Phase 9's ForEach job list (JOBS-01). Add now to avoid a model rework later.

### Pattern 2: Spawning Filing Jobs from `@MainActor`

**What:** `spawnFilingJob(transcript:repo:)` replaces `beginFiling()`. Called from the transcription success path.

**Key property:** A `Task { }` spawned from a `@MainActor` context inherits `@MainActor` isolation. The task body runs on the main actor at `@MainActor` suspension points (i.e., between `await` calls). This means mutations to `self.jobs` inside the task body do NOT need `await MainActor.run {}` — they are already main-actor-isolated. [CITED: swiftlang/swift-migration-guide DataRaceSafety.md]

```swift
// Source: generalizes existing beginFiling() Task pattern in AppState.swift line ~270
// [ASSUMED] — specific implementation; pattern is [CITED: swiftlang/swift-migration-guide]

@MainActor
private func spawnFilingJob(transcript: String, repo: RepoBinding) {
    let id = UUID()
    // 1. Append job to array first (Task body sees it immediately on first await)
    jobs.append(FilingJob(id: id, transcript: transcript, repo: repo, state: .filing))

    // 2. Spawn Task — inherits @MainActor isolation from calling context
    let task = Task {
        do {
            let result = try await onRunIssueFiling(transcript, repo)
            // Back on @MainActor after await — no MainActor.run needed
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                jobs[idx].state = .done
                jobs[idx].result = result
            }
            announce("created issue #\(result.number)")   // D-01
        } catch let filingError as IssueFilingError {
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                jobs[idx].state = .failed
                jobs[idx].error = filingError
            }
            announce("issue filing failed")   // D-04
        } catch {
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                jobs[idx].state = .failed
            }
            announce("issue filing failed")   // D-04
        }
    }

    // 3. Store task handle for Phase 6 cancellation (forward-prep)
    if let idx = jobs.firstIndex(where: { $0.id == id }) {
        jobs[idx].task = task
    }
}
```

**Integration point:** In `beginTranscription()`'s success path (AppState.swift line ~229), replace:
```swift
self.captureState = .finished
self.beginFiling()
```
with:
```swift
self.captureState = .idle
if let repo = self.boundRepo, let transcript = self.transcript {
    self.spawnFilingJob(transcript: transcript, repo: repo)
}
// else: no repo → status message already surfaced by earlier guard, captureState already .idle
```

### Pattern 3: Pending-Announcement Queue (D-02/D-03)

**What:** A simple `[String]` buffer on `AppState`. Announcements are deferred only during `.recording`; all other states allow immediate TTS.

**Flush trigger:** The transition out of `.recording` (when the user releases PTT or the recording timeout fires). This is the right trigger because D-03 says "the mic is off during transcription/filing, so those states do not need to suppress speech."

```swift
// Source: [ASSUMED] — pattern derived from D-02/D-03 decisions in CONTEXT.md

// On AppState (@MainActor)
private var pendingAnnouncements: [String] = []

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
        speakText(text)   // routes through onSpeak seam or real speak()
    }
}

// Private helper to route through onSpeak seam (preserves test injection)
private func speakText(_ text: String) {
    if let onSpeak = onSpeak {
        onSpeak(text)
    } else {
        speak(text)
    }
}
```

**Flush call site:** Add `flushPendingAnnouncements()` at the START of `beginTranscription()` (after setting `captureState = .transcribing`), NOT inside `stopRecording()`. Reason: `recordingDidTimeout()` also calls `beginTranscription()` directly — placing the flush there covers both the normal key-up path and the cap-exceeded path without duplication.

**Revised `beginTranscription()` opening:**
```swift
private func beginTranscription() {
    captureState = .transcribing
    flushPendingAnnouncements()   // ← NEW: drain any announcements deferred during .recording
    transcriptError = nil
    // … rest unchanged
}
```

**AVSpeechSynthesizer ordering note:** Multiple `speakText()` calls from `flushPendingAnnouncements()` are synchronous (a for loop on the main actor) and call `speechSynthesizer.speak(utterance)` on the single stored instance in sequence. Apple's documentation states utterances are enqueued in order on a single synthesizer instance. The simplest approach (sequential `speak()` calls) should produce sequential audio. [CITED: developer.apple.com/documentation/avfaudio/avspeechsynthesizer]

> **Planner note:** Empirically verify that calling `speak()` 2-3 times in rapid succession on a single stored `AVSpeechSynthesizer` produces sequential audio output on macOS 13 and 14. If ordering is unreliable, fall back to the delegate pattern: `AVSpeechSynthesizerDelegate.speechSynthesizer(_:didFinish:)` can dequeue and speak the next pending announcement. Implementation is straightforward but adds ~20 lines; do not add the delegate complexity speculatively. [ASSUMED — ordering reliability on recent macOS is UNCONFIRMED from search results]

### Pattern 4: `captureState` Enum Simplification (D-08)

**Remove `.filing` case.** The enum reduces from 5 cases to 4:

```swift
// BEFORE (AppState.swift lines 6-14)
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
    case finished
    case filing         // ← REMOVE
}

// AFTER
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
    case finished       // kept: transient state after transcription succeeds, before idle
}
```

> **Note on `.finished`:** The v1.0 code uses `.finished` as a transient state that "immediately chains into `beginFiling()`" (AppState.swift line ~229 comment). Under the jobs model, `.finished` still appears briefly in `beginTranscription()`'s success path, but the chain is now `→ .finished → captureState = .idle` followed by `spawnFilingJob()`. Alternatively, `.finished` can be eliminated by setting `captureState = .idle` directly without the intermediate state. The choice is the planner's. If `.finished` is retained, the tests that assert on `.finished` remain unchanged; if removed, those tests also change. Consider removing `.finished` to simplify the enum to 3 cases (idle/recording/transcribing) — it was only meaningful as a signal to `beginFiling()`, which no longer exists. [ASSUMED — whether to keep or remove `.finished` is a planner design call]

### Pattern 5: PTT Re-Entry Guard Change (D-09)

**Before:**
```swift
// AppState.swift line ~179 — blocks ALL non-idle states including .filing
guard captureState == .idle else { return }
```

**After:**
```swift
// D-09: guard only blocks recording-on-recording and recording-during-transcription;
// in-flight filings no longer block a new recording
guard captureState == .idle else { return }
```

The guard is unchanged in code — it only changed in *meaning*. Previously `.filing` was a `captureState` case that triggered the guard; under the jobs model `.filing` no longer exists in `captureState`, so `.idle` is correctly reachable while jobs are in flight. The only change needed is removing `.filing` from the `CaptureState` enum. No guard logic changes required.

### Anti-Patterns to Avoid

- **Spawning `Task.detached { }` instead of `Task { }`:** A detached task does NOT inherit `@MainActor` isolation. Mutations to `jobs` inside a detached task body would require `await MainActor.run {}` on every mutation. Use unstructured `Task { }` (inherits actor isolation). [CITED: swiftlang/swift/stdlib/task.md]
- **Multiple `AVSpeechSynthesizer` instances:** Each synthesizer plays independently. Using more than one synthesizer causes announcements to overlap. The stored `speechSynthesizer` property is the single authoritative instance. [CITED: developer.apple.com/forums/thread/651832]
- **Clearing completed jobs on completion:** D-07 requires retention; jobs must accumulate in the array for the session. Do NOT `jobs.removeAll(where: { $0.state != .filing })` after a job finishes. Phase 9 owns dismiss/clear.
- **Setting `captureState = .filing` at any point:** `.filing` is removed from the enum. The filing state is now per-job in `FilingJob.state`, not in the capture state machine.
- **Accessing `self.transcript` inside the spawned Task body:** The Task body captures `transcript` as a local constant (passed by value to `spawnFilingJob(transcript:repo:)`) rather than reading `self.transcript`. This is correct — by the time a second job is spawned, `self.transcript` will have been overwritten with the new transcription. Always capture `transcript` from the function parameter, not from `self`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Per-invocation MCP config isolation | Custom UUID/file manager | `IssueFilingRunner.file()` — already does this | The `defer` + UUID pattern in `IssueFilingRunner.swift` lines ~143-147 is correct and complete; verified by construction |
| Concurrent filing scheduler / rate limiter | Custom queue or semaphore | None — unbounded concurrency is the spec | REQUIREMENTS.md Out-of-Scope: "no concurrency-limit scheduler". Each `Task { }` is independent |
| Announcement ordering mechanism | Custom serial queue or actor | Single `AVSpeechSynthesizer` stored property + sequential `speak()` calls | AVSpeechSynthesizer enqueues utterances in order on a single instance |
| Cross-call state sharing between jobs | Shared mutable state | UUID per job + independent `Task` closure | Each job captures `transcript`, `repo`, and `id` by value at spawn time |

**Key insight:** The hard parts (per-invocation isolation, async subprocess management, token acquisition) are already solved in `IssueFilingRunner.file()`. The jobs model is a thin coordination layer on top.

---

## Runtime State Inventory

> This section is included because Phase 5 involves a meaningful refactor (removing `.filing` from `captureState`), but it is NOT a rename/rebrand phase — no stored strings change. Runtime state impact is minimal.

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | None — `captureState` is in-memory only; no UserDefaults or disk storage | Code edit only |
| Live service config | None — no external services track `captureState` | None |
| OS-registered state | None — `.filing` is not registered with the OS | None |
| Secrets/env vars | None — `GITHUB_PERSONAL_ACCESS_TOKEN` key name unchanged | None |
| Build artifacts | None — no .egg-info or cached binary names change | None |

**Nothing found in any category that requires data migration.** The `.filing` case removal is a pure code change; no runtime state carries the string "filing" externally.

---

## Common Pitfalls

### Pitfall 1: Capturing `self.transcript` by Reference Inside the Task Body

**What goes wrong:** The filing job Task closure reads `self.transcript` inside its body. By the time the task runs (or before the first `await` suspends), the user may have completed a second transcription, overwriting `self.transcript`. The second job then receives the same transcript as the first, or the first job's filing uses the wrong transcript.

**Why it happens:** `Task { }` closures capture `self` (or `[weak self]`) by reference. `self.transcript` is mutated on every successful transcription.

**How to avoid:** `spawnFilingJob(transcript:repo:)` receives `transcript` as a `let` parameter. The Task body closes over this local constant — not `self.transcript`. Verified by passing transcript as a function argument rather than reading `self.transcript` inside the Task.

**Warning signs:** Test `testMultipleConcurrentFilingJobsHaveDistinctTranscripts` failing, or both jobs receiving the same transcript string.

### Pitfall 2: `await MainActor.run {}` Inside a `@MainActor`-Inherited Task

**What goes wrong:** Developer adds `await MainActor.run { self.jobs[idx].state = .done }` inside the spawned Task, introducing an unnecessary actor hop that obscures the fact the task is already main-actor-isolated.

**Why it happens:** The v1.0 `beginFiling()` Task uses `await MainActor.run` (AppState.swift lines ~273, ~283). This was a safe guard in case the task was ever not on the main actor. With the `@MainActor` class and `Task { }` inheriting isolation, it is redundant.

**How to avoid:** Task spawned from `@MainActor` context inherits main actor isolation. Mutations to `self.jobs` after `await onRunIssueFiling(...)` returns are already on the main actor. Use direct `self.jobs[idx].state = .done` without `await MainActor.run`. If keeping `await MainActor.run` for defensive clarity, it is harmless (no-op hop), but adds verbosity.

**Warning signs:** Compiler warning or strict-concurrency error about redundant `@MainActor` crossing.

### Pitfall 3: AVSpeechSynthesizer Utterance Ordering Unreliability

**What goes wrong:** Calling `speak()` 2-3 times in rapid succession (during `flushPendingAnnouncements()`) results in utterances playing out of order or simultaneously on recent macOS versions.

**Why it happens:** Some community reports indicate the single-synthesizer sequential-queue guarantee may be unreliable in recent macOS/iOS releases. [ASSUMED — unconfirmed via official docs]

**How to avoid:** Empirically verify on macOS 13 and 14 that 3 rapid `speak()` calls on the stored synthesizer produce sequential audio. If ordering is wrong, implement `AVSpeechSynthesizerDelegate` and chain calls via `speechSynthesizer(_:didFinish:)` callback. For the typical case (0-1 deferred announcements per flush), ordering is moot — this only matters when 2+ filings complete during a single recording hold.

**Warning signs:** TTS announces "issue filing failed" and "created issue #42" simultaneously rather than sequentially.

### Pitfall 4: Missing `[weak self]` or `[id]` Capture in Task Closure

**What goes wrong:** Task closure captures `self` strongly, creating a retain cycle through the `jobs` array (each job's `task` property holds a `Task` that holds a strong ref to `AppState`). `AppState` is never released.

**Why it happens:** `Task { ... }` without `[weak self]` in a `@MainActor final class` retains `self` for the task lifetime.

**How to avoid:** Use `Task { [weak self, id] in ... guard let self else { return } ... }` or capture only the specific values needed. Since `transcript` and `repo` are passed as local constants to `spawnFilingJob`, they can be captured by value: `Task { [id, transcript, repo] in ... }` with `await MainActor.run { [weak self] in ... }` for the mutation step. The existing `beginFiling()` pattern (line ~271) does NOT use `[weak self]`, which is likely safe since AppState lives for the process lifetime — but correct practice is to use `[weak self]` to allow deallocation in tests that create many AppState instances.

**Warning signs:** AppStateTests leak memory; tests with many AppState instances show increasing heap use.

### Pitfall 5: `.finished` → `.idle` vs Direct `.idle` Transition

**What goes wrong:** If `.finished` is retained and `captureState` briefly flashes to `.finished` before `spawnFilingJob()` is called, a PTT key-down event arriving in that window is blocked by `guard captureState == .idle else { return }`, dropping the user's press.

**Why it happens:** The existing code uses `.finished` as a synchronous intermediate state before `beginFiling()`. Under the jobs model, the transition chain is synchronous: `.finished` → `.idle` in the same `await MainActor.run` block, so the window is zero in practice (no suspension between the two assignments). But if any `await` is introduced between `.finished` and `.idle`, the window opens.

**How to avoid:** Set `captureState = .idle` directly (skipping `.finished`) in the transcription success path before calling `spawnFilingJob()`. Or, set both `.finished` and `.idle` synchronously without any `await` between them. Consider removing `.finished` entirely from the enum.

---

## Success Criterion 4: Tempfile Isolation — Verified by Construction

**Claim:** Per-invocation MCP tempfile isolation is already satisfied; no change needed.

**Evidence:** `IssueFilingRunner.swift` lines ~141-147:

```swift
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
try config.mcpConfigJSON.write(to: tempURL, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: tempURL) }
```

Every call to `IssueFilingRunner.file(...)` generates a fresh UUID for the tempfile name. Concurrent calls each run their own stack frame; each creates its own `tempURL` local constant. The `defer` cleanup runs on every exit path for that call's frame, independent of other concurrent calls.

**What the planner should VERIFY (not rebuild):**

1. Confirm `IssueFilingRunner.file()` is a `static func` (it is — no shared mutable state between calls).
2. Confirm the `defer` block references the local `tempURL` constant, not a shared property.
3. Add a test: two concurrent `onRunIssueFiling` stub invocations both succeed without interfering. The stubs in `AppStateTests` already accomplish this by returning deterministically without shared state.

---

## Validation Architecture

> `workflow.nyquist_validation: true` in `.planning/config.json` — section included.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (built into Swift SDK) |
| Config file | `Tests/MakeAnIssueTests/AppStateTests.swift` (existing) |
| Quick run command | `swift test --filter AppStateTests` |
| Full suite command | `swift test` |

### Tests to REWRITE (existing tests that break due to D-08/D-09)

| Test Name | Why It Breaks | Rewrite Behavior |
|-----------|--------------|------------------|
| `testFilingEntersFilingState` | Waits for `captureState == .filing` which no longer exists | Assert `captureState == .idle` AND `jobs.count == 1 && jobs[0].state == .filing` while seam is in-flight |
| `testPushToTalkDuringFilingIsIgnored` | PTT during filing is NOW ALLOWED (D-09). Test currently asserts `.filing` is preserved | Rewrite: while `jobs[0].state == .filing`, startRecording() MUST succeed (`captureState` goes to `.recording`); two concurrent jobs in flight |
| `testStartRecordingAfterFilingReturnsToIdleStartsNewRecording` | Waits for both transcription AND filing to complete before trying PTT | Rewrite: after transcription completes, `captureState == .idle` immediately; PTT should work before filing finishes |
| `.filing` assertion in `testSuccessfulTranscriptionStoresText` | `captureState` never reaches `.filing` | Remove `.filing` assertion; verify `captureState == .idle` and `jobs.count == 1` after transcription |

### New Tests Required (Wave 0 gaps — these files do not yet exist)

| Req ID | Test Name | Behavior | Test Type | Command |
|--------|-----------|----------|-----------|---------|
| CONCUR-01 | `testTranscriptionCompletionReturnsCaptureToIdleImmediately` | After transcription completes, `captureState == .idle` AND `jobs.count == 1` (filing still in-flight) | async unit | `swift test --filter testTranscriptionCompletionReturns` |
| CONCUR-01 | `testNewRecordingAllowedWhileFilingIsInFlight` | Start recording again while `jobs[0].state == .filing`; `captureState == .recording` | async unit | `swift test --filter testNewRecordingAllowed` |
| CONCUR-02 | `testTwoConcurrentFilingJobsCanBeSpawned` | Two transcription → filing cycles while first job in-flight → `jobs.count == 2` | async unit | `swift test --filter testTwoConcurrentFiling` |
| CONCUR-02 | `testBothConcurrentJobsRetainDistinctTranscripts` | Two jobs have distinct `.transcript` values | async unit | `swift test --filter testBothConcurrentJobsRetain` |
| CONCUR-03 | `testSuccessfulFilingJobSpeaksIssueNumber` | Job completion calls `onSpeak("created issue #N")` | async unit | `swift test --filter testSuccessfulFilingJobSpeaks` |
| CONCUR-03 | `testFailedFilingJobSpeaksGenericFailure` | Job failure calls `onSpeak("issue filing failed")` | async unit | `swift test --filter testFailedFilingJobSpeaks` |
| CONCUR-03 | `testAnnouncementDeferredDuringRecording` | If a job completes while `captureState == .recording`, `onSpeak` is NOT called immediately; `pendingAnnouncements.count == 1` | async unit | `swift test --filter testAnnouncementDeferred` |
| CONCUR-03 | `testDeferredAnnouncementFlushedOnRecordingStop` | After `stopRecording()`, deferred announcement is spoken via `onSpeak` | async unit | `swift test --filter testDeferredAnnouncementFlushed` |
| D-06 | `testCompletedFilingJobRetainedInJobsArray` | After job completes, `jobs.count == 1 && jobs[0].state == .done` (not removed) | async unit | `swift test --filter testCompletedFilingJobRetained` |
| D-07 | `testFailedFilingJobRetainedInJobsArray` | After job fails, `jobs.count == 1 && jobs[0].state == .failed` (not removed) | async unit | `swift test --filter testFailedFilingJobRetained` |
| D-09 | `testPTTReEntryDuringFilingStartsNewRecording` | While `jobs[0].state == .filing`, startRecording() transitions `captureState` to `.recording` | async unit | `swift test --filter testPTTReEntry` |

### Sampling Rate

- **Per task commit:** `swift test --filter AppStateTests`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `Sources/MakeAnIssue/FilingJob.swift` — new file, covers `FilingJob` struct and `FilingJobState` enum
- [ ] `testFilingEntersFilingState` rewrite — covers CONCUR-01 intermediate state
- [ ] `testPushToTalkDuringFilingIsIgnored` rewrite — covers D-09 / CONCUR-02
- [ ] All 12 new tests listed above in `AppStateTests.swift`

*(No new test infrastructure files needed — `AppStateTests.swift` uses the existing `waitUntil` helper which is sufficient for all new tests.)*

---

## Security Domain

> `security_enforcement: true`, `security_asvs_level: 1` in `.planning/config.json`.

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth surface introduced in Phase 5 |
| V3 Session Management | No | No session state introduced |
| V4 Access Control | No | No access control surface changes |
| V5 Input Validation | Partial | `FilingJob.transcript` sourced from transcriber (existing validation); `FilingJob.repo` is a `RepoBinding` validated at bind time. No new external input surface introduced. |
| V6 Cryptography | No | No crypto introduced |

### Security Notes for Phase 5

**Token security:** Unchanged from v1.0. The GitHub token is acquired and passed to the subprocess environment by `IssueFilingRunner.file()` on each call. The jobs model does NOT store the token in `FilingJob`. `FilingJob.transcript` and `FilingJob.error` may appear in logs; the token does not. [CITED: IssueFilingRunner.swift line ~139 `// Never log the token value`]

**Subprocess isolation:** Each filing job spawns one `claude -p` subprocess via `CLIRunner`, with `--strict-mcp-config` and scoped `--allowedTools`. The jobs model does not change subprocess isolation — `IssueFilingRunner.file()` is unchanged.

**No new threat surface:** Phase 5 adds no new network calls, no new file I/O paths, and no new MCP config. The `FilingJob` struct is entirely in-memory session state.

### Known Threat Patterns (relevant to Phase 5)

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Transcript leakage via job retention (D-07) | Information Disclosure | Jobs are session-only in-memory; no disk write; cleared on app quit |
| False-positive "issue filing failed" speech | Denial of Service | Speak only on confirmed error path (explicit catch block); no speculative speech |

---

## Open Questions

1. **Should `.finished` be removed from `CaptureState`?**
   - What we know: `.finished` was introduced as a visible intermediate state between transcription and filing. Under the jobs model it is transient within a synchronous block (no `await` between `.finished` and `.idle`). Its only remaining purpose would be to signal "transcription just completed" to tests or observers.
   - What's unclear: does Phase 9's UI need to distinguish `.finished` from `.idle`? CONTEXT.md does not mention it. If not, it is dead weight.
   - Recommendation: Remove `.finished` in this phase. Set `captureState = .idle` directly in the transcription success path before calling `spawnFilingJob()`. This eliminates one state transition and one pitfall (Pitfall 5).

2. **AVSpeechSynthesizer ordering on macOS 13-15 — reliable or not?**
   - What we know: Apple's documentation guarantees utterances are queued in order on a single synthesizer. Some community reports (including one forum post) claim this is no longer the case in recent OS versions.
   - What's unclear: whether this affects brief short-phrase utterances ("created issue #42") on macOS 13-15 specifically.
   - Recommendation: Implement the simple `speak()` approach first. Add a manual verification step in Wave 1 or 2: fire 3 rapid `speak()` calls and confirm they play sequentially. Add the delegate-chain fallback only if ordering fails empirically.

3. **Should `[weak self]` be used in Task closures?**
   - What we know: `AppState` lives for the process lifetime in the running app. In tests, many `AppState` instances are created per test method. Without `[weak self]`, the task holds a strong reference to `AppState`, potentially delaying deallocation until the task completes.
   - What's unclear: whether the existing `beginFiling()` Task (which does not use `[weak self]`) causes test-suite memory pressure in practice.
   - Recommendation: Use `Task { [weak self, id] in guard let self else { return } ... }` in `spawnFilingJob()` for correctness. The overhead is minimal.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `Task { }` spawned from `@MainActor` context inherits `@MainActor` isolation, making `await MainActor.run {}` unnecessary inside the task body for state mutations | Architecture Patterns (Pattern 2) | If wrong, state mutations in Task body would require `await MainActor.run {}`; compiler would likely surface a data-race warning in strict concurrency mode |
| A2 | `Task<Void, Never>` stored in a `struct` member compiles without `Sendable` violations under Swift 5.10 non-strict concurrency | Architecture Patterns (Pattern 1) | If wrong, `FilingJob` may need to be a `class` or `task` property may need `nonisolated` treatment; low impact |
| A3 | Removing `.finished` from `CaptureState` does not break Phase 9 UI or other downstream plans | Architecture Patterns (Pattern 4) | If wrong, Phase 9 may need to re-add a state to distinguish transcription completion; deferred decision |
| A4 | `AVSpeechSynthesizer.speak()` called N times sequentially on a single stored instance produces sequential audio on macOS 13-15 | Pitfall 3 / Open Questions | If wrong, delegate-chain pattern needed; adds ~20 lines to `AppState`; speech may overlap or play out of order |
| A5 | `[weak self]` in the Task closure is safe (i.e., `self` is always non-nil when the task body executes within normal app lifetime) | Pitfall 4 | If wrong, task body early-exits via `guard let self else { return }` and the job silently fails to update its state |

**Lowest-risk assumptions:** A1, A2 — backed by Swift documentation and migration guide. A3, A4, A5 — need empirical verification.

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| `captureState = .filing` blocks new recordings | Jobs model: `captureState` returns to `.idle` immediately; `FilingJob.state` tracks individual job progress | Enables CONCUR-01/02 |
| `beginFiling()` — one active filing at a time | `spawnFilingJob()` — N concurrent Tasks | Enables CONCUR-02 |
| TTS called immediately on success (v1 success-only contract) | TTS gated through `announce()` → pending queue when recording; failure also speaks | Enables D-02/D-04 |

**Deprecated patterns for this phase:**
- `captureState.filing` — removed from the enum; DO NOT use in Phase 5 code
- Direct `onSpeak` / `speak()` calls from filing completion — replaced by `announce()` helper that checks recording state

---

## Sources

### Primary (MEDIUM confidence)

- [swiftlang/swift-migration-guide (Context7 — DataRaceSafety.md)](https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/DataRaceSafety.md) — `@MainActor` Task isolation inheritance, closure capture semantics
- [swiftlang/swift stdlib (Context7 — task.md)](https://github.com/swiftlang/swift/blob/main/stdlib/stdlib.docc/task.md) — `Task.cancel()`, `withTaskCancellationHandler`, unstructured task semantics

### Secondary (MEDIUM confidence — web + cross-check)

- [Apple Developer Documentation — AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) — utterance queue ordering, stored property requirement
- [Apple Developer Forums — Chaining speech utterances](https://developer.apple.com/forums/thread/651832) — single-synthesizer queue pattern, overlap from multiple instances

### Tertiary (LOW confidence — web search only)

- [Swift by Sundell — @MainActor attribute](https://www.swiftbysundell.com/articles/the-main-actor-attribute/) — @MainActor @Published interaction
- [Tim Broder — AVSpeechSynthesizer queue bug](https://timbroder.com/2014/03/avspeechsynthesizers-queue-doesnt-work/) — 2014 queue ordering bug (pause/stop); note: dated
- Community reports (Apple Developer Forums) — unreliable utterance ordering on recent macOS [ASSUMED, unconfirmed]

---

## Metadata

**Confidence breakdown:**
- FilingJob model shape: MEDIUM — directly derived from existing codebase patterns + Swift docs
- Task handle storage: MEDIUM — confirmed via Context7 Swift stdlib docs
- Architecture (jobs collection on @MainActor): MEDIUM — consistent with established AppState pattern; `@MainActor` Task inheritance cited from migration guide
- Pending-announcement queue: MEDIUM — derived from D-02/D-03 decisions; simple `[String]` buffer pattern is well-established
- AVSpeechSynthesizer ordering: LOW — documented guarantee is UNCONFIRMED for recent macOS; empirical verification required
- Test requirements: HIGH — derived directly from reading existing tests and mapping to D-08/D-09 decision changes

**Research date:** 2026-06-28
**Valid until:** 2026-07-28 (stable Swift concurrency patterns; AVSpeechSynthesizer behavior could change with OS updates)
