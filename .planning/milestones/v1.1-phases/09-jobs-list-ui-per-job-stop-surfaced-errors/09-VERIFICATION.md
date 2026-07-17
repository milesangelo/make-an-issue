---
phase: 09-jobs-list-ui-per-job-stop-surfaced-errors
verified: 2026-07-02T07:45:00Z
status: passed
score: 11/11 must-haves verified
behavior_unverified: 0
overrides_applied: 0
---

# Phase 9: Jobs List UI + Per-Job Stop + Surfaced Errors Verification Report

**Phase Goal:** Render active jobs in the menu with per-row Stop and persistent, recoverable error rows (RESIL-01). Specifically — the left-click popover shows a per-state "Filing Jobs" list (filing/done/failed/cancelled) below the transcript; each `.filing` row has a Stop that cancels only that job; terminal rows persist (no auto-clear) with a per-row ✕; failed rows surface a mapped error message + expandable transcript; done rows open the issue URL only when https-validated; a header Clear-all removes terminal rows only and never in-flight work.

**Verified:** 2026-07-02T07:45:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (Plan 09-01 — logic surface)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `dismiss(jobID:)` removes exactly one terminal job and no-ops for a `.filing` job | VERIFIED | `AppState.swift:360-362`: `func dismiss(jobID: UUID) { jobs.removeAll { $0.id == jobID && $0.state != .filing } }`. No `.cancel(` / `.task` reference. Tests `testDismissJobRemovesTerminalJob` and `testDismissJobIsNoOpForFilingJob` pass (155/155 suite green). |
| 2 | `clearFinished()` removes every non-`.filing` job and leaves all `.filing` jobs untouched | VERIFIED | `AppState.swift:367-369`: `func clearFinished() { jobs.removeAll { $0.state != .filing } }`. Tests `testClearFinishedRemovesAllTerminalJobs` and `testClearFinishedPreservesFilingJobs` pass. |
| 3 | `AppState.message(for: IssueFilingError)` is reachable (non-private) and returns correct string per case | VERIFIED | `AppState.swift:426`: `static func message(for error: IssueFilingError) -> String` — no `private` modifier (grep for `private static func message(for error: IssueFilingError)` returns nothing). `testMessageForIssueFilingErrorCases` asserts all 5 cases pass. |
| 4 | `JobRowStyle` maps each of the 4 `FilingJobState` cases to a distinct SF Symbol icon and a tint color | VERIFIED | `JobRowStyle.swift:13-40`: 4 distinct icon strings, 4 distinct tint colors (`.blue`/`.green`/`Color.amberStyle`/`.secondary`). `testJobRowStyleIconPerState` asserts all 4 non-empty and mutually distinct; `testJobRowStyleColorPerState` asserts exact colors. |
| 5 | `JobRowStyle.openableIssueURL` returns a URL only when scheme is https, rejecting non-https/javascript/file | VERIFIED | `JobRowStyle.swift:49-54`: `guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }`. `testOpenableIssueURLAcceptsHTTPS` and `testOpenableIssueURLRejectsNonHTTPS` (http/javascript/file/garbage) pass. |

### Observable Truths (Plan 09-02 — jobs-list UI)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 6 | Popover shows a "FILING JOBS (N)" section listing every job below TranscriptCard when jobs exist | VERIFIED (source) / Human-verified (render) | `MenuView.swift:475-509` `JobsSection` — header `Text("FILING JOBS (\(appState.jobs.count))")`; `JobsSection(appState: appState)` inserted at `MenuView.swift:56`, immediately after the `TranscriptCard` block (line 52). Rendered behavior approved in UAT (09-02-SUMMARY.md Task 3, 6/6 checks). |
| 7 | Section (incl. Clear-all) is hidden entirely when `jobs[]` is empty; newest job renders on top | VERIFIED | `MenuView.swift:479`: `if !appState.jobs.isEmpty { … }` wraps the entire section body including the header/Clear-all — no `EmptyView` fallback, whole block collapses. `MenuView.swift:493`: `ForEach(appState.jobs.reversed())`. UAT step 2 (empty-state) and step 6 (newest-on-top) approved. |
| 8 | A `.filing` row shows an activity indicator + Stop that calls `cancel(jobID:)`, and no ✕ | VERIFIED | `MenuView.swift:552-564`: `.filing` case renders `ActivitySpinner(color: .blue)` + `Button("Stop") { appState.cancel(jobID: job.id) }`. No `DismissButton` in this branch (grep confirms `DismissButton` appears only in `.done`/`.failed`/`.cancelled` branches at lines 585/596/609). |
| 9 | Terminal rows persist (no auto-clear) with a per-row ✕; failed row shows `message(for:)` + expandable transcript | VERIFIED | No timer/auto-clear code exists anywhere in `AppState.swift` or `MenuView.swift` (the only removal paths are `dismiss`/`clearFinished`, both user-invoked). `MenuView.swift:588-599`: `.failed` case renders `Text(job.error.map(AppState.message(for:)) ?? "Issue filing failed")` + `TranscriptSnippet(transcript: job.transcript)` (expand-on-tap at `MenuView.swift:527-543`) + `DismissButton`. |
| 10 | A `.done` row shows "Issue #N filed" opening `result.url` via NSWorkspace only when https-validated | VERIFIED | `MenuView.swift:566-586`: `if let url = JobRowStyle.openableIssueURL(result.url) { NSWorkspace.shared.open(url) }` — the only `NSWorkspace.shared.open` call site in the file (single grep hit at line 573), always preceded by the guard; never opens a raw string. |
| 11 | Terminal rows have a ✕ calling `dismiss(jobID:)`; Clear-all calls `clearFinished()` and removes terminal rows only | VERIFIED | `DismissButton.swift` (in `MenuView.swift:511-525`): action `appState.dismiss(jobID: jobID)`. `ClearAllButton` (`MenuView.swift:460-473`): action `appState.clearFinished()`, whose implementation is itself scoped to `$0.state != .filing` (truth #2), so an in-flight job can never be removed by Clear-all. |

**Score:** 11/11 truths verified (0 present-behavior-unverified)

Note: Truths 6-11 depend partly on rendered SwiftUI view behavior, for which this project has no automated rendered-view test harness (no ViewInspector/SnapshotTesting in `Package.swift` — confirmed by grep, zero hits). Per this project's established pattern (every prior phase's UI), rendered behavior was verified through a blocking `checkpoint:human-verify` task (Plan 09-02 Task 3) during plan execution, which the operator approved across all 6 documented checks (empty state, filing→Stop→cancelled transition, done-row URL open, failed row message+transcript+persistence, newest-on-top scroll, Clear-all scoping). All source-level wiring underlying each of these behaviors (button actions, state-gated branches, guard conditions) was independently confirmed by direct code inspection above, not merely SUMMARY.md narrative.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/AppState.swift` | `dismiss(jobID:)`, `clearFinished()`, exposed `message(for:)` | VERIFIED | All three present, correct signatures, correct predicate (`$0.state != .filing`) |
| `Sources/MakeAnIssue/JobRowStyle.swift` | `iconName(for:)`, `tintColor(for:)`, `openableIssueURL(_:)` | VERIFIED | 55-line file, `enum JobRowStyle` (no cases, nonisolated statics), all three functions present and correct |
| `Sources/MakeAnIssue/MenuView.swift` | `JobsSection`, `JobRow`, `DismissButton`, `ClearAllButton`, `TranscriptSnippet`; composed into `body` | VERIFIED | All 5 structs present; `JobsSection(appState: appState)` composed as last item of `MenuView.body`'s VStack, after `TranscriptCard` |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | dismiss/clearFinished/message unit tests | VERIFIED | 5 new tests present (`testDismissJobRemovesTerminalJob`, `testDismissJobIsNoOpForFilingJob`, `testClearFinishedRemovesAllTerminalJobs`, `testClearFinishedPreservesFilingJobs`, `testMessageForIssueFilingErrorCases`), all passing |
| `Tests/MakeAnIssueTests/JobRowStyleTests.swift` | icon/color mapping + https URL guard tests | VERIFIED | 4 tests present, all passing |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `AppStateTests.swift` | `AppState.swift` | tests call `dismiss(jobID:)`/`clearFinished()`/`message(for:)` directly | WIRED | Confirmed via direct source read of the 5 new test methods |
| `JobRowStyleTests.swift` | `JobRowStyle.swift` | tests assert `iconName`/`tintColor`/`openableIssueURL` | WIRED | Confirmed via direct source read of the 4 test methods |
| `MenuView.swift` | `AppState.swift` | `Stop→cancel(jobID:)`; `✕→dismiss(jobID:)`; `Clear-all→clearFinished()` | WIRED | Grep `appState\.(cancel\|dismiss\|clearFinished)` → 3 hits, one per control, each in the correct row branch |
| `MenuView.swift` | `JobRowStyle.swift` | `JobRow` reads `iconName`/`tintColor`; gates open on `openableIssueURL` | WIRED | Grep `JobRowStyle\.(iconName\|tintColor\|openableIssueURL)` → 7 hits across `.done`/`.failed`/`.cancelled` branches; open call gated correctly |
| `MenuView.swift` | `MenuView.swift` (body composition) | `JobsSection` inserted as last VStack item after `TranscriptCard` | WIRED | `MenuView.swift:56`, directly following the `if let transcript { TranscriptCard(...) }` block at line 51-53 |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full test suite green | `swift test` | `Executed 155 tests, with 0 failures (0 unexpected)` | PASS |
| Build clean | `swift build` | `Build complete!` | PASS |
| dismiss/clearFinished tests present + passing | (included in full run above) | 4/4 pass | PASS |
| JobRowStyle tests present + passing | (included in full run above) | 4/4 pass | PASS |
| Task commits exist in git history | `git cat-file -e <hash>` × 5 | All 5 commits (2c08d71, a47c4da, a5d3749, 3cf5ed7, 65397df) present | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|--------------|--------|----------|
| JOBS-01 | 09-01, 09-02 | Menu shows list of active filing jobs w/ state + activity indicator | SATISFIED | `JobRowStyle.iconName/tintColor` (per-state), `JobsSection`/`JobRow` render all 4 states with `ActivitySpinner` for `.filing` |
| JOBS-02 | 09-02 | Each active job row has a Stop control cancelling that specific job | SATISFIED | `Button("Stop") { appState.cancel(jobID: job.id) }`, `.filing`-branch only, no ✕ on that branch |
| RESIL-01 | 09-01, 09-02 | Failed filing surfaces recoverable error (spoken + persistent row + message + transcript, dismiss-only) | SATISFIED | Spoken announcement pre-exists from Phase 5 (`announce("issue filing failed")`, `AppState.swift`); persistent `.failed` row + `message(for:)` + `TranscriptSnippet` + `DismissButton` added this phase; no auto-clear timer exists anywhere in the codebase |

No orphaned requirements — REQUIREMENTS.md maps exactly JOBS-01, JOBS-02, RESIL-01 to Phase 9, and both plans' frontmatter `requirements` fields collectively cover all three.

### Anti-Patterns Found

None. Grep scan of all 5 phase-modified files (`AppState.swift`, `JobRowStyle.swift`, `MenuView.swift`, `AppStateTests.swift`, `JobRowStyleTests.swift`) for `TBD|FIXME|XXX|TODO|HACK|PLACEHOLDER` and placeholder-language patterns (`placeholder|coming soon|will be here|not yet implemented|not available`) returned zero matches. No debt markers found.

Prohibitions from Plan 09-02 also confirmed honored: no `Retry` button anywhere in `MenuView.swift`; no `✕`/`DismissButton` on the `.filing` branch; no `Button("Stop"` on any terminal branch; no direct `appState.jobs = ` mutation from a view (only `appState.jobs.isEmpty`/`.count`/`.contains`/`.reversed()` reads); `WaveformView` used only in the pre-existing `ActionCard` (unrelated to jobs), not reused for the `.filing` indicator; `ActivitySpinner` used for the `.filing` row instead.

### Human Verification Required

None outstanding. The rendered-view behaviors (Section visibility, per-state row rendering, URL-open, transcript expansion, scroll/ordering, Clear-all scoping) were verified through Plan 09-02's blocking `checkpoint:human-verify` Task 3 during execution — the operator approved all 6 documented checks (per 09-02-SUMMARY.md). This project has no automated rendered-view test infrastructure (confirmed: zero ViewInspector/SnapshotTesting references in `Package.swift`), so this is the established and only verification path for SwiftUI view composition in this codebase, consistent with every prior phase. All underlying source-level wiring for these behaviors was independently confirmed above via direct code inspection (not SUMMARY.md narrative alone).

### Gaps Summary

No gaps found. All 11 must-have truths verified against actual source code (not SUMMARY.md claims): the two new `AppState` mutation methods use the correct terminal-only predicate and never touch cancellation state; `message(for: IssueFilingError)` is reachable and its 5-case mapping is pinned by a passing test; `JobRowStyle` provides 4 distinct icon/color mappings and an https-only URL guard; `MenuView.swift`'s `JobsSection`/`JobRow`/`DismissButton`/`ClearAllButton`/`TranscriptSnippet` are all present, correctly composed into `body`, and correctly wired to the Plan 09-01 logic surface with strict per-state control separation (Stop only on `.filing`, ✕ only on terminal rows) and a defense-in-depth https guard ahead of every `NSWorkspace.shared.open` call. Full `swift test` suite (155/155) and `swift build` are independently confirmed green by direct execution, not by trusting SUMMARY.md's reported numbers. No debt markers, no stub patterns, no orphaned requirements.

---

*Verified: 2026-07-02T07:45:00Z*
*Verifier: Claude (gsd-verifier)*
