---
phase: 07-appkit-status-item-ui-settings-window-shell
plan: "02"
subsystem: AppKit Status-Item UI + Settings Window Shell
tags:
  - AppKit
  - NSPopover
  - KeyboardShortcuts
  - MenuView
  - hotkey-fix
dependency_graph:
  requires:
    - "07-01 (Recorder relocation and .onDisappear removal already applied)"
  provides:
    - "MenuView.swift: verified clean — Recorder editor absent, .onDisappear workaround absent, CLI Command field and ShortcutPillView retained"
  affects:
    - "Sources/MakeAnIssue/MenuView.swift (no-op reconciliation — all work done by 07-01)"
tech_stack:
  added: []
  patterns:
    - "No-op reconciliation: earlier plan's Rule 2 deviation covers 07-02's full scope"
key_files:
  created: []
  modified: []
decisions:
  - "07-02 scope fully satisfied by 07-01 deviation (commit cee29fa): no further changes to MenuView.swift required"
metrics:
  duration: "2 minutes"
  completed: "2026-06-30"
  tasks_completed: 1
  files_created: 0
  files_modified: 0
status: complete
---

# Phase 07 Plan 02: Recorder Relocation + Pitfall 10 Fix — Verification Summary

Verified that 07-01 (commit cee29fa) already performed both removals from `MenuView.swift` that 07-02 planned: the push-to-talk shortcut editor block (lines 63–71 of the pre-07-01 file) was relocated to `SettingsView.swift`, and the `.onDisappear` menu end-tracking workaround (lines 104–113) was removed. Build and test suite confirmed green with no further changes required.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Verify 07-01 already satisfied 07-02 scope (no-op reconciliation) | cee29fa (07-01) | MenuView.swift — no new changes needed |

## Verification Results

### Automated (all assertions pass)

- `! grep -nE 'KeyboardShortcuts\.Recorder' Sources/MakeAnIssue/MenuView.swift` — PASS
- `! grep -nE 'didEndTrackingNotification' Sources/MakeAnIssue/MenuView.swift` — PASS
- `grep -q 'cliCommand' Sources/MakeAnIssue/MenuView.swift` — PASS (CLI Command field retained)
- `grep -q 'ShortcutPillView' Sources/MakeAnIssue/MenuView.swift` — PASS (read-only pill retained)
- `grep -q 'import KeyboardShortcuts' Sources/MakeAnIssue/MenuView.swift` — PASS (still used by `updateShortcutText()`)
- `grep -q 'KeyboardShortcuts.Recorder' Sources/MakeAnIssue/SettingsView.swift` — PASS (editor lives in SettingsView)
- `swift build` — Build complete (0.11s)
- `swift test` — 137 tests, 0 failures

### Manual UAT Required (unchanged from 07-01)

Behavioral correctness is MANUAL-ONLY on macOS 13 (Ventura), 14 (Sonoma), 15 (Sequoia) per 07-VALIDATION.md:
- With another app focused: push-to-talk fires after opening then closing the popover
- With another app focused: push-to-talk fires after opening then closing the right-click menu
- Push-to-talk fires while the popover is open
- Settings disclosure shows only the CLI Command field (no Recorder)
- ShortcutPillView still displays the current shortcut read-only in ActionCard

This is the A4 closure evidence; results to be recorded in 07-VALIDATION.md during UAT.

## Deviations from Plan

### Already-Satisfied by 07-01 (no duplication needed)

**1. [07-01 Rule 2 Deviation] Remove Recorder block + .onDisappear from MenuView.swift — already complete**

- **Satisfied during:** 07-01 Task 1 (commit cee29fa)
- **Work done by 07-01:** The VStack shortcut-editor block (KeyboardShortcuts.Recorder, the secondary "Push-to-Talk Shortcut" label, and the trailing `.padding(.top, 4)`) was removed from the DisclosureGroup in MenuView.swift. The `.onDisappear` modifier posting `NSMenu.didEndTrackingNotification` was also removed. Both are exactly what 07-02 planned.
- **Why it happened:** 07-PATTERNS.md specified both removals, and 07-01's executor applied them as a Rule 2 (Missing Critical Functionality) deviation to prevent duplicate Recorder UI and spurious hotkey un-pause.
- **Verification:** All six source assertions pass; `swift build` and `swift test` (137 tests) remain green.
- **No further action needed in 07-02.**

## Known Stubs

None. The popover's Settings disclosure contains only the CLI Command field (D-04). The ShortcutPillView read-only display (D-05) is retained. Phase 8 will relocate the CLI Command field (FINDING-06).

## Threat Surface Scan

No new threat surface. This plan introduced no changes — all removals were performed by 07-01. The threat register (T-07-03) remains accurate: no STRIDE-applicable threat added by removals-only changes.

## Self-Check: PASSED

- `Sources/MakeAnIssue/MenuView.swift` contains no `KeyboardShortcuts.Recorder`: YES
- `Sources/MakeAnIssue/MenuView.swift` contains no `didEndTrackingNotification`: YES
- `Sources/MakeAnIssue/MenuView.swift` contains `cliCommand`, `ShortcutPillView`, `import KeyboardShortcuts`: YES
- `Sources/MakeAnIssue/SettingsView.swift` contains `KeyboardShortcuts.Recorder`: YES
- All satisfying work in commit cee29fa — present in git log: YES
- `swift build` passed: YES
- `swift test` 137/0 passed: YES
