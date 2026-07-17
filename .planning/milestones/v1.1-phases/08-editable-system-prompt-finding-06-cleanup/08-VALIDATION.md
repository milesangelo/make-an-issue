---
phase: 08
slug: editable-system-prompt-finding-06-cleanup
status: validated
nyquist_compliant: false
wave_0_complete: true
created: 2026-07-01
---

# Phase 8 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Reconstructed retroactively from phase artifacts (State B).

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (SwiftPM) |
| **Config file** | `Package.swift` (test target `Tests/MakeAnIssueTests`) |
| **Quick run command** | `swift test --filter AppStateTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~4 seconds (146 tests) |

---

## Sampling Rate

- **After every task commit:** Run the relevant `swift test --filter <Suite>`
- **After every plan wave:** Run `swift test` (full suite)
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 08-01-02 | 01 | 1 | SETTINGS-05 / SETTINGS-02 | T-08-04 | `instructionsKey` literal is stable `"instructions"` — a rename would silently orphan persisted UserDefaults data on upgrade | unit | `swift test --filter AppStateTests` (`testInstructionsKeyIsStableLiteral`) | ✅ | ✅ green |
| 08-02-01 | 02 | 2 | SETTINGS-04 | T-08-01 | Enforced trailer always appended after user guidance (injection-style edits cannot remove it) | unit | `swift test --filter IssueFilingRunnerTests` (`testBuildPromptWithArbitraryInstructionsEndsWithEnforcedTrailer`) | ✅ | ✅ green |
| 08-02-01 | 02 | 2 | SETTINGS-04 | T-08-02 | Scoped `--allowedTools` grant is independent of instructions text | unit | `swift test --filter IssueFilingRunnerTests` (`testAssembleCommandStillContainsScopedAllowedToolsWithArbitraryInstructions`) | ✅ | ✅ green |
| 08-02-01 | 02 | 2 | SETTINGS-04 | T-08-03 | Blank / whitespace-only instructions fall back to `defaultInstructions` (D-08) | unit | `swift test --filter IssueFilingRunnerTests` (`testBuildPromptWith{Blank,WhitespaceOnly}Instructions…`) | ✅ | ✅ green |
| 08-02-01 | 02 | 2 | SETTINGS-04 / D-06 | — | `IssueFilingConfig.defaultInstructions` is non-empty (single canonical default) | unit | `swift test --filter IssueFilingConfigTests` (`testDefaultInstructionsIsNonEmpty`) | ✅ | ✅ green |
| 08-02-02 | 02 | 2 | SETTINGS-02 | T-08-09 | Persisted instructions read fresh per invocation — no concurrent-job staleness (D-02) | unit | `swift test --filter AppStateTests` (`testCurrentPersistedInstructionsReadsFreshPerInvocation`) | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing XCTest infrastructure covers all automatable phase requirements. The one previously-missing
automated assertion — pinning the `instructionsKey` literal value — was added during this validation
pass (`testInstructionsKeyIsStableLiteral` in `AppStateTests.swift`).

---

## Manual-Only Verifications

These are SwiftUI view behaviors. The repository has no view-testing infrastructure (no ViewInspector,
no snapshot testing), so they cannot be unit-tested without introducing a new dependency out of scope
for this phase. All three were confirmed in Plan 03's blocking human-verify checkpoint (Task 2,
approved 2026-07-01).

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Menu-bar popover shows no "CLI Command" field | SETTINGS-05 | SwiftUI view rendering; no view-test infra | Left-click the menu-bar icon → confirm no "CLI Command" field anywhere in the popover |
| Edited instructions persist across an app relaunch | SETTINGS-02 | `@AppStorage` + process relaunch; not exercisable in a unit test | Settings → Instructions → edit text → Quit → relaunch → reopen Settings → confirm edit persisted |
| "Reset to Default" visibly refills the editor | SETTINGS-03 | SwiftUI `Button` action on a `@AppStorage`-bound `TextEditor` | Settings → Instructions → click "Reset to Default" → confirm the box refills with shipped default (not blank) |
| Read-only enforced-contract display present & non-editable | D-04 | SwiftUI `Text` rendering; source-of-truth assertion already covered by 08-02 unit tests | Settings → Instructions → confirm greyed-out "Issue URL:" trailer + tool-grant note below the editor, non-editable |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or documented manual-only rationale
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (the one automatable gap was filled)
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [ ] `nyquist_compliant: true` — NOT set: 4 SwiftUI behaviors remain manual-only by design (no view-test infra); all were human-verified in Plan 03

**Approval:** approved 2026-07-01 (PARTIAL — automatable coverage complete; UI behaviors manual-only)
