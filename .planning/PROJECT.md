# make-an-issue

## What This Is

A native macOS menu-bar utility that turns a spoken thought into a GitHub issue for the
git repository you are working in. You launch it with a repo-local command (which binds it
to that repo), hold a global shortcut to talk, and the app transcribes your speech with a
local ASR CLI, investigates the repo with a local model CLI, files the issue automatically
with `gh issue create`, and speaks "created issue #NUMBER" back to you.

## Core Value

Capture a repo-aware GitHub issue by voice in seconds, without leaving the keyboard or
opening a browser — the full path from spoken word to filed issue must work end to end.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — ship to validate)

### Active

<!-- Current scope. Building toward these (v1 happy path). See REQUIREMENTS.md for detail. -->

- [ ] Repo-local command launches/activates the menu-bar app and binds it to the repo
- [ ] Global push-to-talk shortcut captures microphone audio while held
- [ ] Recording is transcribed by a user-configured local ASR CLI
- [ ] Bound repo is investigated by a user-configured local model CLI to draft the issue
- [ ] Issue is created automatically via `gh issue create` and the number is spoken aloud

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Always-listening wake phrase — push-to-talk is simpler, more private, and avoids false triggers
- Embedded/in-app model runtime — local models are reached through configured CLIs, not hosted in-app
- Multi-repo switching UI — repo binding comes from the launching command's working directory in v1
- Manual title/body review screen — v1 files automatically; review is a v2 concern
- Advanced failure recovery (retries, queuing, partial-state repair) — beyond v1; basic clear errors only

## Context

- Greenfield project. Workspace was empty at initialization; git was initialized for planning.
- Target platform is macOS 13+ (native Swift/SwiftUI `MenuBarExtra`, AppKit where needed).
- The user already has local ASR and repo-investigation models usable via CLI commands/scripts.
- The user has `gh` installed and authenticated.
- The app shells out to external CLIs (`gh`, ASR, model), so the v1 build runs **non-sandboxed**;
  global shortcuts and microphone capture require Input Monitoring/Accessibility and Microphone
  permissions.

## Constraints

- **Tech stack**: Native macOS app — Swift + SwiftUI/AppKit. Why: native menu-bar, global shortcut, audio capture, and TTS are first-class on macOS.
- **Platform**: macOS 13.0+ minimum. Why: `MenuBarExtra` and modern `SMAppService` APIs.
- **Dependencies**: Relies on user-provided `gh`, ASR CLI, and model CLI on `PATH`/configured paths. Why: keeps the app thin and avoids bundling model runtimes.
- **Sandboxing**: v1 is not App-Sandboxed. Why: App Sandbox blocks spawning arbitrary external CLIs.
- **Scope**: v1 is happy-path only, ready for hands-on manual testing — not production hardening.

## Key Decisions

<!-- Decisions that constrain future work. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Native Swift menu-bar app (`MenuBarExtra` + `LSUIElement`) | First-class menu-bar, hotkey, audio, TTS on macOS | — Pending |
| Global shortcut push-to-talk, not wake phrase | Simpler, private, no false triggers | — Pending |
| Local models invoked via configured CLI commands | Avoids embedded runtimes; reuses user's setup | — Pending |
| Repo binding from launching command's working directory | No multi-repo UI needed in v1 | — Pending |
| Automatic issue creation (no review screen) in v1 | Fastest path; review deferred to v2 | — Pending |
| Issue creation via `gh issue create` | Uses existing auth; no GitHub API client needed | — Pending |
| v1 build runs non-sandboxed | App Sandbox blocks external CLI execution | — Pending |

---
*Last updated: 2026-06-23 after project initialization*
