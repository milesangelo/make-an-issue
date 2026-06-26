# Roadmap: make-an-issue

## Overview

A vertical-MVP "walking skeleton" that thickens one pipeline stage at a time. We first stand up
a repo-bound menu-bar agent, then add push-to-talk capture and transcription, and finally hand the
transcript to the user's own AI coding CLI which drafts **and files** the issue via its configured
MCP server. Each phase ends in a hands-on, manually testable result, and together they deliver the
v1 happy path: speak a thought → an issue (GitHub or Jira) is filed in the right repo → the number
is spoken back.

**Realigned 2026-06-25** (`/gsd-explore`): transcription moves to a **bundled whisper model**
(zero-config); Phases 4 + 5 **merge** — the user's AI CLI (`claude`/`codex`) drafts and files via
its own MCP, retiring `gh issue create` and all app-held tokens. See
`.planning/notes/v1-realign-bundled-whisper-ai-cli-mcp.md`.

## Phases

- [x] **Phase 1: Menu-Bar App + Repo-Bound Launch** - A no-Dock menu-bar agent a repo-local command launches/activates, bound to that repo (completed 2026-06-24)
- [x] **Phase 2: Push-to-Talk Voice Capture** - Global shortcut records mic audio to an ASR-ready WAV while held (completed 2026-06-24)
- [ ] **Phase 3: Local Transcription** - ⟳ *Reopened for rework 2026-06-25* — replace the user ASR CLI with a **bundled** whisper model (zero-config). Original capture→ASR→transcript pipeline shipped & passed UAT 2026-06-25.
- [x] **Phase 4: Voice → AI CLI Drafts & Files Issue (via MCP) + Spoken Confirmation** - *(merges old Phases 4+5)* The user's AI CLI, run in the bound repo, drafts and files the issue via its own MCP; the app parses the issue number/URL and speaks it. **Spike-gated.** (completed 2026-06-26)

## Phase Details

### Phase 1: Menu-Bar App + Repo-Bound Launch

**Goal**: A native macOS menu-bar utility that a repo-local command launches (or activates if already running) and binds to the git repo of that command's working directory.
**Depends on**: Nothing (first phase)
**Requirements**: LAUNCH-01, LAUNCH-02, LAUNCH-03
**Success Criteria** (what must be TRUE):

  1. Running the repo-local command from a git repo shows a menu-bar icon and no Dock icon.
  2. Running the command a second time activates the same instance rather than spawning a duplicate.
  3. The menu shows the bound repository (the git root of the launching directory).

**Plans**: 3 plans

Plans:

- [x] 01-01-PLAN.md — SwiftUI `MenuBarExtra` app shell (`LSUIElement`, `.window` style, non-sandboxed) showing status
- [x] 01-02-PLAN.md — Repo-local launcher command + single-instance activation + cwd hand-off
- [x] 01-03-PLAN.md — Resolve git root from cwd and display the bound repo in the menu

### Phase 2: Push-to-Talk Voice Capture

**Goal**: A user-configurable global shortcut records microphone audio while held and writes an ASR-ready WAV on release.
**Depends on**: Phase 1
**Requirements**: CAPTURE-01, CAPTURE-02, CAPTURE-03
**Success Criteria** (what must be TRUE):

  1. The global shortcut fires while another app is focused (background hotkey works).
  2. Holding the shortcut records and releasing it stops, with the menu reflecting the recording state.
  3. A 16 kHz mono WAV file is produced from the spoken audio.

**Plans**: 2/2 plans complete

Plans:
**Wave 1**

- [x] 02-01-PLAN.md — KeyboardShortcuts integration + AppState push-to-talk state machine (default Control-Option-I, configurable; ignore-repeat guard)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 02-02-PLAN.md — AVFoundation 16 kHz mono WAV capture, mic permission + Info.plist, recorder wiring, and menu recording indicator

### Phase 3: Local Transcription

**Goal**: Transcribe the recorded WAV with a **bundled** whisper model — zero configuration, no user-supplied ASR command.
**Depends on**: Phase 2
**Requirements**: TRANSCRIBE-01 (reworked), TRANSCRIBE-02
**Success Criteria** (what must be TRUE):

  1. Releasing the shortcut transcribes the recording with the bundled whisper binary + model — no ASR command field, no PATH setup.
  2. The transcript text is captured and shown (menu/log) for the request.
  3. The bundled `whisper-cli` runs on a clean machine (signed + hardened-runtime notarized; not Gatekeeper-blocked).

**Status**: Original pipeline (2/2 plans) shipped & passed UAT 2026-06-25; ⟳ reopened 2026-06-25 for the bundled-whisper rework below.

Plans:

**Wave 1 — original pipeline (done)**

- [x] 03-01-PLAN.md — Shared `CLIRunner` (`Process` wrapper: `/bin/zsh -lc`, separate stdout/stderr+exit capture via concurrent readabilityHandlers, single-resume 120s timeout; reusable by Phase 4)

**Wave 2 — original pipeline (done)** *(blocked on Wave 1 completion)*

- [x] 03-02-PLAN.md — `Transcriber` (validate command + shell-safe `{wav}` substitution, run via CLIRunner, trim stdout) + AppState/MenuView integration (`.transcribing` state, async off MainActor, transcript display + NSLog, `asrCommand` field, `onRunTranscription` seam)

**Wave 3 — bundled-whisper rework (2026-06-25)**

- [ ] 03-03: Vendor `whisper-cli` + a model into the app bundle (Resources); sign + hardened-runtime notarize the binary; resolve the bundle path at runtime
- [ ] 03-04: Rewire `Transcriber` to invoke the bundled binary + bundled model (drop the user ASR command + `{wav}`-from-user path); **remove the ASR Command field** and `asrCommand`/`onRunTranscription` user-config surface from MenuView/AppState; update tests

### Phase 4: Voice → AI CLI Drafts & Files Issue (via MCP) + Spoken Confirmation

*(Merges old Phase 4 "Repo Investigation → Issue Draft" + old Phase 5 "Automatic Issue Creation + Spoken Confirmation".)*

**Goal**: Hand the transcript to the user's AI coding CLI (`claude`/`codex`) running in the bound repo; the CLI investigates the repo, drafts the issue, and **files it through its own configured MCP server** (GitHub or Atlassian/Jira). The app parses the created issue's number/URL from stdout and speaks "created issue #NUMBER". No `gh`, no API token.
**Depends on**: Phase 3 (rework) · **Gated on**: the feasibility spike (`/gsd-spike`) confirming non-interactive AI-CLI MCP filing.
**Requirements**: ANALYZE-01, ANALYZE-02, ISSUE-01, ISSUE-02, FEEDBACK-01, PROVIDER-01, AUTH-01
**Success Criteria** (what must be TRUE):

  1. The app invokes the configured AI CLI with the transcript and working directory = bound repo (e.g. `claude -p "<transcript>" --output-format json --mcp-config <file> --allowedTools "mcp__github__create_issue"`).
  2. A real issue is created through the CLI's MCP server (GitHub proven; Jira spike-gated) — the app holds no tokens; it rides the CLI's existing OAuth session.
  3. The created issue number/URL is parsed from the CLI's stdout (regex on a "URL on the last line" instruction).
  4. The app speaks "created issue #NUMBER" via native text-to-speech.
  5. Backend is provider-agnostic via a configurable command seam; `codex` + Jira validated or explicitly documented as deferred.

**Plans**: 4/4 plans complete

Plans:

**Wave 1**

- [x] 04-01-PLAN.md — Foundations: `IssueResultParser` (url-not-id, prose fallback, permission_denials gate), `IssueFilingConfig` provider seam (claude+GitHub; codex/Jira deferred), `CLIRunner` `environment:` passthrough param

**Wave 2** *(blocked on 04-01)*

- [x] 04-02-PLAN.md — `IssueFilingRunner`: scoped `claude -p` invocation (cwd = bound repo, structured `stream-json --verbose`, token via env, MCP tempfile, 300s timeout) → parse + error mapping

**Wave 3** *(blocked on 04-02)*

- [x] 04-03-PLAN.md — `AppState` `.filing` state + `onRunIssueFiling` seam + `AVSpeechSynthesizer` TTS ("created issue #N") + `MenuView` `.filing` label and CLI Command field

**Wave 4** *(blocked on 04-03)*

- [x] 04-04-PLAN.md — Human-verify checkpoint: real end-to-end issue filed via MCP + spoken confirmation, plus failure negative-check

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 (rework) → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Menu-Bar App + Repo-Bound Launch | 3/3 | Complete | 2026-06-24 |
| 2. Push-to-Talk Voice Capture | 2/2 | Complete    | 2026-06-24 |
| 3. Local Transcription | 2/4 | Reopened (bundled-whisper rework) | original 2026-06-25 |
| 4. Voice → AI CLI Drafts & Files Issue (via MCP) + Spoken Confirmation | 4/4 | Complete   | 2026-06-26 |
