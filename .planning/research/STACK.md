# Stack Research — v1.1 Concurrent Filing & Control

**Domain:** Native macOS menu-bar app (Swift 6 strict concurrency, SwiftUI + AppKit + Foundation)
**Researched:** 2026-06-28
**Confidence:** HIGH

> Scope: **additions only** for v1.1. The v1.0 stack (Swift 6, `MenuBarExtra`, `@MainActor` AppState,
> AVFoundation, KeyboardShortcuts, bundled whisper, `CLIRunner` over `Process` + `/bin/zsh -lc`) is
> already validated and is NOT re-researched here. This file names the **first-party APIs** needed for
> (1) cancel a running `Process` via Task cancellation, (2) replace `MenuBarExtra` with an
> `NSStatusItem`+`NSPopover`+`NSMenu` item that opens settings, and (3) an `@AppStorage`-backed editable
> prompt. **No new third-party dependencies are required or recommended.**

---

## Recommended Stack

### Core Technologies (all first-party, already in the toolchain)

| Technology | Version / Availability | Purpose | Why Recommended |
|------------|------------------------|---------|-----------------|
| `withTaskCancellationHandler(operation:onCancel:)` (Swift Concurrency) | macOS 10.15+ / Swift 5.5+ | Bridge cooperative Task cancellation to the imperative `Process.terminate()` call | The only correct way to make a `withCheckedContinuation`-wrapped subprocess respond to `Task.cancel()`. The `onCancel` closure fires the instant the Task is cancelled, even while the continuation is suspended. |
| `Task.isCancelled` / `Task.checkCancellation()` | macOS 10.15+ | Guard points around the run so a cancel before/after spawn is honored | Cheap checks; `checkCancellation()` throws `CancellationError` which the filing flow can map to a user-visible "cancelled" state rather than a failure. |
| `Foundation.Process` — `.terminate()` (SIGTERM), `.interrupt()` (SIGINT), `terminationStatus`, `terminationReason` | macOS 10.x+ | Kill the in-flight `claude` subprocess on cancel | Already the spawn mechanism (`CLIRunner`). `terminate()` is the documented, first-party way to stop a running `Process`. See **Pitfall: SIGTERM propagation** below — this is the one real gotcha. |
| `NSStatusBar.system.statusItem(withLength:)` → `NSStatusItem` | macOS 10.x+ (modern button API 10.10+) | The menu-bar item replacing `MenuBarExtra` | First-party; gives an `NSStatusBarButton` you fully control for left/right-click discrimination — which `MenuBarExtra` does not expose. |
| `NSPopover` + `NSHostingController<RootView>` | `NSPopover` 10.7+, `NSHostingController` 10.15+ (SwiftUI) | Left-click transient UI anchored to the status button; host the existing SwiftUI view tree | Lets you keep the current SwiftUI menu content while moving to AppKit hosting. `NSHostingController` wraps any SwiftUI `View` as an AppKit view controller. |
| `NSMenu` + `NSMenuItem` | macOS 10.x+ | Right-click context menu (Settings…, Quit, jobs/cancel actions) | Standard AppKit menu. Set transiently on the status button only for the right-click event (see pattern) so left-click still routes to the popover. |
| `NSWindow` + `NSWindowController` + `NSHostingController<SettingsView>` | 10.15+ (SwiftUI hosting) | **Self-owned Settings window** (recommended over SwiftUI `Settings` scene) | Opening a SwiftUI `Settings` scene programmatically from a menu-bar (`LSUIElement`/`.accessory`) app is **broken/fragile on macOS 14+** (see findings). A self-owned `NSWindow` hosting a SwiftUI settings view is fully programmatic, works identically on macOS 13/14/15, and you already own the AppKit layer. |
| SwiftUI `@AppStorage` / `UserDefaults.standard` | `@AppStorage` macOS 11.0+ | Persist + two-way bind the editable system prompt | `@AppStorage("systemPrompt")` gives a `Binding<String>` straight into a `TextEditor`; the filing code reads the same key from `UserDefaults.standard`. Matches the existing `asrCommandKey` shared-constant decision (Phase 03-02). |
| SwiftUI `TextEditor` | macOS 11.0+ | Multi-line editable prompt field | First-party multi-line editor; binds directly to the `@AppStorage` string. |
| `NSApp.activate(ignoringOtherApps:)` (macOS 13) / `NSApp.activate()` (macOS 14+) | 10.x+ / `activate()` 14.0+ | Bring the self-owned settings window forward from an `.accessory` app | An `LSUIElement` app has no Dock icon; a window won't become key without activating the app first. Required for the settings window to take focus. |

### Supporting APIs / Details

| API | Availability | Purpose | When to Use |
|-----|--------------|---------|-------------|
| `statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])` | 10.10+ | Make the status button fire its action target on **both** mouse buttons | Required to discriminate left vs right click in one action method. |
| `NSApp.currentEvent?.type == .rightMouseUp` | 10.x+ | Inside the action method, branch left (popover) vs right (menu) | Read the current event type rather than wiring two targets. |
| `NSPopover.behavior = .transient` | 10.7+ | Auto-dismiss popover when the user clicks away | Standard menu-bar popover UX. |
| `NSStatusItem.menu = menu` (set transiently) + `button.performClick(nil)` | 10.x+ | Show the right-click `NSMenu` | Assign `statusItem.menu` only for the right-click branch, then clear it in `menuDidClose(_:)` so left-clicks keep hitting your action (assigning `.menu` permanently disables the custom left-click action). |
| `Task<Void, Never>` handles stored in a `[JobID: Task<Void, Never>]` dictionary on `@MainActor` AppState | Swift 5.5+ | Track concurrent filing jobs; cancel one by id | `Task` is `Sendable`; storing/removing handles in a `@MainActor` class is safe. Cancel via `handle.cancel()`. |
| `Task { ... }` (unstructured, `@MainActor`-inheriting) per filing job | Swift 5.5+ | Fire-and-return concurrent background filings | Each spoken transcript spawns its own tracked `Task`; AppState returns to idle immediately (the v1.1 concurrency requirement). |
| `terminationReason == .uncaughtSignal` | 10.6+ | Distinguish "user cancelled" from "claude failed" | After `terminate()`, the process exits via signal; check `terminationReason` to label the job *cancelled* not *errored*. |
| `@AppStorage` default-not-persisted behavior | — | Keep AppState and the UI in sync | Until first edit, the key is absent from `UserDefaults`. AppState's filing path must read with the **same default fallback** the `@AppStorage` declares: `UserDefaults.standard.string(forKey:) ?? defaultPrompt`. Centralize key + default in one shared constant, exactly as `asrCommandKey` was. |

---

## The three integration recipes (concrete)

### 1. Cancel a running `Process` via Task cancellation

Wrap the existing `withCheckedContinuation` body in `withTaskCancellationHandler`. Keep the `Process`
reference behind the **existing NSLock-guarded `RunState`** — do not capture the `Process` directly into
the `onCancel` closure (it is not `Sendable`).

```
func run(...) async throws -> String {
    try Task.checkCancellation()                 // cancel-before-spawn
    let state = RunState()                        // NSLock-guarded; already exists
    return try await withTaskCancellationHandler {
        try await withCheckedContinuation { cont in
            let process = Process()
            // ... configure /bin/zsh -lc, pipes ...
            state.attach(process: process, continuation: cont)   // store under lock
            process.terminationHandler = { _ in state.resume(...) }
            try? process.run()
        }
    } onCancel: {
        state.cancel()   // locks, reads stored process, calls process.terminate()
    }
}
```

- `onCancel` runs **immediately on cancel, on an arbitrary thread/executor** — hence the lock. The
  existing single-resume `RunState` is exactly the right vehicle; add a `cancel()` that calls
  `terminate()` and a `terminated` flag so the resume path can label the result *cancelled*.
- **Swift 6 / Sendable:** `Process`, `Pipe`, and `CheckedContinuation` are **not `Sendable`**. Confining
  them inside the `NSLock`-guarded `RunState` (a `final class` you treat as a manual mutual-exclusion
  region) is the accepted escape hatch; mark `RunState` `@unchecked Sendable` since the lock provides the
  safety the compiler can't prove. This is the same shape the v1.0 code already uses — extend it, don't
  replace it.

### 2. `NSStatusItem` + left-click `NSPopover` / right-click `NSMenu` (replacing `MenuBarExtra`)

```
// AppDelegate (@MainActor, owns these for the app lifetime)
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = ...
statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
statusItem.button?.target = self
statusItem.button?.action = #selector(statusButtonClicked)

@objc func statusButtonClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
        statusItem.menu = buildRightClickMenu()      // set transiently
        statusItem.button?.performClick(nil)         // pops the menu
        // clear statusItem.menu in menuDidClose(_:) so left-click keeps working
    } else {
        togglePopover()                              // NSPopover w/ NSHostingController(rootView: MenuView())
    }
}
```

- **Swift 6 / actor isolation:** `NSStatusItem`, `NSPopover`, `NSMenu`, `NSWindow` are all
  **main-actor-isolated** in the Swift 6 SDK. Own them on a `@MainActor`-annotated `AppDelegate` (or
  `@MainActor final class`). No `Sendable` crossing occurs because everything stays on the main actor.
- `LSUIElement` (already set) is compatible — the status item is the app's only visible surface.

### 3. Self-owned Settings window + `@AppStorage` editable prompt

**Recommended:** a single retained `NSWindowController` whose `contentViewController` is
`NSHostingController(rootView: SettingsView())`. The right-click menu's "Settings…" item calls
`NSApp.activate(...)` then `window.makeKeyAndOrderFront(nil)`. Works on macOS 13/14/15 with no selector
games.

```
struct SettingsView: View {
    @AppStorage(PromptKey.id) private var systemPrompt = PromptKey.default
    var body: some View {
        TextEditor(text: $systemPrompt)   // edits persist to UserDefaults automatically
    }
}
// Filing code reads the same key:
let prompt = UserDefaults.standard.string(forKey: PromptKey.id) ?? PromptKey.default
```

> The app's "scoped tool grant + Issue-URL-on-last-line" contract must stay **outside** this editable
> field (concatenated by the filing code), so user edits to the prompt can't break the parser. Editable
> = *instructions only*, per the v1.1 requirement.

---

## Installation

No package changes. Everything ships with the macOS 13 SDK / Swift 6 toolchain already in use.

```bash
# No new dependencies. Confirm nothing third-party is added:
#   git diff -- Package.swift   # expect no new dependency lines for this milestone
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Self-owned `NSWindow` + `NSHostingController` for Settings | SwiftUI `Settings { }` scene + `SettingsLink` / `@Environment(\.openSettings)` | Only if you were a pure-SwiftUI `App` with a Dock icon. For an `LSUIElement` menu-bar app opening settings from an AppKit menu, the scene approach is **fragile on macOS 14+** (see What NOT to Use). |
| `withTaskCancellationHandler` + `Process.terminate()` | Polling `Task.isCancelled` in a loop and calling `terminate()` | Never preferred here — there's no loop; the task is suspended on the continuation, so only the cancellation **handler** can react promptly. |
| Full move to `NSStatusItem` | Keep `MenuBarExtra` and bolt on a hidden window for clicks | `MenuBarExtra` does **not** expose left/right-click discrimination or a controllable popover anchor; the v1.1 UI requires both, so the AppKit move is warranted. |
| One tracked `Task` per job in a `@MainActor` dictionary | `TaskGroup` / structured concurrency | A `TaskGroup` would block the parent until all children finish — the opposite of "return to idle immediately." Unstructured tracked `Task`s are correct for fire-and-forget concurrent filings. |
| `process.terminate()` (SIGTERM) | `process.interrupt()` (SIGINT) | Use `interrupt()` if `claude` traps SIGTERM but honors SIGINT (Ctrl-C semantics); worth testing which one cleanly stops an in-flight `claude -p`. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` to open Settings | The `showSettingsWindow:` selector was **removed in macOS 14**; it works on 13 but silently does nothing on 14+. A 13-only solution will break for most users. | Self-owned `NSWindow` + `NSHostingController` (works on all targets). |
| `SettingsLink` as the open mechanism | macOS 14+ only (excludes your 13 floor), is a **`Button` view** (can't be invoked from an `NSMenu` action), and is unreliable inside menu-bar contexts. | Self-owned settings window. |
| `@Environment(\.openSettings)` from the menu/AppDelegate | macOS 14+ only, requires a live SwiftUI render tree, needs an activation-policy toggle + timing hacks to work in an `.accessory` app, and is reported broken on later OSes. | Self-owned settings window. |
| Assigning `statusItem.menu` **permanently** | Once `.menu` is set, AppKit shows it on **any** click and your custom left-click `action` never fires — you lose the popover. | Set `.menu` only transiently for the right-click branch; clear it in `menuDidClose(_:)`. |
| Capturing `Process`/`Pipe`/`CheckedContinuation` directly into the `onCancel` closure | They are **not `Sendable`**; Swift 6 strict concurrency will reject it (or you'll get a data race). | Confine them in the `NSLock`-guarded `@unchecked Sendable` `RunState`; `onCancel` calls a `cancel()` method that locks. |
| `Process.waitUntilExit()` on the main thread / inside the continuation | Blocks; defeats concurrency and can deadlock the main actor. | Keep the existing async `terminationHandler` + continuation pattern. |
| Third-party menu-bar / settings packages (e.g. SettingsAccess, MenuBarExtraAccess) | The milestone explicitly wants **no new dependencies**; the self-owned-window approach removes the only reason teams reach for them. | First-party `NSWindow` + `NSHostingController`. |

---

## Critical pitfalls to flag for the roadmap

1. **SIGTERM does not always reach `claude`.** The runner spawns `/bin/zsh -lc "claude ..."`.
   `Process.terminate()` sends SIGTERM to the **zsh** process. If zsh has not `exec`'d into `claude`,
   the `claude` grandchild can be **orphaned and keep running** (and keep filing!). Mitigations, in order
   of preference:
   - Prefix the command with `exec ` (e.g. `zsh -lc "exec claude ..."`) so zsh **replaces itself** with
     `claude`; then `terminate()` hits `claude` directly. Simplest, first-party, no API change.
   - Or spawn in its own process group and signal the group (`posix_spawn` group / `kill(-pgid, SIGTERM)`),
     which is more code and crosses into POSIX. Prefer `exec` unless that proves insufficient.
   Needs an explicit verification step in the cancel phase (spawn, cancel, confirm no stray `claude`).

2. **`onCancel` thread + single-resume invariant.** The cancellation handler and the `terminationHandler`
   can race (user cancels exactly as the process exits). The existing single-resume `RunState`/NSLock must
   guarantee the continuation resumes **once**, and `cancel()` must be a no-op if already finished. This
   is the highest-risk concurrency surface in the milestone.

3. **`@AppStorage` default-not-persisted gap.** Until the user edits the prompt, the key is absent from
   `UserDefaults`. AppState's filing path must fall back to the **identical** default string, or it will
   send an empty/instruction-less prompt. Centralize key + default in one constant (reuse the
   `asrCommandKey` pattern from Phase 03-02). This also cleanly resolves **FINDING-06**: relocate the
   orphaned "CLI Command" field into this same Settings window using the same `@AppStorage` mechanism.

4. **Activation in an `LSUIElement` app.** The self-owned settings window won't take focus unless you call
   `NSApp.activate(ignoringOtherApps:)` (macOS 13) / `NSApp.activate()` (macOS 14+) **before**
   `makeKeyAndOrderFront`. Easy to miss; the window appears behind other apps otherwise.

---

## Version Compatibility

| API | Min macOS | Notes |
|-----|-----------|-------|
| `withTaskCancellationHandler`, `Task.isCancelled`, `Process.terminate()` | 13.0 (well below) | Fully available; no `#available` guard needed. |
| `NSStatusItem` button API, `NSPopover`, `NSMenu`, `NSHostingController` | 13.0 | All available. |
| `NSApp.activate()` (no-arg) | 14.0 | Use `activate(ignoringOtherApps: true)` on 13.0; branch with `#available(macOS 14, *)` to silence the 14 deprecation. |
| `SettingsLink`, `@Environment(\.openSettings)` | 14.0 | **Do not use** (see What NOT to Use) — listed only to mark them off-limits for the 13.0 floor. |
| `@AppStorage`, `TextEditor` | 13.0 | Available. |

---

## Sources

- Apple Developer Documentation — `NSStatusItem`, `withTaskCancellationHandler`, `Process` — first-party API availability (HIGH).
- steipete.me, "Showing Settings from macOS Menu Bar Items: A 5-Hour Journey" (2025) — confirms `showSettingsWindow:` removed in macOS 14 and that programmatic SwiftUI-`Settings`-scene opening from an `.accessory` app requires fragile hidden-window/activation-policy workarounds; motivates the self-owned-`NSWindow` recommendation (HIGH — cross-checked with rampatra blog + Apple Dev Forums thread 739831).
- blog.rampatra.com, "How to open the Settings view in a SwiftUI app on macOS 14 (Sonoma)" — `SettingsLink` is the only macOS-14 path and cannot be invoked programmatically (MEDIUM-HIGH).
- Medium (clyapp), "Implementing Left Click and Right Click for Menu Bar Status Button" + isapozhnik.com "NSStatusItem … and right-clicks" — `sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent` discrimination, and the transient-`.menu` caveat (MEDIUM, corroborated across two independent posts).

---
*Stack research for: macOS menu-bar app v1.1 (concurrency, AppKit status item, editable-prompt settings)*
*Researched: 2026-06-28*
