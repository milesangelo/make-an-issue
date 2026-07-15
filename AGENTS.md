# AGENTS.md

<!-- GSD:project-start source:PROJECT.md -->
## Project

**make-an-issue** is a native macOS menu-bar utility that turns a spoken thought into a GitHub
issue for the git repository you're working in. You launch it with a repo-local command (which
binds it to that repo), hold a global shortcut to talk, and it transcribes with a bundled
whisper model, hands the transcript to Claude Code running in the bound repo — which
investigates the repo, drafts the issue, and files it through a GitHub MCP server — and speaks
"created issue #NUMBER".

**Core value:** Capture a repo-aware GitHub issue by voice in seconds — the full path from
spoken word to filed issue must work end to end.

v1 is **happy-path only**. See `.planning/PROJECT.md` and `.planning/REQUIREMENTS.md` for scope
and explicit exclusions (no wake phrase, no embedded model runtime, no review screen, no advanced
recovery). Multi-repo selection **is** implemented (MULTI-01): the menu accumulates every launched
repo, lets the user switch which is the active bound repo, and persists the list + selection across
relaunches; each dictation files against the currently-active repo.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:STACK.md -->
## Technology Stack

- **Language/UI:** Swift + SwiftUI views hosted in an AppKit `NSStatusItem`/`NSPopover` shell, macOS 13+.
- **Global hotkey:** sindresorhus/KeyboardShortcuts (SPM) for push-to-talk (`onKeyDown`/`onKeyUp`).
- **Audio + speech:** AVFoundation — mic capture to 16 kHz mono WAV; `AVSpeechSynthesizer` for TTS.
- **External CLIs (user-provided):** `claude` (drafts & files issues via a GitHub MCP server), `gh` (provides the GitHub token), `docker` (runs the MCP server container). ASR uses the **bundled** `whisper-cli` + model (vendored at build time).
- **Process model:** Foundation `Process` runs all external CLIs. v1 runs **non-sandboxed** (App Sandbox blocks spawning CLIs).

See `.planning/research/STACK.md` for details and alternatives.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Greenfield project — conventions will firm up as code lands. Starting guidance:

- One shared `CLIRunner` for every external invocation (working dir, configurable PATH, stdout/exit capture).
- Repo binding = git root of the launching command's working directory; `gh`/git run with that as the working directory.
- Keep the shortcut and drafting instructions user-configurable; never hard-code Homebrew paths (GUI `PATH` differs from Terminal).
- Keep v1 strictly on the happy path; do not add review UI or recovery logic without a roadmap change.
- Multi-repo selection is implemented (MULTI-01): `AppState.knownRepos` accumulates launched repos (deduped by `rootURL`, most-recent first), `boundRepo` is the active selection, and both are persisted to `UserDefaults` under `knownReposKey`/`activeRepoKey` — restored via `restorePersistedRepos()` before the launch request is applied. In-flight `FilingJob`s keep the repo they were spawned against (by-value capture).
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Single instance binds to the launch repo, then a sequential pipeline:
launch/bind → push-to-talk capture (WAV) → bundled whisper-cli (transcript) →
Claude Code + GitHub MCP (draft & file issue) → spoken confirmation. Capture returns to idle
after transcription; each filing runs as an independent background job (filing/done/failed/cancelled).

Components: RepoBinding, AudioRecorder, Transcriber, CLIRunner, IssueFilingRunner (+ IssueFilingConfig,
IssueResultParser), AppState, MenuView, SettingsView. See `.planning/research/ARCHITECTURE.md` for the
data-flow diagram and structure.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.codex/skills/`, `.agents/skills/`, `.cursor/skills/`, or `.github/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `$gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `$gsd-debug` for investigation and bug fixing
- `$gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.

> Note: the global GSD CLI (`~/.codex/gsd-core/bin/gsd-tools.cjs`) currently fails to load
> (`runtime-artifact-conversion.cjs` requires a missing `../../../package.json`). These planning
> artifacts were authored directly from the GSD templates. Once the global install is fixed,
> GSD commands can manage these files normally.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `$gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` — do not edit manually.
<!-- GSD:profile-end -->

## Skill routing

- **Spike findings for make-an-issue** (implementation patterns, constraints, gotchas) → `Skill("spike-findings-make-an-issue")`

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
