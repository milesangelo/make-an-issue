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

- ✓ Repo-local command launches/activates the menu-bar app and binds it to the repo — v1.0 (Phase 1)
- ✓ Global push-to-talk shortcut captures microphone audio while held — v1.0 (Phase 2)
- ✓ Zero-config transcription via a **bundled** whisper model (no user ASR command) — v1.0 (Phase 3, bundled-whisper rework)
- ✓ The user's AI CLI, run in the bound repo, **drafts and files** the issue via its own MCP — no `gh`, no API token — v1.0 (Phase 4; GitHub via `claude -p` proven end-to-end + UAT)
- ✓ The created issue number/URL is parsed from the CLI output and spoken aloud ("created issue #N") — v1.0 (Phase 4)
- ✓ Backend is provider-agnostic via a configurable command seam (`IssueFilingConfig`) — v1.0 (Phase 4; claude + GitHub proven, `codex` + Jira explicitly deferred)

### Active

<!-- Next-milestone candidates (from REQUIREMENTS.md v2). Formalized when /gsd-new-milestone defines the next milestone's requirements. -->

- [ ] Review/edit the drafted title & body before filing (v2 REVIEW-01)
- [ ] Surfaced, recoverable errors for missing binding / failed filing (v2 RESIL-01)
- [ ] View and switch the bound repository from the menu (v2 MULTI-01)
- [ ] Developer-ID signing + notarization of the bundled whisper binary for clean-machine distribution (deferred from v1.0)
- [ ] Prove/wire non-Claude providers — `codex` + Atlassian/Jira (gated by upstream MCP-write feasibility)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Always-listening wake phrase — push-to-talk is simpler, more private, and avoids false triggers
- Embedded/in-app **LLM** runtime — the drafting/filing LLM is the user's own AI CLI + MCP, not hosted in-app (a **STT** model *is* now bundled — whisper.cpp — for zero-config transcription)
- App-held GitHub auth / `gh issue create` — retired 2026-06-25; the AI CLI files via its own MCP (OAuth), app holds no tokens
- Multi-repo switching UI — repo binding comes from the launching command's working directory in v1
- Manual title/body review screen — v1 files automatically; review is a v2 concern
- Advanced failure recovery (retries, queuing, partial-state repair) — beyond v1; basic clear errors only

## Context

- **Shipped v1.0 MVP on 2026-06-28** — full voice → filed-issue → spoken-confirmation happy path,
  proven end-to-end with real GitHub issues filed via `claude` + MCP.
- Codebase: ~3,660 LOC Swift across 23 files. Tech stack: Swift 6 / SwiftUI `MenuBarExtra` + AppKit,
  AVFoundation (capture + TTS), KeyboardShortcuts (global hotkey), bundled `whisper.cpp` (`whisper-cli` +
  SHA-pinned `small.en` model), plus `fetch-whisper.sh` / `build-app.sh` for vendoring + `.app` assembly.
- Target platform is macOS 13+ (native Swift/SwiftUI `MenuBarExtra`, AppKit where needed).
- Transcription is now **zero-config** via the bundled whisper model (the user-supplied ASR CLI was removed).
- The app holds **no credentials** — it rides the user's AI CLI's existing MCP OAuth session (no `gh`, no API token).
- The app shells out to the user's AI CLI (`claude`/`codex`) and the bundled whisper binary, so the v1
  build runs **non-sandboxed**; global shortcuts and microphone capture require Input
  Monitoring/Accessibility and Microphone permissions.
- Carried tech debt (see `milestones/v1.0-MILESTONE-AUDIT.md`): orphaned "CLI Command" UI field
  (FINDING-06); incomplete Nyquist/VALIDATION docs on Phases 1–3.

## Constraints

- **Tech stack**: Native macOS app — Swift + SwiftUI/AppKit. Why: native menu-bar, global shortcut, audio capture, and TTS are first-class on macOS.
- **Platform**: macOS 13.0+ minimum. Why: `MenuBarExtra` and modern `SMAppService` APIs.
- **Dependencies**: Relies on the user's AI coding CLI (`claude`/`codex`) on `PATH` with a configured MCP server (GitHub proven). ASR is no longer a dependency — whisper is bundled. Why: the app stays thin and token-free, riding the CLI's own auth.
- **Sandboxing**: v1 is not App-Sandboxed. Why: App Sandbox blocks spawning arbitrary external CLIs.
- **Scope**: v1 is happy-path only, ready for hands-on manual testing — not production hardening.

## Key Decisions

<!-- Decisions that constrain future work. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Native Swift menu-bar app (`MenuBarExtra` + `LSUIElement`) | First-class menu-bar, hotkey, audio, TTS on macOS | ✓ Good — shipped v1.0 (Phase 1) |
| Global shortcut push-to-talk, not wake phrase | Simpler, private, no false triggers | Validated in Phase 2 (KeyboardShortcuts global Carbon hotkey) |
| Local models invoked via configured CLI commands | Avoids embedded runtimes; reuses user's setup | CLIRunner pattern validated in Phase 3; **scope narrowed 2026-06-25** — STT is now a bundled whisper model (not a user CLI); the LLM is the user's AI coding CLI (`claude`/`codex`) |
| **Bundle whisper.cpp + model; drop user ASR config** (2026-06-25) | Zero-config + best accuracy on technical vocab for enterprise teammates | ✓ Good — shipped v1.0 (Phase 3; ad-hoc signed for local use, Developer-ID notarization deferred to a distribution phase) |
| **AI CLI drafts AND files the issue via its own MCP** (2026-06-25) | Enterprise users have GitHub/Atlassian MCP on their cloud subscription and forbid API tokens; collapses Phases 4+5 and removes `gh` | Validated in Phase 4 (claude + GitHub proven end-to-end; `codex` + Jira deferred) |
| **No app-held tokens; one-time OAuth per provider OK** (2026-06-25) | App never handles credentials; rides the AI CLI's existing MCP OAuth session | Validated in Phase 4 (app holds no tokens; rides claude's MCP OAuth session) |
| Repo binding from launching command's working directory | No multi-repo UI needed in v1 | Validated in Phase 1 |
| Filesystem-only git-root resolver for Phase 1 | Avoids shelling out before the CLI pipeline exists; enough for visible repo binding | Validated in Phase 1 |
| Launcher open-command test override must be absolute-path only | Keeps automated smoke tests possible without permitting PATH-based command ambiguity | Added during Phase 1 security gate |
| Automatic issue creation (no review screen) in v1 | Fastest path; review deferred to v2 | ✓ Good — shipped v1.0; review is a v2 candidate (REVIEW-01) |
| Issue creation via `gh issue create` | Uses existing auth; no GitHub API client needed | **Retired 2026-06-25** — replaced by AI-CLI-files-via-MCP (no `gh`, supports Jira, no API token) |
| v1 build runs non-sandboxed | App Sandbox blocks external CLI execution | ✓ Good — shipped v1.0 non-sandboxed; revisit if distributing via App Store |

---
*Last updated: 2026-06-28 after v1.0 MVP milestone — shipped the full voice → filed-issue → spoken-confirmation happy path (4 phases, 15 plans). Requirements moved to Validated; Active now holds v2 candidates.*
