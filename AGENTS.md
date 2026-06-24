# AGENTS.md

<!-- GSD:project-start source:PROJECT.md -->
## Project

**make-an-issue** is a native macOS menu-bar utility that turns a spoken thought into a GitHub
issue for the git repository you're working in. You launch it with a repo-local command (which
binds it to that repo), hold a global shortcut to talk, and it transcribes via a local ASR CLI,
investigates the repo via a local model CLI, files the issue with `gh issue create`, and speaks
"created issue #NUMBER".

**Core value:** Capture a repo-aware GitHub issue by voice in seconds — the full path from
spoken word to filed issue must work end to end.

v1 is **happy-path only**. See `.planning/PROJECT.md` and `.planning/REQUIREMENTS.md` for scope
and explicit exclusions (no wake phrase, no embedded model runtime, no multi-repo UI, no review
screen, no advanced recovery).
<!-- GSD:project-end -->

<!-- GSD:stack-start source:STACK.md -->
## Technology Stack

- **Language/UI:** Swift + SwiftUI `MenuBarExtra` (AppKit `NSStatusItem`/`NSPopover` as fallback), macOS 13+.
- **Global hotkey:** sindresorhus/KeyboardShortcuts (SPM) for push-to-talk (`onKeyDown`/`onKeyUp`).
- **Audio + speech:** AVFoundation — mic capture to 16 kHz mono WAV; `AVSpeechSynthesizer` (or `/usr/bin/say`) for TTS.
- **External CLIs (user-provided):** `gh` (issue creation), a configured ASR CLI (e.g. `whisper-cli`), a configured local model CLI; optional `ffmpeg`.
- **Process model:** Foundation `Process` runs all external CLIs. v1 runs **non-sandboxed** (App Sandbox blocks spawning CLIs).

See `.planning/research/STACK.md` for details and alternatives.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Greenfield project — conventions will firm up as code lands. Starting guidance:

- One shared `CLIRunner` for every external invocation (working dir, configurable PATH, stdout/exit capture).
- Repo binding = git root of the launching command's working directory; `gh`/git run with that as the working directory.
- Make ASR and model commands and the shortcut user-configurable; never hard-code Homebrew paths (GUI `PATH` differs from Terminal).
- Keep v1 strictly on the happy path; do not add review UI, multi-repo UI, or recovery logic without a roadmap change.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Single instance binds to the launch repo, then a sequential pipeline:
launch/bind → push-to-talk capture (WAV) → ASR CLI (transcript) → model CLI (title/body) →
`gh issue create` (issue number) → spoken confirmation.

Components: RepoBinding, HotkeyManager, AudioRecorder, CLIRunner (Transcriber/Investigator/IssueCreator),
SpeechOutput, MenuView. See `.planning/research/ARCHITECTURE.md` for the data-flow diagram and structure.
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
