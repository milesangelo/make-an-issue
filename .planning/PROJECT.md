# make-an-issue

## What This Is

A native macOS menu-bar utility that turns a spoken thought into a GitHub issue for one of the
repositories you are working in. A repo-local command adds or activates a repository, a global
push-to-talk shortcut captures speech, bundled Whisper transcribes it, and Claude Code investigates
the selected repo and files the issue through the GitHub MCP server. The app speaks
"created issue #NUMBER" when the filing completes. It does not persist credentials; it obtains the
user's existing `gh` token at runtime for the temporary MCP environment.

The repository also contains a separate `make-an-issue-worker` CLI that can take an issue through
an isolated agent workspace, validation, a fresh non-force branch, and a verified draft pull
request. That worker is the baseline for the next milestone, not part of the shipped v1.1 scope.

## Core Value

Capture a repo-aware GitHub issue by voice in seconds, without leaving the keyboard or
opening a browser — the full path from spoken word to filed issue must work end to end.

## Current State

**v1.1 Concurrent Filing & Control shipped on 2026-07-02 at `5c26f6c`.** Its five phases are
archived with 15/15 requirements satisfied, 5/5 phase verifications passed, 12/12 cross-phase
integrations wired, and 5/5 end-to-end flows traced.

Work merged after that boundary is vNext groundwork: multi-repository selection (PR #6), release
signing and a deterministic assembled-app smoke gate (PRs #8–#9), and the Issue-to-PR worker
contract plus implementation baseline (PRs #10–#15). None of that later work is attributed to
v1.1.

<details>
<summary>Archived v1.1 goal</summary>

Remove the serial filing bottleneck and give the user control over filing and drafting guidance:
concurrent background jobs, per-job cancellation, a reliable AppKit status-item shell, a live
recording indicator, editable instructions with an app-owned enforced contract, and visible,
recoverable filing outcomes.

</details>

## Next Milestone Goals: v1.2 Issue-to-PR Worker

Planning starts from the merged worker baseline rather than treating it as unimplemented:

- Normative product and threat-model contracts already govern the worker.
- The CLI, strict configuration/routing, SQLite ledger, isolated workspace, Claude Code adapter,
  bounded process execution, validation, draft-PR publication, and startup publication
  reconciliation already exist.
- Fresh v1.2 requirements and phases must cover the remaining end-to-end contract surface,
  especially label pickup/reconciliation, menu-app enqueue and status integration, and the
  per-user worker lifecycle.

Formal milestone definition begins with `$gsd-new-milestone`.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ Repo-local command launches/activates the menu-bar app and binds it to the repo — v1.0 (Phase 1)
- ✓ Global push-to-talk shortcut captures microphone audio while held — v1.0 (Phase 2)
- ✓ Zero-config transcription via a **bundled** whisper model (no user ASR command) — v1.0 (Phase 3, bundled-whisper rework)
- ✓ The user's AI CLI, run in the bound repo, **drafts and files** the issue via its own MCP — no `gh`, no API token — v1.0 (Phase 4; GitHub via `claude -p` proven end-to-end + UAT)
- ✓ The created issue number/URL is parsed from the CLI output and spoken aloud ("created issue #N") — v1.0 (Phase 4)
- ✓ Backend is provider-agnostic via a configurable command seam (`IssueFilingConfig`) — v1.0 (Phase 4; claude + GitHub proven, `codex` + Jira explicitly deferred)
- ✓ Background/concurrent issue filing — capture returns to idle the instant transcription completes; multiple filings run concurrently as independent jobs, each speaking its own outcome — v1.1 (Phase 5; CONCUR-01/02/03)
- ✓ Per-job and quit-time cancellation terminate full subprocess trees and clean temporary MCP files — v1.1 (Phase 6; CANCEL-01/02/03)
- ✓ Right-click menu-bar icon opens a Settings…/Quit menu; left-click keeps the status popover; the Settings window is a focusable, single-instance AppKit shell hosting the push-to-talk Recorder — v1.1 (Phase 7; SETTINGS-01)
- ✓ Menu-bar icon shows a live red recording indicator while push-to-talk is held; reverts the instant recording stops — v1.1 (Phase 7; FEEDBACK-02)
- ✓ Editable, persisted drafting-instructions tab in Settings, with an app-owned **unbreakable enforced contract** (issue-URL trailer + scoped tool grant survive any user edit) shown read-only; removed the orphaned dead "CLI Command" field — v1.1 (Phase 8; SETTINGS-02/03/04/05, FINDING-06)
- ✓ Live "Filing Jobs" popover list — per-state rows (filing/done/failed/cancelled) with a per-job Stop on active rows, persistent dismissable error rows surfacing the mapped message + expandable transcript, an https-guarded clickable done-row issue link, and a Clear-all that removes only terminal jobs — v1.1 (Phase 9; JOBS-01/JOBS-02/RESIL-01)

### Active

<!-- Candidates only. Fresh v1.2 requirements are defined by /gsd-new-milestone. -->

- [ ] Complete Issue-to-PR worker pickup/reconciliation, app integration, and lifecycle surfaces.
- [ ] Review/edit the drafted title & body before filing (REVIEW-01 — deferred).
- [ ] Developer-ID signing + notarization for clean-machine distribution.
- [ ] Decide provider breadth beyond the implemented Claude Code worker adapter.

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Always-listening wake phrase — push-to-talk is simpler, more private, and avoids false triggers
- Embedded/in-app **LLM** runtime — the drafting/filing LLM is the user's own AI CLI + MCP, not hosted in-app (a **STT** model *is* now bundled — whisper.cpp — for zero-config transcription)
- App-held GitHub auth / `gh issue create` — retired 2026-06-25; the AI CLI files via its own MCP (OAuth), app holds no tokens
- Manual title/body review screen — v1 files automatically; review is a v2 concern
- Advanced failure recovery (retries, queuing, partial-state repair) — beyond v1; basic clear errors only

## Context

- **v1.0 MVP shipped 2026-06-28; v1.1 shipped 2026-07-02.**
- Current codebase: 8,136 source LOC across 29 Swift source files; 14,312 LOC across 53 source and
  test Swift files.
- App stack: Swift 6, SwiftUI hosted by an AppKit `NSStatusItem`/`NSPopover` shell,
  AVFoundation, KeyboardShortcuts, and bundled `whisper.cpp`.
- Worker stack: a separate SwiftPM executable/core library, `swift-toml`, SQLite, worker-owned
  workspaces, guarded Git operations, Claude Code provider execution, and draft-only GitHub
  publication.
- Target platform is macOS 13+. The app remains non-sandboxed because it spawns external tools.
- The app obtains an existing `gh` token at runtime for its temporary GitHub MCP environment but
  does not persist it. Worker provider processes receive no GitHub publication credential.
- v1.1 carried five non-blocking audit items (four cancellation robustness/coverage observations
  and one documentation-precision warning) plus partial Nyquist coverage across Phases 5–9.
- Clean-machine distribution still requires Developer-ID signing and notarization; ad-hoc signing
  and strict local seal verification are implemented.

## Constraints

- **Tech stack**: Native macOS app — Swift + SwiftUI/AppKit. Why: native menu-bar, global shortcut, audio capture, and TTS are first-class on macOS.
- **Platform**: macOS 13.0+ minimum. Why: `MenuBarExtra` and modern `SMAppService` APIs.
- **Dependencies**: Relies on Claude Code, `gh`, and Docker for issue filing; bundled Whisper handles
  transcription. The worker additionally uses SQLite and `swift-toml`.
- **Sandboxing**: v1 is not App-Sandboxed. Why: App Sandbox blocks spawning arbitrary external CLIs.
- **Scope**: The shipped app remains a local macOS utility; v1.2 planning is focused on completing
  the separate Issue-to-PR worker contract.

## Key Decisions

<!-- Decisions that constrain future work. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Native Swift menu-bar app (`NSStatusItem`/`NSPopover` + `LSUIElement`) | First-class menu-bar, hotkey, audio, TTS on macOS | ✓ Good — v1.0 shell evolved to the AppKit status-item architecture in v1.1 |
| Global shortcut push-to-talk, not wake phrase | Simpler, private, no false triggers | Validated in Phase 2 (KeyboardShortcuts global Carbon hotkey) |
| Local models invoked via configured CLI commands | Avoids embedded runtimes; reuses user's setup | CLIRunner pattern validated in Phase 3; **scope narrowed 2026-06-25** — STT is now a bundled whisper model (not a user CLI); the LLM is the user's AI coding CLI (`claude`/`codex`) |
| **Bundle whisper.cpp + model; drop user ASR config** (2026-06-25) | Zero-config + best accuracy on technical vocab for enterprise teammates | ✓ Good — shipped v1.0 (Phase 3; ad-hoc signed for local use, Developer-ID notarization deferred to a distribution phase) |
| **AI CLI drafts AND files the issue via its own MCP** (2026-06-25) | Enterprise users have GitHub/Atlassian MCP on their cloud subscription and forbid API tokens; collapses Phases 4+5 and removes `gh` | Validated in Phase 4 (claude + GitHub proven end-to-end; `codex` + Jira deferred) |
| **No persisted app credentials** | Reuse existing user authentication without maintaining a credential store | Revised post-v1.1: the app retrieves `gh auth token` at runtime for the temporary MCP environment; it never persists the token |
| Repo binding from launching command's working directory | Keep repository selection tied to explicit local context | Validated in Phase 1; expanded post-v1.1 to a persisted multi-repo picker (PR #6) |
| Filesystem-only git-root resolver for Phase 1 | Avoids shelling out before the CLI pipeline exists; enough for visible repo binding | Validated in Phase 1 |
| Launcher open-command test override must be absolute-path only | Keeps automated smoke tests possible without permitting PATH-based command ambiguity | Added during Phase 1 security gate |
| Automatic issue creation (no review screen) in v1 | Fastest path; review deferred to v2 | ✓ Good — shipped v1.0; review is a v2 candidate (REVIEW-01) |
| Issue creation via `gh issue create` | Uses existing auth; no GitHub API client needed | **Retired 2026-06-25** — replaced by AI-CLI-files-via-MCP (no `gh`, supports Jira, no API token) |
| v1 build runs non-sandboxed | App Sandbox blocks external CLI execution | ✓ Good — shipped v1.0 non-sandboxed; revisit if distributing via App Store |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-17 after v1.1 milestone closeout and v1.2 worker-baseline review.*
