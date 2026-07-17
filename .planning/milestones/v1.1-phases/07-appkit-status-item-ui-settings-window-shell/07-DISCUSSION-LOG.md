# Phase 7: AppKit Status-Item UI + Settings Window Shell - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-30
**Phase:** 7-AppKit Status-Item UI + Settings Window Shell
**Areas discussed:** Recording indicator look, Settings window content, Popover content & dismiss, Right-click menu items

---

## Recording Indicator Look

| Option | Description | Selected |
|--------|-------------|----------|
| Tint the button red | Keep the glyph, apply a red tint/highlight to the NSStatusItem button while recording | ✓ |
| Swap to recording symbol | Replace the icon glyph (mic.fill / record.circle / waveform) while recording | |
| Red dot overlay | Keep the base icon, overlay a small red dot/badge | |

**User's choice:** Tint the button red.
**Notes:** Native "highlighted menu-bar button" feel preferred over symbol swap / dot badge.

### Follow-up: indicator scope

| Option | Description | Selected |
|--------|-------------|----------|
| Recording only | Tint only while `captureState == .recording`, revert on release | ✓ |
| Recording + transcribing | Also tint during the transcribing stage (second shade) | |

**User's choice:** Recording only.
**Notes:** Exactly FEEDBACK-02's scope; transcribing/filing feedback stays in the popover.

---

## Settings Window Content

| Option | Description | Selected |
|--------|-------------|----------|
| Empty shell + move shortcut | Focusable empty window, but move the push-to-talk Recorder into it; leave CLI field for Phase 8 | ✓ |
| Truly empty shell | Window opens/focuses with placeholder only; touch nothing in the popover | |
| Move shortcut + CLI field | Move both Recorder and CLI Command field into the window now | |

**User's choice:** Empty shell + move shortcut.
**Notes:** The Recorder needs real keyboard focus, which a transient popover fights (Pitfall 8) — a
real window is where it belongs. CLI field relocation stays Phase 8 (FINDING-06).

---

## Popover Content & Dismiss

| Option | Description | Selected |
|--------|-------------|----------|
| Keep disclosure as-is | Leave the inline Settings disclosure in the popover with the CLI field; just remove the Recorder | ✓ |
| Drop disclosure entirely | Remove the whole inline Settings disclosure from the popover this phase | |

**User's choice:** Keep disclosure as-is.
**Notes:** Read-only shortcut display (ShortcutPillView) stays, so the current shortcut is still
visible at a glance after the Recorder moves to the window.

### Follow-up: dismiss behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Transient (auto-close) | Standard menu-bar feel; closes on outside click / menu selection | ✓ |
| Semi-transient | Stays open on inside interaction; closes on outside click | |

**User's choice:** Transient (auto-close).
**Notes:** Safe because the only focus-sensitive editor (future prompt editor) lives in the Settings
window. Planning note recorded: CLI field in a transient popover needs `NSApp.activate` for focus and
could drop an in-progress edit (accepted — single-line field Phase 8 relocates).

---

## Right-Click Menu Items

| Option | Description | Selected |
|--------|-------------|----------|
| Settings… + Quit only | Exactly the two success-criteria items | ✓ |
| Add app header / repo | Prefix with a disabled header row (app name or bound-repo name) | |

**User's choice:** Settings… + Quit only.
**Notes:** Repo/shortcut context already lives in the left-click popover — no duplication.

---

## Claude's Discretion

Routed to research/planning (technical mechanics, already covered by v1.1 research — see CONTEXT.md):
- `button.target/action` + `sendAction(on:)` click discrimination (not `.menu`) — Pitfall 7
- Self-owned `NSWindow`/`NSWindowController` + `NSHostingController` Settings window (not the SwiftUI
  `Settings` scene / `SettingsLink` / `showSettingsWindow:`) — Pitfall 9; single-window focus-existing
- Accessory-app focus dance (`NSApp.activate` before `makeKeyAndOrderFront`) — Pitfall 8/9
- Re-tune the KeyboardShortcuts `.menuOpen` rebalance for the new shell — Pitfall 10
- Recording-indicator Combine sink binding (`captureState == .recording`)

## Deferred Ideas

- Editable system prompt + Reset-to-Default + FINDING-06 CLI-field relocation → Phase 8 (SETTINGS-02–05)
- Jobs list + per-job Stop + persistent error rows → Phase 9 (JOBS-01/02, RESIL-01)
- In-flight "Filing issue…" indicator → Phase 9 follow-up (from 06-UAT.md)
