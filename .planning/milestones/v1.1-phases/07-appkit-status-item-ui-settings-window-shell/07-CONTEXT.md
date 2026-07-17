# Phase 7: AppKit Status-Item UI + Settings Window Shell - Context

**Gathered:** 2026-06-30
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace `MenuBarExtra` with a **self-owned AppKit `NSStatusItem` shell** that works across
macOS 13–15:

- **Left-click** opens the status popover (the existing `MenuView` content).
- **Right-click** opens an `NSMenu` with `Settings…` and `Quit`.
- Choosing `Settings…` opens a **focusable, self-owned `NSWindow`** (empty shell acceptable this
  phase) that can take keyboard focus in the accessory (`LSUIElement`) app.
- The menu-bar **icon shows a live recording indicator** while push-to-talk is held, visible with
  the popover closed, reverting when recording stops.
- The global push-to-talk shortcut continues firing reliably across popover/menu open-close cycles
  with another app focused.

Delivers: **SETTINGS-01, FEEDBACK-02**.

**Out of scope (own phases):** the editable system prompt + FINDING-06 CLI-field cleanup is
**Phase 8** (SETTINGS-02–05); the jobs list, per-job Stop, and error rows in the popover are
**Phase 9** (JOBS-01/02, RESIL-01). This phase ships the **shell** — the window is allowed to be
empty except for the one element we explicitly move into it (the shortcut Recorder).

</domain>

<decisions>
## Implementation Decisions

### Recording Indicator (FEEDBACK-02)
- **D-01:** While recording, **tint/highlight the `NSStatusItem` button red** (keep the
  `exclamationmark.bubble` glyph — do not swap the symbol or add a dot overlay). Revert to the
  default appearance the instant recording stops. Native "highlighted menu-bar button" feel.
- **D-02:** The indicator reflects **live recording only** (`captureState == .recording`). It does
  **not** light up during the transcribing stage or during background filing. One state drives it,
  matching FEEDBACK-02's exact wording. Transcribing/filing feedback stays in the popover.

### Settings Window Shell (SETTINGS-01)
- **D-03:** The Settings window is a **focusable but otherwise empty shell this phase**, with one
  exception: **move the push-to-talk shortcut `KeyboardShortcuts.Recorder` out of the popover and
  into the Settings window.** Rationale: the Recorder needs real keyboard focus, which a transient
  menu-bar popover fights (Pitfall 8) — a proper window is where it belongs. Phase 8 fills the rest
  of the window (editable prompt, Reset-to-Default, FINDING-06 CLI-field resolution).
- **D-04:** The orphaned **CLI Command field stays where it is** (in the popover's inline Settings
  disclosure) for this phase — its relocation/removal is **Phase 8's** FINDING-06 work. Do not
  move it now.

### Popover Content & Dismiss
- **D-05:** **Keep the popover's inline "Settings" disclosure**, minus the Recorder (which moved to
  the window per D-03). The disclosure retains only the CLI Command field for now. The popover's
  read-only shortcut *display* (`ShortcutPillView` in `ActionCard`) stays — the current shortcut is
  still visible at a glance even though the Recorder editor moved.
- **D-06:** The left-click popover is **transient** (auto-closes on outside click / menu selection)
  — standard menu-bar behavior, matching how `MenuBarExtra` behaves today. This is safe because the
  only focus-sensitive editor (the future prompt editor) lives in the Settings window, not the
  popover.
  - **Planning note:** the CLI Command field remaining in a *transient* popover means (a) the
    popover must `NSApp.activate(...)` for that `TextField` to take focus (Pitfall 8a), and (b) a
    transient outside-click could drop an in-progress CLI-field edit. Accepted as low-risk — it is a
    single-line field that Phase 8 relocates anyway (not a dwell-heavy multi-line editor).

### Right-Click Menu
- **D-07:** The right-click `NSMenu` contains **`Settings…` and `Quit` only** — exactly the success
  criteria. No app-name header row, no bound-repo row. Repo/shortcut context already lives in the
  left-click popover, so no duplication.

### Claude's Discretion (routed to research/planning — technical mechanics, already researched)
- **Status-item interaction model:** use `statusItem.button.target/action` with
  `sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent` to discriminate clicks —
  **NOT** `statusItem.menu` (which silently disables the left-click popover; Pitfall 7).
- **Settings window construction:** self-owned `NSWindow`/`NSWindowController` hosting SwiftUI via
  `NSHostingController` — **NOT** the SwiftUI `Settings` scene / `SettingsLink` / `showSettingsWindow:`
  (those diverge across macOS 13/14/15; Pitfall 9). Single-window (re-opening `Settings…` focuses the
  existing window rather than spawning a new one). Keep an empty `Settings {}`-or-equivalent Scene in
  `body` if the App protocol requires a Scene once `MenuBarExtra` is removed.
- **Accessory-app focus dance:** `NSApp.activate(ignoringOtherApps:)` before
  `makeKeyAndOrderFront`/`orderFrontRegardless` so the window takes focus from an `LSUIElement` app;
  validated on the macOS 13 floor.
- **Global hotkey survival:** the current `MenuView.onDisappear` posts
  `NSMenu.didEndTrackingNotification` to rebalance KeyboardShortcuts' `.menuOpen` mode. When
  `MenuBarExtra` is removed, **re-tune this empirically** under the new `NSPopover`/`NSMenu`
  open-close cycles — do not blindly carry it over (Pitfall 10). Verify the hotkey still fires with
  another app focused across popover and menu cycles.
- **Recording-indicator binding:** drive the button tint from `captureState == .recording` via a
  single Combine sink (the only Combine→AppKit bridge in the new shell).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase requirements & scope
- `.planning/ROADMAP.md` § "Phase 7: AppKit Status-Item UI + Settings Window Shell" — goal +
  4 success criteria.
- `.planning/REQUIREMENTS.md` — **SETTINGS-01** (right-click Settings…/Quit; left-click popover),
  **FEEDBACK-02** (live recording indicator on the icon). Note Phase 8 (SETTINGS-02–05) and Phase 9
  (JOBS-01/02, RESIL-01) depend on this shell.

### v1.1 research (the load-bearing technical guidance for this phase)
- `.planning/research/SUMMARY.md` § "Phase 3: AppKit Status-Item UI + Settings Window Shell" —
  recommended approach (NSStatusItem + NSPopover + NSMenu; self-owned NSWindow; `$filingJobs` badge
  sink; remove the `MenuBarExtra` `.onDisappear` workaround) and the macOS 13/14/15 verification
  checklist.
- `.planning/research/PITFALLS.md` — **Pitfall 7** (`.menu` disables left-click popover),
  **Pitfall 8** (LSUIElement popover focus + transient eats edits), **Pitfall 9** (macOS 13/14/15
  Settings divergence → self-owned window), **Pitfall 10** (`.menuOpen` hotkey rebalance). All four
  directly govern this phase.
- `.planning/research/ARCHITECTURE.md` — AppDelegate-owned status item; Combine→AppKit badge bridge.

### Prior-phase decisions that constrain this phase
- `.planning/phases/05-concurrent-filing-jobs-model/05-CONTEXT.md` — `@Published [FilingJob] jobs`
  is the source of truth the popover will eventually bind (Phase 9 renders it; the shell binds the
  model).
- `.planning/phases/06-cancellation-stop-control/06-CONTEXT.md` — D-01: no interim cancel
  affordance was built into the (now-being-replaced) `MenuBarExtra` menu; the popover/menu rewrite
  happens here. `AppDelegate.applicationShouldTerminate` quit-teardown already exists and must be
  preserved when the status item moves into `AppDelegate`.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Sources/MakeAnIssue/MenuView.swift` — the entire popover UI (header, RepositoryCard, ActionCard,
  StatusBanner, TranscriptCard, inline Settings disclosure). Reused **as the popover content** via
  `NSHostingController(MenuView())`. The Recorder (lines ~64–70) moves to the Settings window; the
  CLI Command field (lines ~73–80) stays. The `ShortcutPillView` shortcut display in `ActionCard`
  stays.
- `Sources/MakeAnIssue/AppDelegate.swift` — already an `NSApplicationDelegate` owning `appState`;
  this is where the `NSStatusItem`, `NSPopover`, and `NSMenu` get created (replacing the
  `MenuBarExtra` scene). `applicationShouldTerminate` quit-teardown (Phase 6 D-04) MUST be preserved.
- `Sources/MakeAnIssue/MakeAnIssueApp.swift` — `@main` `App` currently declares `MenuBarExtra`;
  this scene is replaced. Keep `@NSApplicationDelegateAdaptor(AppDelegate.self)`; provide a Scene in
  `body` as the toolchain requires once `MenuBarExtra` is gone.

### Established Patterns
- `AppState.captureState: CaptureState` (`.idle/.recording/.transcribing`) is the recording-state
  source — the red-tint indicator binds to `== .recording` (D-01/D-02). `@Published`, so a Combine
  sink in AppDelegate drives the button appearance.
- `KeyboardShortcuts.Name.pushToTalk` + the `.menuOpen` rebalance workaround in
  `MenuView.onDisappear` (lines 104–113) — must be re-tuned for the new shell (Pitfall 10).
- `MenuView` is `width: 320`, padded SwiftUI — sizes cleanly into an `NSPopover.contentViewController`.

### Integration Points
- `AppDelegate` gains ownership of `NSStatusItem`/`NSPopover`/`NSMenu` and the new Settings
  `NSWindowController`. Left-click action shows the popover; right-click shows the menu; `Settings…`
  shows the window; `Quit` → `NSApp.terminate` (preserving the existing terminate teardown).
- The recording-indicator Combine sink is the one Combine→AppKit bridge added this phase.

</code_context>

<specifics>
## Specific Ideas

- Recording indicator = **red tint on the button background**, glyph unchanged (user explicitly
  preferred this over a symbol swap or a dot badge).
- Settings window should feel like a *real window* (focusable, takes keyboard focus) — that's the
  whole reason the shortcut Recorder moves into it rather than staying in the transient popover.

</specifics>

<deferred>
## Deferred Ideas

- **Editable system prompt, Reset-to-Default, and FINDING-06 CLI-field relocation** → **Phase 8**
  (SETTINGS-02–05). The Settings window is intentionally an empty shell + Recorder this phase so
  Phase 8 has a focusable window to fill.
- **Jobs list, per-job Stop buttons, persistent error rows in the popover** → **Phase 9**
  (JOBS-01/02, RESIL-01). The shell binds the jobs model; Phase 9 renders rows.
- **In-flight "Filing issue…" indicator** (no UI feedback during background investigation today) —
  captured as a Phase 9 follow-up in `06-UAT.md`; not part of FEEDBACK-02's recording indicator.

None of the above is scope creep into Phase 7 — discussion stayed within the shell boundary.

</deferred>

---

*Phase: 7-AppKit Status-Item UI + Settings Window Shell*
*Context gathered: 2026-06-30*
