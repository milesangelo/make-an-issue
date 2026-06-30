---
phase: 07-appkit-status-item-ui-settings-window-shell
verified: 2026-06-30T00:00:00Z
status: human_needed
score: 3/7 must-haves verified
behavior_unverified: 4
overrides_applied: 0
behavior_unverified_items:
  - truth: "Right-clicking or Control-clicking the menu-bar icon opens a menu containing exactly Settings… and Quit; left-clicking opens the status popover hosting MenuView"
    test: "Right-click the menu-bar icon, then separately left-click it with another app focused"
    expected: "Right-click shows exactly two items (Settings… and Quit); left-click shows the NSPopover with MenuView content"
    why_human: "NSStatusItem click routing and NSMenu presentation require a running macOS app on real hardware; grep cannot observe which event path fires at runtime"
  - truth: "Choosing Settings… opens a focusable self-owned window that can take real keyboard focus; re-opening focuses the existing window"
    test: "Choose Settings… from the right-click menu; click the Recorder and press a key; choose Settings… a second time without closing"
    expected: "Window appears and the Recorder captures the key press (no beep); a second Settings… invocation focuses the existing window rather than spawning a second one"
    why_human: "LSUIElement focus acquisition (NSApp.activate before makeKeyAndOrderFront) and single-window guard behavior require a running app; presence of the code path does not prove the OS grants focus"
  - truth: "While captureState == .recording the menu-bar icon shows a red tint; tint is absent during .transcribing/filing and reverts the instant recording stops"
    test: "Hold the push-to-talk shortcut; observe the menu-bar icon; release; trigger a transcription"
    expected: "Icon background turns red while recording, reverts immediately on release; no red tint appears during transcribing or filing"
    why_human: "NSStatusBarButton layer-backgroundColor rendering is not unit-testable; the contentView chain (superview?.window?.contentView) can return nil on certain macOS 13.x releases (Open Question 1); only a running app on each target OS confirms the tint appears"
  - truth: "The global push-to-talk shortcut continues to fire reliably across popover open/close and right-click menu open/close cycles with another app focused"
    test: "Focus Finder; open then close the status popover; press the shortcut. Repeat for the right-click menu. Also press shortcut while the popover is open."
    expected: "Shortcut fires and recording begins each time — no lockout caused by unbalanced menu-tracking state"
    why_human: "Cross-app empirical hotkey-survival behavior requires an interactive session; the presence of the removed .onDisappear workaround is a necessary but not sufficient condition (A4 closure)"
human_verification:
  - test: "Right-click / Control-click the menu-bar icon on macOS 13, 14, and 15"
    expected: "Menu with exactly two items: 'Settings…' and 'Quit' (separated by a divider); no app-name header or extra rows"
    why_human: "NSStatusItem + NSMenu presentation requires a running app"
  - test: "Left-click the menu-bar icon on macOS 13, 14, and 15"
    expected: "Status popover opens showing MenuView content (header, RepositoryCard, ActionCard, etc.)"
    why_human: "NSPopover show/hide requires a running app"
  - test: "Choose Settings… from the right-click menu; click the Recorder and press a key combination"
    expected: "The Settings window opens and the Recorder captures the key press. No second window spawns on re-open."
    why_human: "LSUIElement focus and single-window guard behavior require real hardware"
  - test: "Hold push-to-talk while watching the menu-bar icon; release; then trigger transcription"
    expected: "Red tint appears during recording, absent during transcribing, reverts on release. If tint is absent on macOS 13, apply the button-layer fallback from 07-01-SUMMARY.md and re-UAT."
    why_human: "NSStatusBarButton layer-background tinting requires a running app; Open Question 1 requires macOS 13 validation"
  - test: "Choose Quit from the right-click menu with an in-flight filing active"
    expected: "App exits cleanly; no orphaned 'claude' process or Docker container remains"
    why_human: "applicationShouldTerminate teardown (Phase 6 guard) requires a running app"
  - test: "Focus Finder; open then close the popover; press the push-to-talk shortcut. Repeat with the right-click menu. Also press the shortcut while the popover is open."
    expected: "Recording begins each time; no lockout"
    why_human: "Cross-app hotkey-survival (Pitfall 10 / A4) requires interactive verification"
---

# Phase 7: AppKit Status-Item UI + Settings Window Shell — Verification Report

**Phase Goal:** Right-clicking the menu-bar icon opens a Settings/Quit menu while left-click keeps the status popover, and the icon itself shows a live recording indicator — all on a self-owned AppKit shell that works across macOS 13–15.
**Verified:** 2026-06-30
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

Seven truths are drawn from the four ROADMAP success criteria plus three code-verifiable plan-specific must-haves.

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Right-click opens Settings…/Quit menu; left-click opens status popover (ROADMAP SC1) | PRESENT_BEHAVIOR_UNVERIFIED | `statusItemClicked(_:)` reads `NSApp.currentEvent` and branches to `showRightClickMenu()` vs `togglePopover()`. `showRightClickMenu()` uses assign-popUp-clear with exactly two menu items + separator. `popover.contentViewController` set to `NSHostingController(rootView: MenuView())`. All wired. Runtime behavior unverifiable without running app. |
| 2 | Settings window is focusable (LSUIElement) and single-instance (ROADMAP SC2) | PRESENT_BEHAVIOR_UNVERIFIED | `showSettingsWindow()` calls `NSApp.activate(ignoringOtherApps: true)` before `makeKeyAndOrderFront(nil)` (Pitfall 8/9). Single-window guard checks `settingsWindowController?.window?.isVisible`. `SettingsView` injected via `NSHostingController`. LSUIElement focus acquisition requires real hardware. |
| 3 | Recording indicator: red on `.recording`, absent on `.transcribing`/filing, reverts instantly (ROADMAP SC3) | PRESENT_BEHAVIOR_UNVERIFIED | `observeCaptureStateForIndicator()` subscribes `appState.$captureState`; sink passes `state == .recording` (exactly `.recording`, not other states). `updateRecordingIndicator()` sets `contentView?.layer?.backgroundColor` red or clear. No `contentTintColor` used. Visual rendering requires running app on macOS 13/14/15 (Open Question 1). |
| 4 | Push-to-talk shortcut fires reliably across popover/menu open-close cycles with another app focused (ROADMAP SC4) | PRESENT_BEHAVIOR_UNVERIFIED | `.onDisappear` menu end-tracking notification post removed from `MenuView`. `didEndTrackingNotification` absent from `MenuView.swift`. NSPopover does not unbalance menu tracking. Cross-app hotkey survival requires interactive UAT (Pitfall 10 / A4). |
| 5 | `applicationShouldTerminate` (Phase 6 teardown) preserved verbatim | VERIFIED | `applicationShouldTerminate` present at line 29 of `AppDelegate.swift`. `cancelAll()`, `forceKillAllProcessTrees()`, `sweepMCPTempFiles()` chain unchanged. No modifications to the method body. |
| 6 | Shortcut editor (Recorder) not in popover; Settings disclosure contains only the CLI Command field | VERIFIED | `grep -nE 'KeyboardShortcuts\.Recorder' MenuView.swift` returns no results. `DisclosureGroup` contains only `cliCommand` `TextField` (lines 61–83). `KeyboardShortcuts.Recorder` confirmed present in `SettingsView.swift` (line 12). |
| 7 | `ShortcutPillView` retained in `ActionCard` as read-only shortcut display | VERIFIED | `ShortcutPillView` at line 208 of `MenuView.swift` inside `ActionCard`. `struct ShortcutPillView` defined at line 361. `shortcutText` populated via `updateShortcutText()` calling `KeyboardShortcuts.getShortcut(for: .pushToTalk)`. |

**Score:** 3/7 truths verified | 4 present, behavior-unverified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/SettingsView.swift` | `struct SettingsView: View` hosting `KeyboardShortcuts.Recorder(name: .pushToTalk)` | VERIFIED | 22 lines. Imports `KeyboardShortcuts` and `SwiftUI` only — no `AppKit`. `Form` with `Section`, `VStack`, `.formStyle(.grouped)`, `.frame(width: 360)`, `.padding()`. |
| `Sources/MakeAnIssue/AppDelegate.swift` | NSStatusItem shell + popover + NSMenu + Settings window + recording indicator; `applicationShouldTerminate` preserved | VERIFIED | 170 lines. All required methods present: `setUpStatusItem`, `statusItemClicked`, `togglePopover`, `showRightClickMenu`, `showSettingsWindow`, `observeCaptureStateForIndicator`, `updateRecordingIndicator`. Imports `AppKit`, `Combine`, `SwiftUI`. |
| `Sources/MakeAnIssue/MakeAnIssueApp.swift` | `Settings { EmptyView() }` placeholder; no `MenuBarExtra` | VERIFIED | 15 lines. `Settings { EmptyView() }` at lines 11–13. `@NSApplicationDelegateAdaptor(AppDelegate.self)` preserved. `MenuBarExtra` appears only in a comment (line 8), not as a live scene declaration. |
| `Sources/MakeAnIssue/MenuView.swift` | Recorder block removed; `.onDisappear` workaround removed; `cliCommand` and `ShortcutPillView` retained | VERIFIED | `KeyboardShortcuts.Recorder` absent. `didEndTrackingNotification` absent. `cliCommand` at line 8 and line 68. `ShortcutPillView` at line 208 and line 361. `import KeyboardShortcuts` retained (still needed by `updateShortcutText()`). |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AppDelegate.statusItemClicked` | `showRightClickMenu()` / `togglePopover()` | `NSApp.currentEvent` right/left-click discrimination | WIRED | Line 95–102: reads `event.type == .rightMouseUp` or `.leftMouseUp + .control` → branches correctly. `sendAction(on: [.leftMouseUp, .rightMouseUp])` at line 87. |
| `AppDelegate.showRightClickMenu()` | Settings…/Quit NSMenu | assign-popUp-clear sequence | WIRED | Line 127–129: `statusItem.menu = menu` → `performClick(nil)` → `statusItem.menu = nil`. Prevents left-click popover lockout. Settings… item targets `#selector(showSettingsWindow)` with `target = self`. |
| `AppDelegate.showSettingsWindow()` | `SettingsView` via `NSHostingController` | `SettingsView().environmentObject(appState)` | WIRED | Line 138–148. `SettingsView()` injected. Single-window guard at line 133. `NSApp.activate` before `makeKeyAndOrderFront` at line 146. |
| `AppDelegate.observeCaptureStateForIndicator()` | `updateRecordingIndicator()` | `appState.$captureState` Combine sink | WIRED | Lines 153–160. `receive(on: RunLoop.main)`. Sink passes `state == .recording`. Stored in `cancellables`. |
| `AppDelegate.setUpStatusItem()` | `MenuView` via `NSHostingController` | `popover.contentViewController` | WIRED | Line 90–91: `popover.contentViewController = NSHostingController(rootView: MenuView().environmentObject(appState))`. |

---

### Data-Flow Trace (Level 4)

Not applicable: all modified artifacts are UI/shell wiring layers (AppKit status-item, popover, NSMenu, settings window). No artifact renders database-backed dynamic data beyond what was already wired before this phase. `AppState.captureState` flows to `updateRecordingIndicator` through a live Combine sink — the data path is Combine-wired, not fetch-based.

---

### Behavioral Spot-Checks

Step 7b: The phase produces runnable AppKit UI. All behaviors require NSStatusItem interaction within a running macOS process. None are testable via CLI-style spot-checks without a running app. SKIPPED — all runtime behaviors routed to human verification above.

---

### Probe Execution

No probes declared in PLAN frontmatter or SUMMARY. No `scripts/*/tests/probe-*.sh` matching this phase found. SKIPPED.

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| SETTINGS-01 | 07-01-PLAN.md, 07-02-PLAN.md | Right-clicking opens Settings…/Quit menu; left-click opens popover | SATISFIED (code) — HUMAN UAT PENDING | AppDelegate wiring present and complete. REQUIREMENTS.md traceability shows Phase 7 / Complete. Behavioral proof deferred to UAT per 07-VALIDATION.md. |
| FEEDBACK-02 | 07-01-PLAN.md | Menu-bar icon shows active-recording indicator while push-to-talk is held; reverts on stop | SATISFIED (code) — HUMAN UAT PENDING | `observeCaptureStateForIndicator()` + `updateRecordingIndicator()` wired. Condition is `state == .recording` only. Layer-background approach (not `contentTintColor`). Rendering on macOS 13/14/15 deferred to UAT. |

No orphaned requirements: REQUIREMENTS.md maps both SETTINGS-01 and FEEDBACK-02 to Phase 7 only. Both claim "Complete" in the traceability table. No additional Phase 7 requirement IDs found.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | — | — | — | — |

No TBD, FIXME, XXX, HACK, or unreferenced debt markers found in any file modified by this phase. `EmptyView()` in `MakeAnIssueApp.swift` is design-correct (the real window is the self-owned `NSWindowController`; the comment on line 8 explains the intent).

---

### Commit Verification

All commits claimed in SUMMARY.md verified present in git log:

| Hash | Message |
|------|---------|
| `cee29fa` | feat(07-01): create SettingsView hosting push-to-talk Recorder (D-03) |
| `9b4db57` | feat(07-01): add AppKit status-item shell + recording indicator to AppDelegate |
| `04482f8` | feat(07-01): replace MenuBarExtra scene with Settings { EmptyView() } placeholder |
| `ba37b10` | docs(07-02): complete MenuView reconciliation — 07-01 deviation covers full 07-02 scope |

---

### Human Verification Required

All four ROADMAP success criteria require manual UAT on macOS 13 (Ventura), 14 (Sonoma), and 15 (Sequoia) per the established 07-VALIDATION.md contract. The code structure is fully present and wired; the gap is runtime proof only.

#### 1. Right-click menu / left-click popover (ROADMAP SC1)

**Test:** Right-click (or Control-click) the menu-bar icon; then left-click it.
**Expected:** Right-click shows exactly two items — "Settings…" and "Quit" — with a separator; no app-name header or extra rows. Left-click shows the NSPopover with MenuView (header, RepositoryCard, ActionCard).
**Why human:** NSStatusItem click routing and NSMenu presentation require a running macOS app.

#### 2. Settings window focus and single-instance guard (ROADMAP SC2)

**Test:** Choose Settings…; click the push-to-talk Recorder in the window and press a key combination. Then choose Settings… again without closing.
**Expected:** The Recorder captures the key (no macOS "beep" indicating focus was denied). The second invocation raises the existing window rather than spawning a second one.
**Why human:** LSUIElement keyboard focus acquisition (NSApp.activate before makeKeyAndOrderFront) and the single-window guard require real hardware across macOS 13/14/15.

#### 3. Live recording indicator (ROADMAP SC3, FEEDBACK-02)

**Test:** Hold the push-to-talk shortcut while watching the menu-bar icon. Release. Then trigger a transcription (hold + speak briefly to enter transcribing state).
**Expected:** Menu-bar icon background turns red (semi-transparent) while recording; reverts the instant the shortcut is released. No red tint during transcribing or filing. If the tint does not appear on macOS 13, apply the button-layer fallback from 07-01-SUMMARY.md Open Question 1.
**Why human:** NSStatusBarButton `contentView` layer availability varies by macOS 13.x patch; visual rendering not inspectable without a running app.

#### 4. Push-to-talk shortcut survival across popover/menu cycles (ROADMAP SC4)

**Test:** With Finder focused: (a) open then close the status popover via left-click, then press the push-to-talk shortcut; (b) open then close the right-click menu, then press the shortcut; (c) press the shortcut while the popover is open.
**Expected:** Recording begins each time — the shortcut is not locked out by unbalanced menu-tracking state.
**Why human:** Cross-app hotkey survival (Pitfall 10 / Assumption A4) is an empirical runtime property; the code-level fix (removal of the `.onDisappear` workaround) is a necessary but not sufficient condition.

#### 5. Quit teardown (SETTINGS-01 / Phase 6 regression guard)

**Test:** With an in-flight filing active, choose Quit from the right-click menu.
**Expected:** App exits cleanly; `pgrep -f claude` and `docker ps` show no orphaned processes or containers.
**Why human:** `applicationShouldTerminate` teardown requires a running app with active filing jobs.

---

### Gaps Summary

No gaps. All code artifacts are present, substantive, and wired. The four open items are exclusively runtime behaviors that the PLAN, VALIDATION, and ROADMAP explicitly designated as MANUAL-ONLY UAT — they are not blocking deficiencies but pending human sign-off. The 07-VALIDATION.md `nyquist_compliant` and `wave_0_complete` flags should be updated after UAT completes.

---

_Verified: 2026-06-30_
_Verifier: Claude (gsd-verifier)_
