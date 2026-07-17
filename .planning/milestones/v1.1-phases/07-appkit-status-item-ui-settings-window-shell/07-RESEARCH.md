# Phase 7: AppKit Status-Item UI + Settings Window Shell — Research

**Researched:** 2026-06-30
**Domain:** Native macOS AppKit — NSStatusItem, NSPopover, NSMenu, NSWindow/NSHostingController, Combine→AppKit bridge, macOS 13/14/15 behavioral divergence
**Confidence:** HIGH (grounded in canonical research files already produced for this project plus targeted verification of phase-specific mechanics)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Recording Indicator (FEEDBACK-02)**
- **D-01:** While recording, tint/highlight the `NSStatusItem` button red (keep the `exclamationmark.bubble` glyph — do not swap the symbol or add a dot overlay). Revert to the default appearance the instant recording stops. Native "highlighted menu-bar button" feel.
- **D-02:** The indicator reflects live recording only (`captureState == .recording`). It does not light up during the transcribing stage or during background filing. One state drives it, matching FEEDBACK-02's exact wording. Transcribing/filing feedback stays in the popover.

**Settings Window Shell (SETTINGS-01)**
- **D-03:** The Settings window is a focusable but otherwise empty shell this phase, with one exception: move the push-to-talk shortcut `KeyboardShortcuts.Recorder` out of the popover and into the Settings window. Phase 8 fills the rest of the window.
- **D-04:** The orphaned CLI Command field stays in the popover's inline Settings disclosure for this phase — its relocation/removal is Phase 8's FINDING-06 work. Do not move it now.

**Popover Content & Dismiss**
- **D-05:** Keep the popover's inline "Settings" disclosure, minus the Recorder (which moved to the window per D-03). The disclosure retains only the CLI Command field for now. The popover's read-only shortcut display (`ShortcutPillView` in `ActionCard`) stays.
- **D-06:** The left-click popover is transient (auto-closes on outside click / menu selection) — standard menu-bar behavior, matching how `MenuBarExtra` behaves today. Accepted low-risk for the single-line CLI field.

**Right-Click Menu**
- **D-07:** The right-click NSMenu contains Settings… and Quit only — no app-name header row, no bound-repo row.

### Claude's Discretion (technical mechanics — research answers these)

- **Status-item interaction model:** use `statusItem.button.target/action` with `sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent` to discriminate clicks — NOT `statusItem.menu` (which silently disables the left-click popover; Pitfall 7).
- **Settings window construction:** self-owned `NSWindow`/`NSWindowController` hosting SwiftUI via `NSHostingController` — NOT the SwiftUI `Settings` scene / `SettingsLink` / `showSettingsWindow:` (those diverge across macOS 13/14/15; Pitfall 9). Single-window (re-opening Settings… focuses the existing window rather than spawning a new one). Keep an empty `Settings {}`-or-equivalent Scene in `body` if the App protocol requires a Scene once `MenuBarExtra` is removed.
- **Accessory-app focus dance:** `NSApp.activate(ignoringOtherApps:)` before `makeKeyAndOrderFront`/`orderFrontRegardless` so the window takes focus from an `LSUIElement` app; validated on the macOS 13 floor.
- **Global hotkey survival:** the current `MenuView.onDisappear` posts `NSMenu.didEndTrackingNotification` to rebalance KeyboardShortcuts' `.menuOpen` mode. When `MenuBarExtra` is removed, re-tune this empirically under the new `NSPopover`/`NSMenu` open-close cycles — do not blindly carry it over (Pitfall 10).
- **Recording-indicator binding:** drive the button tint from `captureState == .recording` via a single Combine sink.

### Deferred Ideas (OUT OF SCOPE)

- **Editable system prompt, Reset-to-Default, and FINDING-06 CLI-field relocation** → Phase 8 (SETTINGS-02–05).
- **Jobs list, per-job Stop buttons, persistent error rows in the popover** → Phase 9 (JOBS-01/02, RESIL-01).
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SETTINGS-01 | Right-clicking the menu-bar icon opens a menu with "Settings…" and "Quit"; left-click still opens the status popover | Click-discrimination pattern (sendAction + currentEvent); NSMenu build-and-show; Pitfall 7 avoidance |
| FEEDBACK-02 | While push-to-talk is held and recording is live, the menu-bar icon shows an active-recording indicator visible even when the popover is closed; reverts when recording stops | Red-tint approach (layer background on contentView); Combine sink binding to captureState; contentTintColor bug warning |
</phase_requirements>

---

## Summary

Phase 7 is a **structural replacement** of the SwiftUI `MenuBarExtra` scene with a self-owned AppKit shell: `NSStatusItem` + `NSPopover` (left-click) + `NSMenu` (right-click) + a self-owned `NSWindow`/`NSWindowController` Settings shell — all owned by `AppDelegate`, which already holds `appState`. This is not a greenfield phase; it grafts new AppKit shell ownership onto a proven architecture and preserves all existing Phase 5/6 infrastructure unchanged.

The most important technical decisions are already locked in CONTEXT.md (D-01 through D-07) and fully grounded in the canonical research (PITFALLS.md Pitfalls 7/8/9/10, ARCHITECTURE.md section d). This research phase amplifies those into plan-ready code patterns and calls out one new hazard not in the original research: **`NSStatusBarButton.contentTintColor` is broken on macOS 11+ (confirmed unfixed regression)** — the red recording indicator must use the `button?.superview?.window?.contentView` layer approach instead.

The KeyboardShortcuts hotkey workaround in `MenuView.onDisappear` should be removed (not carried over) because NSPopover does not trigger menu-tracking mode, and a real NSMenu posts genuinely balanced notifications. Empirical re-testing is mandatory before marking hotkey survival verified.

**Primary recommendation:** Implement in two tasks — (1) NSStatusItem/NSPopover/NSMenu shell + recording indicator Combine sink, (2) self-owned Settings NSWindowController + Recorder relocation + MenuView Recorder removal. The App.body Scene swap (`MenuBarExtra` → `Settings { EmptyView() }`) is a prerequisite executed in task 1.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Status item click handling | AppDelegate (AppKit) | — | `NSStatusItem` is an AppKit object; click discrimination requires `#objc` methods; cannot live in SwiftUI |
| Popover content rendering | SwiftUI (MenuView) | AppDelegate (hosts it) | Content is existing SwiftUI; AppDelegate wraps it via `NSHostingController` |
| Right-click menu | AppDelegate (AppKit) | — | Programmatic `NSMenu` with `NSMenuItem` instances |
| Recording indicator (red tint) | AppDelegate (AppKit) | AppState (source) | Bridges `@Published captureState` → AppKit layer via Combine sink |
| Settings window lifecycle | AppDelegate (AppKit) | SwiftUI (window content) | Self-owned `NSWindowController`; content is SwiftUI via `NSHostingController` |
| Push-to-talk Recorder | Settings window (SwiftUI) | — | Requires real keyboard focus; moved from transient popover per D-03 |
| Shortcut display (pill) | Popover / MenuView (SwiftUI) | — | Read-only display stays in popover per D-05 |
| Quit teardown | AppDelegate (`applicationShouldTerminate`) | — | Phase 6 implementation preserved |

---

## Standard Stack

### Core (all first-party, no new dependencies)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `NSStatusItem` | macOS 13+ SDK | Status bar icon + button | Only public API for menu-bar icons; manages icon lifetime |
| `NSPopover` | macOS 13+ SDK | Left-click popover hosting SwiftUI | Transient dismissal, anchor to status item button |
| `NSMenu` / `NSMenuItem` | macOS 13+ SDK | Right-click menu | Standard contextual menu; posts balanced tracking notifications |
| `NSHostingController` | macOS 13+ SDK | Bridge SwiftUI views into AppKit windows and popovers | First-party SwiftUI↔AppKit interop |
| `NSWindow` / `NSWindowController` | macOS 13+ SDK | Settings window with real focus | Avoids macOS 13/14 `showSettingsWindow:` divergence (Pitfall 9) |
| Combine (`AnyCancellable`) | macOS 13+ SDK | Bridge `@Published captureState` → AppKit button tint | Already used in the project; the one Combine→AppKit seam |
| `KeyboardShortcuts` (sindresorhus) | already present | Push-to-talk shortcut + Recorder | Unchanged dependency; Recorder moves from popover to Settings window |

**Installation:** No new packages. All first-party SDK + the existing `KeyboardShortcuts` dependency.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Self-owned NSWindow | SwiftUI `Settings` scene + `showSettingsWindow:` | Settings scene API diverges between macOS 13 and 14; self-owned window works identically on both |
| Layer background for red indicator | `NSStatusBarButton.contentTintColor` | `contentTintColor` is broken on macOS 11+ (shows black); layer approach is reliable |
| Combine sink for Combine→AppKit bridge | KVO | Combine is already the project's reactive pattern; KVO adds Objective-C boilerplate |

---

## Package Legitimacy Audit

No external packages are added in this phase. All code changes use first-party Apple SDK APIs and the existing `KeyboardShortcuts` dependency (already in the project, legitimacy not re-audited here).

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious:** none

---

## Architecture Patterns

### System Architecture Diagram

```
User Input
    │
    ├─── Left-click ──────────────────────────────────────────────────┐
    │                                                                  ▼
    │                                               NSPopover (transient)
    │                                                    │
    │                                               NSHostingController
    │                                                    │
    │                                               MenuView (existing SwiftUI)
    │                                               ├── Header, RepositoryCard, ActionCard
    │                                               ├── StatusBanner, TranscriptCard
    │                                               └── DisclosureGroup: CLI Command field only
    │                                                    (Recorder REMOVED from here)
    │
    ├─── Right-click ─────────────────────────────────────────────────┐
    │                                                                  ▼
    │                                               NSMenu (programmatic)
    │                                               ├── "Settings…" ──────────────────┐
    │                                               └── "Quit" → NSApp.terminate     │
    │                                                                                 │
    │                                               ┌─────────────────────────────────┘
    │                                               ▼
    │                                         NSWindowController
    │                                               │
    │                                         NSWindow (titled, focusable)
    │                                               │
    │                                         NSHostingController<SettingsView>
    │                                               │
    │                                         SettingsView (SwiftUI)
    │                                         └── KeyboardShortcuts.Recorder (moved from popover)
    │
    └─── captureState == .recording ─────────────────────────────────┐
         (Combine sink on AppState.$captureState)                     ▼
                                                         button?.superview?.window?.contentView
                                                         layer.backgroundColor = systemRed (α 0.3)
                                                         layer.cornerRadius = 4
                                                         (cleared when recording stops)

AppDelegate owns: statusItem, popover, cancellables, settingsWindowController
AppState owns: captureState, jobs (unchanged from Phase 5/6)
MakeAnIssueApp.body: Settings { EmptyView() }  ← minimal required Scene placeholder
```

### Recommended Project Structure

```
Sources/MakeAnIssue/
├── AppDelegate.swift        # ADD: setUpStatusItem(), statusItemClicked(_:),
│                            #      showRightClickMenu(), togglePopover(_:),
│                            #      showSettingsWindow(), observeCaptureStateForIndicator()
│                            #      PRESERVE: applicationShouldTerminate, sweepMCPTempFiles
├── MakeAnIssueApp.swift     # MODIFY: replace MenuBarExtra with Settings { EmptyView() }
├── MenuView.swift           # MODIFY: remove KeyboardShortcuts.Recorder (lines ~64-70)
│                            #          remove .onDisappear didEndTrackingNotification post
│                            #          CLI Command field stays in DisclosureGroup
├── SettingsView.swift       # NEW: SettingsView with KeyboardShortcuts.Recorder
└── [all other files unchanged]
```

### Pattern 1: NSStatusItem Click Discrimination (no .menu assignment)

**What:** Own all mouse events via `button.action`; branch on event type in the action selector.
**When to use:** Any NSStatusItem that needs different behavior for left vs right click. NEVER set `statusItem.menu` if the status item also shows a popover on left-click.

```swift
// Source: PITFALLS.md Pitfall 7; ARCHITECTURE.md section d [CITED: .planning/research/PITFALLS.md]
private func setUpStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.bubble",
                                       accessibilityDescription: "Make an Issue")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

    popover.behavior = .transient
    popover.contentViewController = NSHostingController(
        rootView: MenuView().environmentObject(appState))
}

@objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    let isRightClick = event.type == .rightMouseUp
        || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    if isRightClick {
        showRightClickMenu()
    } else {
        togglePopover(sender)
    }
}
```

### Pattern 2: Right-Click NSMenu — assign-popUp-clear

**What:** Build NSMenu programmatically, temporarily assign to status item for correct positioning, then clear.
**When to use:** When a status item needs a contextual menu without losing the left-click popover.

```swift
// Source: PITFALLS.md Pitfall 7 [CITED: .planning/research/PITFALLS.md]
@objc private func showRightClickMenu() {
    let menu = NSMenu()
    let settingsItem = NSMenuItem(title: "Settings…",
                                  action: #selector(showSettingsWindow),
                                  keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
    menu.addItem(quitItem)

    // Assign-popUp-clear: lets NSStatusItem position the menu correctly.
    // Clear immediately after so button.action is restored for next left-click.
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
}
```

### Pattern 3: NSPopover Toggle

**What:** Show/hide popover anchored to status item button; activate app first for LSUIElement context.
**When to use:** Every left-click on the status item button.

```swift
// Source: PITFALLS.md Pitfall 8a [CITED: .planning/research/PITFALLS.md]
private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
        popover.performClose(nil)
    } else {
        // Pitfall 8a: activate before showing so TextFields in the popover accept focus
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}
```

### Pattern 4: Recording Indicator — Layer Background

**What:** Drive a red background on the status item button's backing view via a Combine sink.
**When to use:** Single source of truth for recording state; revertes automatically when captureState changes.

**Critical pitfall:** `NSStatusBarButton.contentTintColor` is BROKEN on macOS 11+ (shows black regardless of color set — confirmed unfixed as of macOS 15 era). Do not use it. [ASSUMED: regression reported for macOS 11; no confirmed fix as of macOS 15]

```swift
// Source: blog.mastykarz.nl; ARCHITECTURE.md section d [CITED: https://blog.mastykarz.nl/add-background-color-menu-bar-icon-macos/]
private var cancellables = Set<AnyCancellable>()

private func observeCaptureStateForIndicator() {
    appState.$captureState
        .receive(on: RunLoop.main)
        .sink { [weak self] state in
            self?.updateRecordingIndicator(state == .recording)
        }
        .store(in: &cancellables)
}

private func updateRecordingIndicator(_ isRecording: Bool) {
    let contentView = statusItem.button?.superview?.window?.contentView
    contentView?.wantsLayer = true
    contentView?.layer?.backgroundColor = isRecording
        ? NSColor.systemRed.withAlphaComponent(0.3).cgColor
        : NSColor.clear.cgColor
    contentView?.layer?.cornerRadius = 4
}
```

**Timing:** Call `observeCaptureStateForIndicator()` from `applicationDidFinishLaunching` AFTER `setUpStatusItem()` (the contentView hierarchy is not available until the status item is created).

### Pattern 5: Self-Owned Settings NSWindowController

**What:** Single-window settings controller; re-opening focuses existing window; activation dance for LSUIElement app.
**When to use:** Any settings/preferences window from a menu-bar-only (LSUIElement) app.

```swift
// Source: PITFALLS.md Pitfall 9; ARCHITECTURE.md section d [CITED: .planning/research/PITFALLS.md]
private var settingsWindowController: NSWindowController?

@objc private func showSettingsWindow() {
    // Single-window: bring existing to front if already open
    if let controller = settingsWindowController, controller.window?.isVisible == true {
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return
    }
    let settingsView = SettingsView()
        .environmentObject(appState)
    let hostingController = NSHostingController(rootView: settingsView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.setContentSize(NSSize(width: 360, height: 180))  // size to Recorder + label
    window.center()
    let controller = NSWindowController(window: window)
    settingsWindowController = controller

    // Activation dance for LSUIElement app: activate BEFORE makeKeyAndOrderFront
    // so the window takes real keyboard focus (Pitfall 8 / Pitfall 9).
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
}
```

### Pattern 6: App.body Scene Placeholder

**What:** Minimal `Settings { EmptyView() }` scene to satisfy the `@main App` protocol after `MenuBarExtra` is removed.
**When to use:** Every AppKit-owned status item app built on the SwiftUI `@main App` struct.

```swift
// Source: PITFALLS.md Pitfall 9 [CITED: .planning/research/PITFALLS.md]
@main
struct MakeAnIssueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // MenuBarExtra replaced with NSStatusItem owned by AppDelegate.
        // This empty Settings scene is a required protocol-conformance placeholder;
        // the self-owned NSWindowController in AppDelegate handles the real settings window.
        Settings {
            EmptyView()
        }
    }
}
```

**Why `Settings` not `WindowGroup`:** `WindowGroup { EmptyView() }` may auto-open a blank window on launch. `Settings { EmptyView() }` never auto-shows (it only activates via the standard Preferences action, which is unreachable in an LSUIElement app with no app menu).

### Pattern 7: Remove MenuView.onDisappear Workaround

**What:** Delete the manual `NSMenu.didEndTrackingNotification` post from `MenuView.onDisappear`.
**When to use:** Whenever switching from `MenuBarExtra` to a self-owned `NSStatusItem`.

The workaround in `MenuView.onDisappear` (lines 104–113) posts `NSMenu.didEndTrackingNotification` manually because `MenuBarExtra(.window)` fires `didBeginTracking` with no balanced `didEndTracking`. Once on `NSStatusItem`:
- `NSPopover` does NOT post any NSMenu tracking notifications → the global hotkey is naturally in `.normal` mode during popover open/close.
- A real `NSMenu` posts genuinely balanced `didBeginTracking`/`didEndTracking` → the library correctly pauses during right-click tracking and resumes after.
- Carrying over the manual post can spuriously fire `didEndTracking` while the menu is still open, reintroducing flapping. [CITED: .planning/research/PITFALLS.md Pitfall 10]

```swift
// REMOVE this entire block from MenuView.onDisappear:
.onDisappear {
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
}
// The method itself may be removed if no other .onDisappear logic exists.
```

**Verification required (see Validation Architecture):** Before marking Pitfall 10 resolved, run the empirical hotkey survival test across all open/close cycles.

### Anti-Patterns to Avoid

- **Setting `statusItem.menu`:** Disables `button.action` entirely; left-click always opens the menu, never the popover. (Pitfall 7)
- **`NSStatusBarButton.contentTintColor`:** Broken on macOS 11+ — always renders black. Do not use for the recording indicator.
- **Two settings windows:** Store `settingsWindowController` in a `private var` on AppDelegate; always check `isVisible` before creating a new one.
- **Resuming `NSApp.activate` after `makeKeyAndOrderFront`:** The activation must come BEFORE `makeKeyAndOrderFront` or the window may appear without key focus on macOS 13.
- **Carrying over the manual `didEndTrackingNotification` post:** Can cause hotkey mode flapping under the new AppKit shell. Remove and re-test.
- **Releasing `statusItem`:** A local `var statusItem` in a method gets released and the icon vanishes. Must be a `private var statusItem: NSStatusItem!` stored property on AppDelegate.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Left/right click discrimination | Custom NSEvent monitor or subclass | `sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent` | Built into NSStatusBarButton; monitors are more fragile |
| SwiftUI in a window | Custom NSView layout | `NSHostingController(rootView:)` | First-party bridge; handles layout, sizing, and SwiftUI environment |
| Combine→AppKit bridge | Timer-based polling | Combine `$captureState.receive(on: RunLoop.main).sink {}` | Reactive, no polling, zero drift; already the project pattern |
| Settings window lifecycle | Multiple window tracking | Single `NSWindowController` stored on AppDelegate + `isVisible` check | Single source of truth; no orphaned windows |

**Key insight:** AppKit provides all the primitives needed. No SPM packages are required; the challenge is correct *composition* of first-party APIs, not finding libraries.

---

## Common Pitfalls

### Pitfall A: `statusItem.menu` silently disables the left-click popover

**What goes wrong:** Setting `statusItem.menu = someMenu` makes AppKit handle ALL clicks by opening that menu — `button.action` never fires, the popover never shows.
**Why it happens:** NSStatusItem has two mutually exclusive interaction models: `.menu` (AppKit owns all clicks) vs `button.action` (you own all clicks). They cannot coexist.
**How to avoid:** Never set `statusItem.menu` as a persistent assignment. Use the assign-popUp-clear pattern only for right-click menu display (Pattern 2 above).
**Warning signs:** Left-click always shows the menu; popover never appears.
[CITED: .planning/research/PITFALLS.md Pitfall 7]

### Pitfall B: `NSStatusBarButton.contentTintColor` is broken on macOS 11+

**What goes wrong:** Setting `button.contentTintColor = .systemRed` shows black in the menu bar instead of red. This is a confirmed Apple regression (FB8530353) with no public fix as of macOS 11–15.
**Why it happens:** AppKit regression in the status bar rendering path.
**How to avoid:** Use the `button?.superview?.window?.contentView` layer background approach (Pattern 4). Set `wantsLayer = true` and manipulate `layer.backgroundColor` directly.
**Warning signs:** Red color set in code but icon appears black (not red) in the menu bar.
[ASSUMED: regression confirmed for macOS 11+; status on macOS 13/14/15 not independently verified this session — risk: if Apple fixed it silently, layer approach still works]

### Pitfall C: Settings window opens without keyboard focus (LSUIElement app)

**What goes wrong:** The Settings window appears but the `KeyboardShortcuts.Recorder` (or any text field) ignores keystrokes — the window appears but the system doesn't consider it key.
**Why it happens:** macOS won't make a window key when the app has no Dock icon (`LSUIElement = YES`) unless the app is explicitly activated first.
**How to avoid:** Call `NSApp.activate(ignoringOtherApps: true)` BEFORE `makeKeyAndOrderFront(nil)`. On macOS 14+ the no-args `NSApp.activate()` is preferred but `ignoringOtherApps: true` works on both.
**Warning signs:** Window appears but clicking the shortcut Recorder shows focus ring but typing registers in the background app.
[CITED: .planning/research/PITFALLS.md Pitfall 8; Pitfall 9]

### Pitfall D: KeyboardShortcuts hotkey regression from carrying over the manual notification

**What goes wrong:** Manually posting `NSMenu.didEndTrackingNotification` under the new NSStatusItem shell can spuriously un-pause the hotkey *while the right-click menu is still open*, or fire an unbalanced end-tracking that causes the hotkey to flap (sometimes works, sometimes dead).
**Why it happens:** The workaround was reverse-engineered against `MenuBarExtra`'s specific buggy tracking behavior. Real `NSMenu` has correctly balanced notifications; adding a second end-tracking post breaks the balance.
**How to avoid:** Remove the `onDisappear` workaround entirely. Test empirically (see Validation Architecture). Re-add only a minimal, targeted fix if a real imbalance is measured.
**Warning signs:** Push-to-talk works only sometimes after interacting with the menu/popover; or hotkey fires during menu open.
[CITED: .planning/research/PITFALLS.md Pitfall 10]

### Pitfall E: Double settings window spawning

**What goes wrong:** Each click of "Settings…" opens a new NSWindowController + NSWindow, layering multiple settings windows behind each other.
**Why it happens:** No check for existing window before creating a new one.
**How to avoid:** Store `settingsWindowController: NSWindowController?` on AppDelegate; check `controller.window?.isVisible` before creating a new one (Pattern 5 above).
**Warning signs:** Multiple "Settings" windows in the Window menu; NSWindowController leaks.

---

## Code Examples

### Complete AppDelegate additions for Phase 7

```swift
// Source: ARCHITECTURE.md section d; PITFALLS.md Pitfalls 7/8/9/10
// [CITED: .planning/research/ARCHITECTURE.md; .planning/research/PITFALLS.md]

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()                         // UNCHANGED
    private let launchRequestStore = LaunchRequestStore()  // UNCHANGED
    private var statusItem: NSStatusItem!             // NEW — must be stored property
    private let popover = NSPopover()                 // NEW
    private var cancellables = Set<AnyCancellable>()  // NEW (Combine bridge)
    private var settingsWindowController: NSWindowController? // NEW

    func applicationDidFinishLaunching(_ notification: Notification) {
        consumeLatestLaunchRequest()   // UNCHANGED — must run first
        setUpStatusItem()              // NEW
        observeCaptureStateForIndicator() // NEW
    }

    // applicationShouldHandleReopen: UNCHANGED
    // applicationShouldTerminate: UNCHANGED — Phase 6 implementation preserved
    // sweepMCPTempFiles: UNCHANGED
    // consumeLatestLaunchRequest: UNCHANGED
}
```

### SettingsView.swift (new file)

```swift
// Source: KeyboardShortcuts documentation; CONTEXT.md D-03
// [CITED: https://github.com/sindresorhus/KeyboardShortcuts]
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Push-to-Talk Shortcut")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    KeyboardShortcuts.Recorder("", name: .pushToTalk)
                        .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding()
    }
}
```

### MenuView.swift — Recorder removal

```swift
// REMOVE lines ~64–70 (KeyboardShortcuts.Recorder block):
// VStack(alignment: .leading, spacing: 4) {
//     Text("Push-to-Talk Shortcut") ...
//     KeyboardShortcuts.Recorder("", name: .pushToTalk) ...
// }
// .padding(.top, 4)

// REMOVE .onDisappear block (lines ~104–113):
// .onDisappear {
//     NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
// }

// KEEP: CLI Command TextField in DisclosureGroup (per D-04)
// KEEP: ShortcutPillView display in ActionCard (per D-05)
// KEEP: All other view content unchanged
```

---

## Runtime State Inventory

> This is not a rename/refactor/migration phase — no rename of stored keys or identifiers occurs. Omit the full inventory table. The only state change is:

**MenuBarExtra removal:** The `MenuBarExtra` scene did not write to UserDefaults, disk, or any persistent store — its state was purely transient (scene presence). No migration needed.

**Existing UserDefaults keys** (`cliCommandKey` = "cliCommand"): Unchanged. The CLI Command field stays in the popover's DisclosureGroup (D-04).

**No runtime state migration required.**

---

## Validation Architecture

Nyquist validation is ENABLED (config.json `workflow.nyquist_validation: true`).

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (existing; see Tests/MakeAnIssueTests/) |
| Config file | Package.swift (existing test target) |
| Quick run command | `swift test --filter MakeAnIssueTests 2>&1` |
| Full suite command | `swift test 2>&1` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | Note |
|--------|----------|-----------|-------------------|------|
| SETTINGS-01 | Right-click opens NSMenu with Settings…/Quit | Manual only | N/A | NSStatusItem requires running app |
| SETTINGS-01 | Left-click opens NSPopover | Manual only | N/A | Requires running app |
| SETTINGS-01 | Settings… opens focusable window | Manual only | N/A | Requires running app + keyboard test |
| SETTINGS-01 | Recorder in Settings window accepts keystrokes | Manual only | N/A | Requires running app on real hardware |
| FEEDBACK-02 | Red indicator appears when captureState == .recording | Manual only | N/A | Requires running app |
| FEEDBACK-02 | Indicator absent during .transcribing | Manual only | N/A | Requires running app |
| FEEDBACK-02 | Indicator reverts instantly on recording stop | Manual only | N/A | Requires running app |
| HOTKEY | Push-to-talk fires after popover open/close with another app focused | Manual only | N/A | Empirical; cross-app |
| HOTKEY | Push-to-talk fires after menu open/close with another app focused | Manual only | N/A | Empirical; cross-app |
| BUILD | All existing tests pass after MenuBarExtra removal and MenuView edits | Automated | `swift test 2>&1` | Regression guard |

### Wave 0 Gaps

The existing test suite (AppStateTests, CLIRunnerTests, IssueFilingRunnerTests) covers model behavior. Phase 7 changes are purely in the AppKit shell layer — all behaviors require a running macOS app or simulated AppKit events, neither of which is practical in XCTest without significant mocking infrastructure.

**Required automated check for Phase 7:**
- [ ] Run `swift test 2>&1` after each plan to confirm no regressions in the model layer
- The full Phase 7 behavioral verification is the UAT checklist below

### Sampling Rate

- **Per task commit:** `swift test --filter AppStateTests 2>&1` (model regression guard, ~2s)
- **Per wave merge:** `swift test 2>&1` (full suite)
- **Phase gate:** Full suite green AND all UAT items below verified before `/gsd-verify-work`

### macOS Version UAT Checklist (manual — must run on all three)

The following must be verified manually on **macOS 13 (Ventura), macOS 14 (Sonoma), and macOS 15 (Sequoia)**:

```
[ ] Right-click opens NSMenu with exactly "Settings…" and "Quit"
[ ] Left-click opens the status popover (MenuView content)
[ ] Control-click treated as right-click (opens NSMenu)
[ ] "Settings…" opens the Settings window and brings it to front
[ ] Settings window accepts keyboard focus (click Recorder, press a key — it captures)
[ ] KeyboardShortcuts.Recorder in Settings window works (can change the shortcut)
[ ] Recorder removed from popover's Settings disclosure (only CLI Command remains there)
[ ] ShortcutPillView display still shows current shortcut in ActionCard (read-only)
[ ] Recording indicator appears (red background on button) while push-to-talk held
[ ] Recording indicator does NOT appear during transcribing state
[ ] Recording indicator does NOT appear during filing (any job state)
[ ] Recording indicator clears the instant recording stops
[ ] Re-opening Settings… while window is open focuses the existing window (no double)
[ ] Quit menu item exits the app cleanly (applicationShouldTerminate teardown runs)
[ ] Global push-to-talk fires after opening then closing the popover, with Finder focused
[ ] Global push-to-talk fires after opening then closing the right-click menu, with Finder focused
[ ] Global push-to-talk fires while the popover is open (it should, since NSPopover != NSMenu mode)
[ ] Existing filing/cancel behavior unchanged (regression check)
```

---

## Security Domain

`security_enforcement: true`, `security_asvs_level: 1`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Phase 7 adds no auth surface |
| V3 Session Management | No | Phase 7 adds no session handling |
| V4 Access Control | No | Settings window opens from the right-click menu; no authorization gate needed |
| V5 Input Validation | No | Phase 7 adds no new user-text input (the Recorder records key combos, not free text) |
| V6 Cryptography | No | No crypto in this phase |

### Known Threat Patterns for this Phase

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Quit menu item → process cleanup | Tampering | `NSApp.terminate(nil)` naturally triggers `applicationShouldTerminate` (Phase 6 teardown already handles this) |
| Settings window focus steal | Spoofing | `NSApp.activate(ignoringOtherApps: true)` is intentional; no user data exposed in empty shell |

**Net security impact:** Minimal. Phase 7 adds no new input surfaces, no new data stores, and no new network or subprocess calls. The right-click menu's "Quit" correctly routes through the existing Phase 6 teardown via `applicationShouldTerminate`.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SwiftUI `MenuBarExtra(.window)` | Self-owned `NSStatusItem` + `NSPopover` + `NSMenu` | macOS 13 → this phase | Enables left/right-click discrimination; eliminates MenuBarExtra tracking workaround |
| SwiftUI `Settings` scene + `showSettingsWindow:` | Self-owned `NSWindowController` | macOS 14 removed `showSettingsWindow:` | Works identically on macOS 13, 14, 15 |
| `NSStatusBarButton.contentTintColor` for tinting | Layer background on contentView | Broken since macOS 11 | Only reliable red-tint approach |

**Deprecated/outdated:**
- `showSettingsWindow:` selector: removed in macOS 14; **do not use**.
- `SettingsLink` / `openSettings`: macOS 14+ only; **do not use** (floor is macOS 13).
- `NSStatusItem.view` (custom view): deprecated since macOS 10.14; **do not use**.
- `NSStatusBarButton.contentTintColor`: broken since macOS 11; **do not use** for color changes.
- `MenuBarExtra` `.onDisappear` `didEndTrackingNotification` post: specific to MenuBarExtra's buggy behavior; **remove** when switching to NSStatusItem.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `button?.superview?.window?.contentView` layer approach for red background works reliably on macOS 13, 14, and 15 | Pattern 4; Pitfall B | If Apple changed the window hierarchy, this view may be nil → no indicator shown. Verify on real hardware during UAT. |
| A2 | `NSStatusBarButton.contentTintColor` remains broken on macOS 13/14/15 (regression reported for macOS 11+, no public fix) | Pitfall B | If Apple quietly fixed it, the layer approach still works correctly (no harm). Risk is only if contentTintColor was used — it isn't. |
| A3 | `Settings { EmptyView() }` compiles without warning and never creates visible UI in an LSUIElement app | Pattern 6 | If it auto-shows a settings window or generates a deprecation warning, use `WindowGroup { EmptyView() }.windowStyle(.hiddenTitleBar)` as an alternative. Verify at build time. |
| A4 | `NSPopover.behavior = .transient` does not trigger KeyboardShortcuts menu-tracking mode; hotkey remains in `.normal` during popover open | Pattern 7; Pitfall D | If NSPopover somehow triggers tracking mode (unlikely based on research), the manual didEndTracking post must be added back. Empirical UAT required. |

**If this table is empty:** All claims were verified — it is not empty; A1–A4 require macOS-version UAT to close.

---

## Open Questions

1. **Recording indicator depth on macOS 15**
   - What we know: The `button?.superview?.window?.contentView` layer approach works on macOS 11 (blog.mastykarz.nl). It is the standard recommendation across community sources.
   - What's unclear: Whether the contentView hierarchy is structurally identical on macOS 13/14/15 or if Sonoma/Sequoia changed the NSStatusBarButton backing window structure.
   - Recommendation: Test recording indicator on all three OS versions during UAT; if `contentView` is nil, fall back to `button.wantsLayer = true; button.layer?.backgroundColor = ...` directly on the button.

2. **KeyboardShortcuts hotkey under NSPopover (must be empirically verified)**
   - What we know: NSPopover does not post NSMenu tracking notifications. The manual post in `MenuView.onDisappear` was targeting MenuBarExtra's specific bug.
   - What's unclear: Whether KeyboardShortcuts has any other mechanism that reacts to popover state.
   - Recommendation: This is the UAT item "Global push-to-talk fires after popover open/close with Finder focused." It MUST be verified before the plan marks the phase complete.

3. **Settings window `NSWindow` sizing**
   - What we know: The Settings window hosts only `KeyboardShortcuts.Recorder` this phase.
   - What's unclear: The exact intrinsic size of `SettingsView` with just the Recorder and label. `NSHostingController` will size to the SwiftUI content automatically.
   - Recommendation: Use `.frame(width: 360)` for the form; let height size naturally. Adjust in implementation if the window appears too small/large.

---

## Environment Availability

> This phase modifies Swift source files only. No new external tools, services, or CLIs are required beyond the existing build environment.

| Dependency | Required By | Available | Notes |
|------------|------------|-----------|-------|
| Xcode (Swift/AppKit) | All code changes | ✓ | Already used for all prior phases |
| macOS 13 test machine | UAT item verification | Required | Floor of the deployment target |
| macOS 14 test machine | UAT item verification | Required | Settings API divergence point |
| macOS 15 test machine | UAT item verification | Recommended | Latest release; confirm no regressions |

**Missing dependencies with fallback:**
- macOS 14/15 test machines: If unavailable, note which OS versions were UAT'd and flag remaining as deferred verification debt.

---

## Sources

### Primary (HIGH confidence)
- `.planning/research/PITFALLS.md` — Pitfalls 7, 8, 9, 10 — direct prior research, grounded in Apple SDK behavior and cross-referenced sources
- `.planning/research/ARCHITECTURE.md` — Section d (AppDelegate AppKit shell ownership, Combine badge sink) and Section (a)/(b) context
- `.planning/research/SUMMARY.md` — Phase 3 entry, recommended approach, verification checklist
- Direct source reads: `AppDelegate.swift`, `MenuView.swift`, `MakeAnIssueApp.swift`, `AppState.swift` (current as of Phase 6 completion)

### Secondary (MEDIUM confidence)
- [https://blog.mastykarz.nl/add-background-color-menu-bar-icon-macos/](https://blog.mastykarz.nl/add-background-color-menu-bar-icon-macos/) — Layer background approach for NSStatusBarButton
- [https://github.com/feedback-assistant/reports/issues/144](https://github.com/feedback-assistant/reports/issues/144) — NSStatusBarButton.contentTintColor regression (macOS 11+, confirmed)
- [https://github.com/sindresorhus/KeyboardShortcuts/issues/1](https://github.com/sindresorhus/KeyboardShortcuts/issues/1) — NSMenu tracking mode behavior under KeyboardShortcuts
- [https://artlasovsky.com/fine-tuning-macos-app-activation-behavior](https://artlasovsky.com/fine-tuning-macos-app-activation-behavior) — NSApp.activate + makeKeyAndOrderFront activation pattern

### Tertiary (LOW confidence)
- WebSearch: Scene requirement after MenuBarExtra removal — corroborated `Settings { EmptyView() }` pattern
- WebSearch: NSStatusItem left/right click discrimination — corroborated ARCHITECTURE.md patterns

---

## Metadata

**Confidence breakdown:**

| Area | Level | Reason |
|------|-------|--------|
| Click discrimination pattern | HIGH | Grounded in PITFALLS.md Pitfall 7 (project canonical research) + multiple independent sources |
| Recording indicator (layer approach) | MEDIUM | Blog source + feedback-assistant bug report confirms contentTintColor is broken; layer approach not independently verified on macOS 13+ |
| Settings window self-owned NSWindowController | HIGH | Grounded in PITFALLS.md Pitfall 9 (project canonical research) — the divergence is documented and the self-owned approach is the recommended avoidance |
| KeyboardShortcuts hotkey under NSPopover | MEDIUM | Grounded in PITFALLS.md Pitfall 10; NSPopover not posting tracking notifications confirmed; empirical verification required |
| App.body scene placeholder | MEDIUM | Web sources confirm Settings scene + NSApplicationDelegateAdaptor works; EmptyView() variant is a reasonable inference |

**Research date:** 2026-06-30
**Valid until:** 2026-07-30 (stable macOS APIs; safe for 30 days)
