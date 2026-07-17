---
phase: 05-concurrent-filing-jobs-model
reviewed: 2026-06-29T20:57:40Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/FilingJob.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
  - Tests/MakeAnIssueTests/FilingJobTests.swift
findings:
  critical: 0
  warning: 5
  info: 3
  total: 8
status: issues_found
---

# Phase 05: Code Review Report

**Reviewed:** 2026-06-29T20:57:40Z
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

This phase refactors a serial filing pipeline into N concurrent per-job `@MainActor`
Tasks tracked in `@Published var jobs: [FilingJob]`, with spoken outcomes routed through a
defer-until-mic-idle announcement queue.

The core concurrency mechanics are largely correct. The stale-index-across-await hazard the
plan warns about is genuinely avoided: `spawnFilingJob` re-resolves the job index via
`firstIndex(where: { $0.id == id })` *after* every `await` rather than caching an index, and
the transcript/repo are captured by value into the filing Task's capture list. `[weak self]`
is used on the filing Task and the long-lived global closures, so no retain cycle pins
`AppState`. The test suite asserts real concurrent behavior (two simultaneous `.filing` jobs,
distinct transcripts, distinct result numbers, deferral while recording, flush on stop) rather
than tautologies — with one exception noted below.

The defects found are correctness/robustness gaps at the edges of the concurrency model: a
read of `self.boundRepo` *after* an `await` (the exact Pitfall-1 class the plan flags), a
deferred-announcement queue that can be stranded on the error path, transcript content written
to the system log, and one weak/misleading test. No security-critical, crash, or data-loss
BLOCKER was proven.

## Warnings

### WR-01: `self.boundRepo` read after `await` can file to the wrong repository

**File:** `Sources/MakeAnIssue/AppState.swift:230`
**Issue:** Inside the transcription `Task`, `boundRepo` is read from `self` *after* the
`await onRunTranscription(wavURL)` suspension point:

```swift
let text = try await onRunTranscription(wavURL)   // suspension point
...
if let repo = self.boundRepo {                     // live read AFTER await
    self.spawnFilingJob(transcript: text, repo: repo)
}
```

`handleLaunchRequest(_:)` mutates `boundRepo` and is driven by external CLI launch requests,
which are not gated by `captureState`. If a launch request for repo B arrives while a recording
for repo A is still transcribing, this read observes repo B and the issue is filed against the
wrong repository. This is precisely the "never read from `self` after an `await`" hazard the
plan calls out as Pitfall 1 — the transcript is correctly captured by value (`text`), but the
repo is not. The window is narrow (transcription duration) and the "correct" repo is arguably
debatable, hence WARNING rather than BLOCKER, but the wrong-repo outcome is real.
**Fix:** Snapshot the repo before the suspension point and pass the snapshot through, so the
filing target is the repo bound when the user spoke:
```swift
private func beginTranscription() {
    ...
    let repoAtCapture = boundRepo   // snapshot before await
    Task {
        let text = try await onRunTranscription(wavURL)
        self.transcript = text
        self.captureState = .idle
        if let repo = repoAtCapture {
            self.spawnFilingJob(transcript: text, repo: repo)
        } else {
            self.statusText = "No repository bound — cannot file"
        }
        ...
    }
}
```

### WR-02: Deferred announcements are stranded on the recording-error path

**File:** `Sources/MakeAnIssue/AppState.swift:389-395` (and `295-310`)
**Issue:** `announce(_:)` defers a completed job's spoken outcome into `pendingAnnouncements`
whenever `captureState == .recording`. The *only* drain point is
`flushPendingAnnouncements()`, which is called exclusively from `beginTranscription()`.
`handleRecordingError(_:)` resets `captureState = .idle` without draining the queue:

```swift
func handleRecordingError(_ error: Error?) {
    recordingTimeoutTask?.cancel()
    recordingTimeoutTask = nil
    onStopRecording()
    captureState = .idle
    statusText = "Recording failed — ..."
    // pendingAnnouncements never flushed here
}
```

Sequence: a job completes while a second recording is active (announcement deferred) → that
recording fails via the recorder's error delegate instead of a normal key-up stop → the
deferred "created issue #N" / "issue filing failed" announcement is stranded and only spoken
later, when (or if) the user records again. The user never hears the outcome of a successful
filing.
**Fix:** Drain the queue when recording ends abnormally:
```swift
func handleRecordingError(_ error: Error?) {
    recordingTimeoutTask?.cancel()
    recordingTimeoutTask = nil
    onStopRecording()
    captureState = .idle
    statusText = "Recording failed — \(error?.localizedDescription ?? "audio error")"
    flushPendingAnnouncements()
}
```

### WR-03: Transcript (user speech content) written to the unified system log

**File:** `Sources/MakeAnIssue/AppState.swift:228`
**Issue:** `NSLog("MakeAnIssue transcript: \(text)")` writes the full transcribed speech to the
macOS unified log on every successful transcription. Transcribed voice content is user-sensitive
(it can contain anything the user dictates) and persists in the system log, readable by admins
and processes with log entitlements. This is an information-disclosure / privacy defect, not a
debug convenience that should ship.
**Fix:** Remove the content from the log, or log only metadata (length), or mark it private:
```swift
NSLog("MakeAnIssue transcript received (%d chars)", text.count)
// or, if content is needed for debugging, gate behind a debug flag and use os_log with .private
```

### WR-04: `testFilingJobStateHasFourCases` is tautological and its comment is misleading

**File:** `Tests/MakeAnIssueTests/FilingJobTests.swift:15-19`
**Issue:** The test claims to enforce the enum's case count:
```swift
func testFilingJobStateHasFourCases() {
    // Exhaustive switch ensures all four cases exist at compile time.
    let states: [FilingJobState] = [.filing, .done, .failed, .cancelled]
    XCTAssertEqual(states.count, 4)
}
```
There is no exhaustive `switch` — the body is an array literal of four hand-written elements,
then asserts the literal it just wrote has four elements. The assertion is always true and
provides no compile-time or runtime guard: adding a fifth case to `FilingJobState` leaves this
test green. The comment asserts a guarantee the code does not deliver.
**Fix:** Make the count derive from the type via an exhaustive switch (so a new case forces a
compile error or test update):
```swift
func testFilingJobStateHasFourCases() {
    for state in [FilingJobState.filing, .done, .failed, .cancelled] {
        switch state {            // exhaustive — a new case breaks compilation
        case .filing, .done, .failed, .cancelled: break
        }
    }
}
```
Or delete the test as low-value; the real assertions live in `testFilingJobStateEquatable`.

### WR-05: Generic `catch` in `spawnFilingJob` marks job `.failed` but leaves `error` nil

**File:** `Sources/MakeAnIssue/AppState.swift:280-285`
**Issue:** The typed `catch let filingError as IssueFilingError` branch stores
`jobs[idx].error = filingError`, but the fallthrough generic `catch` sets only
`jobs[idx].state = .failed` and never populates `jobs[idx].error`. A job that failed for a
non-`IssueFilingError` reason is `.failed` with `error == nil`. The Phase 9 job-list UI (the
stated reason this state is retained per D-06/D-07) will render a failed row with no diagnostic,
and any `error`-based branching will mis-handle it as if no error occurred.
**Fix:** Either funnel unexpected errors into a typed case or store something inspectable, e.g.
wrap as an `IssueFilingError`/store the localized description so the failed job is never
information-empty:
```swift
} catch {
    if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
        self.jobs[idx].state = .failed
        self.jobs[idx].error = .cliFailed(exitCode: -1, stderr: error.localizedDescription)
    }
    self.announce("issue filing failed")
}
```

## Info

### IN-01: Transcription Task captures `self` strongly while filing Task documents `[weak self]`

**File:** `Sources/MakeAnIssue/AppState.swift:224-251`
**Issue:** `spawnFilingJob` deliberately uses `[weak self]` and documents it as Pitfall 4, but
the `Task {}` in `beginTranscription()` captures `self` strongly with no capture list. Because
`AppState` is the app's long-lived root state this is not a leak in practice, but it is
inconsistent with the established pattern and would matter if `AppState` ever became
short-lived.
**Fix:** Mirror the filing Task: `Task { [weak self] in guard let self else { return } ... }`.

### IN-02: Redundant `await MainActor.run {}` in transcription error paths

**File:** `Sources/MakeAnIssue/AppState.swift:237-248`
**Issue:** The `Task {}` is created inside a `@MainActor` method and therefore already runs on
the main actor (the success path correctly mutates `self` directly). The two
`await MainActor.run { ... }` wrappers in the `catch` branches are redundant hops that add an
extra await/suspension and read as if the surrounding context were non-isolated, which is
misleading.
**Fix:** Drop the `MainActor.run` wrappers and mutate `self` directly, matching the success path.

### IN-03: Late mic-permission denial overwrites status even after `startRecording()` promoted to granted

**File:** `Sources/MakeAnIssue/AppState.swift:156-163`
**Issue:** The startup permission `Task` correctly avoids clobbering `micPermissionGranted`
(it only promotes), but on a late-resolving denial it unconditionally sets
`statusText = "Microphone access denied …"`. If the live re-check in `startRecording()` already
promoted `micPermissionGranted = true` (grant made in System Settings after launch), the UI can
show a "denied" banner while permission is in fact granted.
**Fix:** Guard the status write on the current flag: `if !granted, !self?.micPermissionGranted`,
or only set the denial status when `micPermissionGranted` is still false.

---

_Reviewed: 2026-06-29T20:57:40Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
