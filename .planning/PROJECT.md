# make-an-issue

## What This Is

A native macOS menu-bar utility that turns a spoken thought into a tracker issue (GitHub or
Jira) for the git repository you are working in. You launch it with a repo-local command (which
binds it to that repo), hold a global shortcut to talk, and the app transcribes your speech with
a **bundled** whisper model (zero setup), then hands the transcript to **your own AI coding CLI**
(`claude`/`codex`) running in the repo — which investigates the repo, drafts the issue, and
**files it through its already-configured MCP server** (GitHub or Atlassian/Jira). The app then
speaks "created issue #NUMBER" back to you. The app holds no API tokens; it rides the AI CLI's
existing auth.

## Core Value

Capture a repo-aware GitHub issue by voice in seconds, without leaving the keyboard or
opening a browser — the full path from spoken word to filed issue must work end to end.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ Repo-local command launches/activates the menu-bar app and binds it to the repo — Phase 1
- ✓ Global push-to-talk shortcut captures microphone audio while held — Phase 2
- ✓ Speech-to-transcript pipeline (capture → ASR → transcript display) works end to end — Phase 3
  <sub>(shipped via a user-configured ASR CLI; mechanism being **replaced by a bundled whisper model** — see Active)</sub>

### Active

<!-- Current scope. Building toward these (v1 happy path). Realigned 2026-06-25 — see REQUIREMENTS.md + notes/v1-realign-bundled-whisper-ai-cli-mcp.md -->

- [ ] Transcription uses a **bundled** whisper model — zero config, no user ASR command (Phase 3 rework)
- [ ] The user's AI CLI (`claude`/`codex`), run in the bound repo, **drafts and files** the issue via its own MCP (GitHub or Atlassian/Jira) — no `gh`, no API token (Phase 4, merged)
- [ ] The created issue number/URL is parsed from the CLI output and spoken aloud (Phase 4, merged)
- [ ] Backend is provider-agnostic; `codex` + Jira are spike-gated v1 targets (Phase 4, merged)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Always-listening wake phrase — push-to-talk is simpler, more private, and avoids false triggers
- Embedded/in-app **LLM** runtime — the drafting/filing LLM is the user's own AI CLI + MCP, not hosted in-app (a **STT** model *is* now bundled — whisper.cpp — for zero-config transcription)
- App-held GitHub auth / `gh issue create` — retired 2026-06-25; the AI CLI files via its own MCP (OAuth), app holds no tokens
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
| Global shortcut push-to-talk, not wake phrase | Simpler, private, no false triggers | Validated in Phase 2 (KeyboardShortcuts global Carbon hotkey) |
| Local models invoked via configured CLI commands | Avoids embedded runtimes; reuses user's setup | CLIRunner pattern validated in Phase 3; **scope narrowed 2026-06-25** — STT is now a bundled whisper model (not a user CLI); the LLM is the user's AI coding CLI (`claude`/`codex`) |
| **Bundle whisper.cpp + model; drop user ASR config** (2026-06-25) | Zero-config + best accuracy on technical vocab for enterprise teammates | — Pending (Phase 3 rework; requires signing/notarizing the bundled binary) |
| **AI CLI drafts AND files the issue via its own MCP** (2026-06-25) | Enterprise users have GitHub/Atlassian MCP on their cloud subscription and forbid API tokens; collapses Phases 4+5 and removes `gh` | — Pending (Phase 4 merged; `codex` + Jira spike-gated) |
| **No app-held tokens; one-time OAuth per provider OK** (2026-06-25) | App never handles credentials; rides the AI CLI's existing MCP OAuth session | — Pending |
| Repo binding from launching command's working directory | No multi-repo UI needed in v1 | Validated in Phase 1 |
| Filesystem-only git-root resolver for Phase 1 | Avoids shelling out before the CLI pipeline exists; enough for visible repo binding | Validated in Phase 1 |
| Launcher open-command test override must be absolute-path only | Keeps automated smoke tests possible without permitting PATH-based command ambiguity | Added during Phase 1 security gate |
| Automatic issue creation (no review screen) in v1 | Fastest path; review deferred to v2 | — Pending |
| Issue creation via `gh issue create` | Uses existing auth; no GitHub API client needed | **Retired 2026-06-25** — replaced by AI-CLI-files-via-MCP (no `gh`, supports Jira, no API token) |
| v1 build runs non-sandboxed | App Sandbox blocks external CLI execution | — Pending |

---
*Last updated: 2026-06-25 after mid-milestone realignment (bundled whisper + AI-CLI/MCP filing)*
