---
phase: 07-appkit-status-item-ui-settings-window-shell
plan: "01"
subsystem: AppKit Status-Item UI + Settings Window Shell
tags:
  - AppKit
  - NSStatusItem
  - NSPopover
  - SwiftUI
  - Combine
  - settings
  - recording-indicator
dependency_graph:
  requires:
    - "06-cancellation-stop-control (Phase 6 teardown preserved verbatim)"
  provides:
    - "SettingsView.swift: focusable Settings window with push-to-talk Recorder"
    - "AppDelegate AppKit shell: NSStatusItem, NSPopover, right-click NSMenu, recording indicator"
    - "MakeAnIssueApp: Settings { EmptyView() } placeholder scene"
  affects:
    - "MenuView.swift: Recorder block and .onDisappear workaround removed"
tech_stack:
  added:
    - "Combine (AppDelegate import — $captureState sink)"
    - "SwiftUI (AppDelegate import — NSHostingController for Settings and popover)"
  patterns:
    - "assign-popUp-clear NSMenu pattern (right-click menu)"
    - "NSApp.activate before makeKeyAndOrderFront (LSUIElement focus)"
    - "layer backgroundColor for recording tint (NOT contentTintColor)"
    - "Stored NSStatusItem! property (prevent early release)"
    - "Transient NSPopover with left/right-click discrimination via NSApp.currentEvent"
key_files:
  created:
    - "Sources/MakeAnIssue/SettingsView.swift"
  modified:
    - "Sources/MakeAnIssue/AppDelegate.swift"
    - "Sources/MakeAnIssue/MakeAnIssueApp.swift"
    - "Sources/MakeAnIssue/MenuView.swift"
decisions:
  - "D-01: Red tint on exclamationmark.bubble glyph via layer backgroundColor, no symbol swap"
  - "D-02: Recording-only indicator — .transcribing and filing never light the tint"
  - "D-03: Settings window self-owned NSWindowController hosting SettingsView with Recorder"
  - "D-06: Transient NSPopover for left-click; popover.behavior = .transient"
  - "D-07: Right-click NSMenu contains Settings… and Quit only (assign-popUp-clear)"
  - "Open Question 1 resolution: used contentView layer (primary path) — button's own layer is documented fallback for UAT"
  - "Assumption A3: Settings { EmptyView() } never auto-shows in LSUIElement app"
metrics:
  duration: "4 minutes"
  completed: "2026-06-30"
  tasks_completed: 3
  files_created: 1
  files_modified: 3
status: complete
---

# Phase 07 Plan 01: AppKit Status-Item Shell + Recording Indicator Summary

AppKit status-item shell replacing `MenuBarExtra`: NSStatusItem with left/right-click discrimination, transient NSPopover hosting MenuView, assign-popUp-clear NSMenu with Settings…/Quit, self-owned NSWindowController hosting SettingsView with push-to-talk Recorder, and Combine sink driving layer-background red tint on `.recording` only.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create SettingsView.swift + remove Recorder from MenuView | cee29fa | SettingsView.swift (new), MenuView.swift |
| 2 | Build AppDelegate AppKit shell + recording indicator | 9b4db57 | AppDelegate.swift |
| 3 | Swap App scene from MenuBarExtra to Settings { EmptyView() } | 04482f8 | MakeAnIssueApp.swift |

## Verification Results

### Automated

- `swift build` passed after each task (all three tasks)
- `swift test` passed after Task 2 and Task 3: **137 tests, 0 failures**
- Source assertions all pass:
  - `SettingsView.swift`: `struct SettingsView`, `KeyboardShortcuts.Recorder`, `.pushToTalk`, no `AppKit` import
  - `AppDelegate.swift`: `func setUpStatusItem`, `sendAction(on:`, `statusItem.menu = nil`, `func showSettingsWindow`, `$captureState`, `applicationShouldTerminate`, no `contentTintColor`
  - `MakeAnIssueApp.swift`: no `MenuBarExtra(` scene call, `Settings {`, `EmptyView`, `NSApplicationDelegateAdaptor` preserved

### Manual UAT Required

Behavioral correctness is MANUAL-ONLY on macOS 13 (Ventura), 14 (Sonoma), 15 (Sequoia) per 07-VALIDATION.md:
- Right-click / Control-click → Settings… and Quit only
- Left-click → popover opens with MenuView
- Settings… → focusable window, Recorder captures keys, re-open focuses existing window
- Red tint while `.recording`, absent during `.transcribing` / filing, reverts instantly on stop
- Quit → clean teardown via preserved `applicationShouldTerminate`

## Open Question 1: Recording Indicator Layer

The primary implementation uses `statusItem.button?.superview?.window?.contentView` layer
(`contentView.wantsLayer = true; contentView.layer?.backgroundColor = red`). This is the
recommended approach from RESEARCH.md to tint the status-item background area.

If `contentView` is `nil` on a given OS (e.g. early macOS 13.0), the nil-coalescing means
the update silently no-ops. The documented fallback would be `statusItem.button?.wantsLayer`
/ `statusItem.button?.layer?.backgroundColor`. UAT on macOS 13 should verify the tint appears;
if it does not, apply the button-layer fallback and note in 07-VALIDATION.md.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 — Missing Critical Functionality] Remove Recorder and `.onDisappear` from MenuView.swift**

- **Found during:** Task 1 (creating SettingsView.swift)
- **Issue:** The plan's `files_modified` list and task boundaries did not include MenuView.swift, but 07-PATTERNS.md clearly specifies two removals from it as part of this plan's execution. Leaving both the Recorder in MenuView AND the new SettingsView would result in duplicate Recorder UI. Leaving the `.onDisappear` didEndTrackingNotification post causes spurious hotkey un-pause when the NSPopover closes (Pitfall 10 — NSPopover does not post NSMenu tracking notifications).
- **Fix:** Removed the VStack Recorder block (lines 63–71) from the DisclosureGroup in MenuView.swift. Removed the `.onDisappear` modifier (lines 104–113). CLI Command TextField (D-04) and all other content preserved.
- **Files modified:** `Sources/MakeAnIssue/MenuView.swift`
- **Commit:** cee29fa (included in Task 1 commit)

## Known Stubs

None. SettingsView is minimal by design — Phase 8 will add the prompt-editor and reset-to-default UI.

## Threat Surface Scan

No new threat surface introduced beyond what the plan's threat register anticipated:
- T-07-01: Quit → `applicationShouldTerminate` preserved verbatim (mitigated)
- T-07-02: `NSApp.activate(ignoringOtherApps: true)` in `showSettingsWindow` and `togglePopover` — accepted per plan

## Self-Check: PASSED

- `Sources/MakeAnIssue/SettingsView.swift` exists: YES
- `Sources/MakeAnIssue/AppDelegate.swift` contains `func setUpStatusItem`: YES
- `Sources/MakeAnIssue/MakeAnIssueApp.swift` contains `Settings {`: YES
- Task commits: cee29fa, 9b4db57, 04482f8 — all present in git log
