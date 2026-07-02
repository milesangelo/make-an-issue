---
phase: 9
slug: jobs-list-ui-per-job-stop-surfaced-errors
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-01
---

# Phase 9 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from `09-RESEARCH.md` §Validation Architecture (lines 534–589) and the two phase plans.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (existing test target `MakeAnIssueTests`, `Tests/MakeAnIssueTests/`) |
| **Config file** | `Package.swift` (no new test-time dependency; only `KeyboardShortcuts` present — no ViewInspector/SnapshotTesting) |
| **Quick run command** | `swift test --filter AppStateTests 2>&1` |
| **Full suite command** | `swift test 2>&1` |
| **Estimated runtime** | ~30–60 seconds (small XCTest suite) |

**Rendered-view constraint:** No ViewInspector/SnapshotTesting exists, so on-screen row layout, actual icon rendering, and button hit-targets are **not automatable** in this project. Every prior phase (5–8) asserts SwiftUI-adjacent behavior via `AppState` `@Published` state or pure functions; Phase 9 follows that convention. Testable logic is pulled into pure functions (`JobRowStyle`, `openableIssueURL`) and `@MainActor AppState` mutations (`dismiss`/`clearFinished`); rendering is manual-only UAT.

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter AppStateTests 2>&1` (fastest feedback for the new dismiss/clearFinished/message unit tests; use `--filter JobRowStyleTests` for the 09-01 Task 3 commit)
- **After every plan wave:** Run `swift test 2>&1` (full suite)
- **Before `/gsd-verify-work`:** Full suite green AND the manual UAT checkpoint (09-02 Task 3) passed
- **Max feedback latency:** ~60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 09-01-1 | 01 | 1 | RESIL-01 | T-09-01 | `dismiss`/`clearFinished` are terminal-only; a `.filing` job can never be dropped | unit | `swift test --filter AppStateTests` | ❌ W0 | ⬜ pending |
| 09-01-2 | 01 | 1 | RESIL-01 | — | `message(for:)` reachable (non-private); 5-case strings pinned, not re-authored | unit | `swift test --filter AppStateTests` | ❌ W0 | ⬜ pending |
| 09-01-3 | 01 | 1 | JOBS-01 | T-09-02 | `openableIssueURL` admits `https` only; rejects http/javascript/file/garbage | unit | `swift test --filter JobRowStyleTests` | ❌ W0 | ⬜ pending |
| 09-02-1 | 02 | 2 | JOBS-01, JOBS-02, RESIL-01 | T-09-03, T-09-04 | Stop only on `.filing`, ✕ only on terminal; done-row opens only via the guard | build | `swift build` | ✅ | ⬜ pending |
| 09-02-2 | 02 | 2 | JOBS-01 | T-09-05 | Clear-all removes terminal rows only; views never mutate `jobs[]` directly | build+suite | `swift build && swift test` | ✅ | ⬜ pending |
| 09-02-3 | 02 | 2 | JOBS-01, JOBS-02, RESIL-01 | — | Rendered per-state rows, controls, expand, newest-first scroll (manual) | manual-only | — (UAT checkpoint) | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky. "File Exists": ✅ existing test file · ❌ W0 = new test authored during the task.*

---

## Wave 0 Requirements

- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — add `testDismissJobRemovesTerminalJob`, `testDismissJobIsNoOpForFilingJob`, `testClearFinishedRemovesAllTerminalJobs`, `testClearFinishedPreservesFilingJobs`, `testMessageForIssueFilingErrorCases` (RESIL-01 new `AppState` surface)
- [ ] `Tests/MakeAnIssueTests/JobRowStyleTests.swift` (new file) — add `testJobRowStyleIconPerState`, `testJobRowStyleColorPerState`, `testOpenableIssueURLAcceptsHTTPS`, `testOpenableIssueURLRejectsNonHTTPS` (JOBS-01 state→style mapping + D-10 https guard)
- [ ] Framework install: none — XCTest already configured; no `Package.swift` test-target changes needed

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Jobs list renders with correct per-state icon/color + `.filing` activity indicator | JOBS-01 | No ViewInspector/SnapshotTesting infra — rendered output is not assertable | 09-02 Task 3, steps 2–4, 6 |
| Stop present only on `.filing` rows; ✕ only on terminal rows (D-05) | JOBS-02 | View composition, no rendering infra | 09-02 Task 3, step 3 |
| Transcript snippet expand/collapse toggle; full text reachable when expanded (D-08) | RESIL-01 | `@State` toggle behavior on a rendered view | 09-02 Task 3, step 5 |
| Done-row `#N` opens the correct issue in the browser (D-10) | JOBS-01 | Rendered tap → `NSWorkspace.open` (the https guard itself is automated in 09-01) | 09-02 Task 3, step 4 |
| Clear-all removes terminal rows only, leaves in-flight `.filing` job running (D-04/D-05) | JOBS-02 | Rendered control + live subprocess | 09-02 Task 3, step 7 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies (manual-only rows justified above)
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify (09-02 Task 3 is the only manual task, isolated after two build/suite tasks)
- [ ] Wave 0 covers all MISSING references (AppStateTests + JobRowStyleTests new methods)
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter (flip after execution proves the full suite green)

**Approval:** pending
