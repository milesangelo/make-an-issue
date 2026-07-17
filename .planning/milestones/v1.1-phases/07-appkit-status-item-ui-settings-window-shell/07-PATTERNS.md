# Phase 7: AppKit Status-Item UI + Settings Window Shell - Pattern Map

**Mapped:** 2026-06-30
**Files analyzed:** 4 (3 modified, 1 new)
**Analogs found:** 4 / 4

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Sources/MakeAnIssue/AppDelegate.swift` | delegate / AppKit shell | event-driven + pub-sub | `Sources/MakeAnIssue/AppDelegate.swift` (self — additions only) | self |
| `Sources/MakeAnIssue/MakeAnIssueApp.swift` | app entry point | — | `Sources/MakeAnIssue/MakeAnIssueApp.swift` (self — scene swap) | self |
| `Sources/MakeAnIssue/MenuView.swift` | component | request-response | `Sources/MakeAnIssue/MenuView.swift` (self — removals only) | self |
| `Sources/MakeAnIssue/SettingsView.swift` | component | request-response | `Sources/MakeAnIssue/MenuView.swift` DisclosureGroup block | role-match |

---

## Pattern Assignments

### `Sources/MakeAnIssue/AppDelegate.swift` (MODIFIED — additions only)

**Analog:** Self. All additions land in this existing file; existing methods are preserved verbatim.

**Current stored properties** (lines 1–8 — establish the baseline to preserve):
```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let launchRequestStore = LaunchRequestStore()
```

**New stored properties to add** (insert after line 7, before `applicationDidFinishLaunching`):
```swift
    // Phase 7 additions — AppKit status-item shell
    private var statusItem: NSStatusItem!           // must be stored property; local var = released + icon vanishes
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindowController: NSWindowController?
```

**`applicationDidFinishLaunching` — current** (line 9–11, PRESERVE + extend):
```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        consumeLatestLaunchRequest()
    }
```
Becomes:
```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        consumeLatestLaunchRequest()   // UNCHANGED — must run first
        setUpStatusItem()              // NEW
        observeCaptureStateForIndicator() // NEW — after setUpStatusItem so contentView hierarchy exists
    }
```

**`applicationShouldTerminate` — PRESERVE VERBATIM** (lines 19–36):
```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.jobs.contains(where: { $0.state == .filing }) else {
            Self.sweepMCPTempFiles()
            return .terminateNow
        }
        appState.cancelAll()
        Self.sweepMCPTempFiles()
        Task { @MainActor in
            defer { NSApp.reply(toApplicationShouldTerminate: true) }
            try? await Task.sleep(for: .seconds(2))
            appState.forceKillAllProcessTrees()
            Self.sweepMCPTempFiles()
        }
        return .terminateLater
    }
```

**Status-item setup — new method** (click-discrimination pattern; do NOT set `statusItem.menu` persistently):
```swift
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
```

**Click handler — new `@objc` method** (discriminates left vs right; control-click = right):
```swift
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

**Popover toggle — new method** (activate before show so TextField in popover accepts focus — Pitfall 8a):
```swift
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
```

**Right-click menu — new method** (assign-popUp-clear pattern; D-07 = Settings… and Quit only):
```swift
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
        // assign-popUp-clear: positions menu correctly; clears so button.action fires next left-click
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
```

**Settings window — new method** (single-window; re-opening focuses; activate before makeKeyAndOrderFront):
```swift
    @objc private func showSettingsWindow() {
        if let controller = settingsWindowController, controller.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingController = NSHostingController(
            rootView: SettingsView().environmentObject(appState))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)   // BEFORE makeKeyAndOrderFront (Pitfall 8/9)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
```

**Recording indicator — Combine sink** (layer background on contentView; NOT contentTintColor which is broken on macOS 11+):
```swift
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

**Import to add** — `AppDelegate.swift` currently only imports `AppKit`. Add `Combine` and `SwiftUI`:
```swift
import AppKit
import Combine
import SwiftUI
```

---

### `Sources/MakeAnIssue/MakeAnIssueApp.swift` (MODIFIED — scene swap only)

**Analog:** Self. One change: replace `MenuBarExtra` scene with `Settings { EmptyView() }`.

**Current body** (lines 7–13, REPLACE entirely):
```swift
    var body: some Scene {
        MenuBarExtra("Make an Issue", systemImage: "exclamationmark.bubble") {
            MenuView()
                .environmentObject(appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
```

**New body** (Settings scene = required protocol-conformance placeholder; never auto-shows in LSUIElement app):
```swift
    var body: some Scene {
        // NSStatusItem owned by AppDelegate replaces MenuBarExtra.
        // Settings scene is a required protocol-conformance placeholder;
        // the real window is the self-owned NSWindowController in AppDelegate.
        Settings {
            EmptyView()
        }
    }
```

**Lines 1–6 PRESERVE VERBATIM:**
```swift
import SwiftUI

@main
struct MakeAnIssueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

---

### `Sources/MakeAnIssue/MenuView.swift` (MODIFIED — two removals only)

**Analog:** Self. Remove exactly two blocks; all other content stays untouched.

**REMOVE block 1 — KeyboardShortcuts.Recorder** (lines 63–71, within the DisclosureGroup VStack):
```swift
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Push-to-Talk Shortcut")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        KeyboardShortcuts.Recorder("", name: .pushToTalk)
                            .labelsHidden()
                    }
                    .padding(.top, 4)
```
The DisclosureGroup VStack continues with the CLI Command block (lines 73–80) which is KEPT per D-04.

**REMOVE block 2 — `.onDisappear` workaround** (lines 104–113):
```swift
        .onDisappear {
            // KeyboardShortcuts pauses the global Carbon hotkey and falls back to a
            // focus-only local key monitor whenever it believes a menu is open
            // ...
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        }
```
NSPopover does not post NSMenu tracking notifications; carrying this over can spuriously un-pause the hotkey. Remove the modifier entirely (Pitfall 10 / RESEARCH.md Pattern 7).

**KEEP VERBATIM — everything else:**
- `import AppKit` / `import KeyboardShortcuts` / `import SwiftUI` (line 1–3)
- `@EnvironmentObject private var appState: AppState` (line 6)
- `@AppStorage(AppState.cliCommandKey) private var cliCommand` (line 8)
- Header, RepositoryCard, ActionCard, StatusBanner, TranscriptCard (lines 14–58)
- DisclosureGroup label and CLI Command TextField (lines 61–93, minus Recorder block)
- `ShortcutPillView` in `ActionCard` (line 228) — read-only display stays per D-05
- `.onAppear` / `.onReceive` modifiers (lines 98–103)
- `updateShortcutText()` / `shouldShowStatusBanner` (lines 116–127)
- All subview structs (StateBadge, RepositoryCard, ActionCard, …, TranscriptCard, CopyButton) (lines 131–539)

---

### `Sources/MakeAnIssue/SettingsView.swift` (NEW)

**Analog:** `Sources/MakeAnIssue/MenuView.swift` — specifically the removed Recorder block (lines 63–71) which this file re-homes. The Form+Section+VStack layout follows the closest available project SwiftUI pattern.

**Import pattern** (copy from MenuView lines 1–3, drop `AppKit`):
```swift
import KeyboardShortcuts
import SwiftUI
```

**Core pattern** (Recorder block from MenuView re-homed in a Form; `.formStyle(.grouped)` matches macOS Settings convention; `.frame(width: 360)` from RESEARCH.md Pattern 5):
```swift
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

No `@EnvironmentObject` needed for this phase — the Recorder reads/writes via `KeyboardShortcuts.Name.pushToTalk` directly, which is a shared singleton (same pattern as existing MenuView Recorder usage at line 68).

---

## Shared Patterns

### Combine `@Published` → AppKit bridge
**Source:** `Sources/MakeAnIssue/AppState.swift` (lines 2, 28 — `import Combine`, `@Published var captureState: CaptureState = .idle`)
**Apply to:** `AppDelegate.swift` — `observeCaptureStateForIndicator()` + `cancellables` stored property
```swift
// AppState.swift line 2
import Combine
// AppState.swift line 28
@Published var captureState: CaptureState = .idle
```
Pattern: subscribe via `appState.$captureState.receive(on: RunLoop.main).sink { }.store(in: &cancellables)`.

### NSHostingController SwiftUI embedding
**Source:** Established in `MakeAnIssueApp.swift` (MenuBarExtra body wrapping `MenuView().environmentObject(appDelegate.appState)`)
**Apply to:** Both NSPopover content and Settings NSWindowController in `AppDelegate.swift`
```swift
// Pattern: wrap SwiftUI view + inject appState environment
NSHostingController(rootView: MenuView().environmentObject(appState))
NSHostingController(rootView: SettingsView().environmentObject(appState))
```

### `@NSApplicationDelegateAdaptor` + `appState` threading
**Source:** `MakeAnIssueApp.swift` line 5; `AppDelegate.swift` lines 3–5
**Apply to:** All new AppDelegate methods must be `@MainActor`-safe (the class is already marked `@MainActor final class AppDelegate`)
```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
```

### LSUIElement focus activation
**Source:** `AppDelegate.swift` line 15 (`applicationShouldHandleReopen` already calls `sender.activate(ignoringOtherApps: true)`)
**Apply to:** `togglePopover(_:)` and `showSettingsWindow()` — both must call `NSApp.activate(ignoringOtherApps: true)` before showing UI
```swift
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        consumeLatestLaunchRequest()
        sender.activate(ignoringOtherApps: true)   // ← precedent for activation pattern
        return true
    }
```

---

## No Analog Found

No files in this phase lack an analog. All four files are either self-modifications or have a clear role-match in the existing codebase.

---

## Anti-Patterns (from RESEARCH.md — must not appear in implementation)

| Anti-Pattern | Why | What to do instead |
|---|---|---|
| `statusItem.menu = menu` (persistent) | Disables `button.action`; left-click never fires popover | assign-popUp-clear in `showRightClickMenu()` only |
| `NSStatusBarButton.contentTintColor = .systemRed` | Broken macOS 11+ regression (shows black) | Layer background on `button?.superview?.window?.contentView` |
| `var statusItem` as local variable | Gets released; menu-bar icon vanishes | `private var statusItem: NSStatusItem!` stored property |
| `NSApp.activate` after `makeKeyAndOrderFront` | Window appears without key focus on macOS 13 | Activate BEFORE `makeKeyAndOrderFront` |
| Carrying over `.onDisappear` `didEndTrackingNotification` post | Spurious un-pause with real NSMenu; hotkey flapping | Remove entirely; re-test empirically |
| `showSettingsWindow:` selector | Removed in macOS 14 | Self-owned `NSWindowController` |

---

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/`
**Files scanned:** 3 source files read in full
**Pattern extraction date:** 2026-06-30
