# Requirements: make-an-issue

**Defined:** 2026-06-23
**Core Value:** Capture a repo-aware GitHub issue by voice in seconds — the full path from spoken word to filed issue must work end to end.

## v1 Requirements

Happy-path only. Each requirement maps to exactly one roadmap phase.

### Launch & Repo Binding

- [x] **LAUNCH-01**: A repo-local command launches the menu-bar app if it is not running, or activates the existing single instance.
- [x] **LAUNCH-02**: On launch/activation, the app binds the session to the git repository resolved from the command's working directory.
- [x] **LAUNCH-03**: The app runs as a native background menu-bar utility (no Dock icon) and displays the currently bound repository.

### Voice Capture

- [x] **CAPTURE-01**: A user-configurable global shortcut is registered and triggers while the app is in the background.
- [x] **CAPTURE-02**: Holding the shortcut records microphone audio (push-to-talk); releasing it stops the recording.
- [x] **CAPTURE-03**: The recording is saved as a 16 kHz mono WAV suitable as input to the ASR CLI.

### Transcription

- [~] **TRANSCRIBE-01**: The app transcribes the recorded WAV with a **bundled** `whisper.cpp` binary + bundled model — zero configuration, no user-supplied ASR command. *(Reworked 2026-06-25 — was "user-configured local ASR CLI"; Phase 3 needs rework.)*
- [x] **TRANSCRIBE-02**: The transcription output is captured as transcript text for the request.

### Issue Drafting & Filing (via the user's AI CLI + MCP)

- [ ] **ANALYZE-01**: The app invokes the user's AI coding CLI (e.g. `claude -p`, `codex exec`) with the transcript and the working directory set to the bound repo, so the CLI can investigate the repo for context.
- [ ] **ANALYZE-02**: The AI CLI drafts the issue (title + body) from the transcript and repo context.
- [ ] **ISSUE-01**: The AI CLI **files the issue through its own configured MCP server** (GitHub or Atlassian/Jira). The app uses **no `gh` and no API token** — it never handles credentials.
- [ ] **ISSUE-02**: The app parses the created issue's number/URL from the AI CLI's stdout (instruct "issue URL on the last line" + regex extract).
- [ ] **FEEDBACK-01**: The app speaks "created issue #NUMBER" using native macOS text-to-speech.

### Backend Flexibility & Auth

- [ ] **PROVIDER-01**: The AI backend is provider-agnostic via a configurable command seam. `claude` + GitHub remote MCP is the proven v1 leg; `codex` and Atlassian/Jira are v1 targets **gated by a feasibility spike** (codex non-interactive MCP write is unreliable upstream; Jira zero-token write may be infeasible).
- [ ] **AUTH-01**: The app never stores or transmits credentials/tokens. It relies on the user's pre-authenticated MCP session; a **one-time interactive OAuth grant per provider** (persisted in the CLI's own credential store) is acceptable, after which filing runs unattended.

## v2 Requirements

Deferred to a future release. Tracked but not in the current roadmap.

### Review & Editing

- **REVIEW-01**: User can review and edit the generated title/body before the issue is created.
- **REVIEW-02**: User can set labels/assignees for the created issue.

### Resilience

- **RESIL-01**: Clear, surfaced errors for missing repo binding, missing CLIs, or failed `gh` calls.
- **RESIL-02**: Retry/queue for failed or offline issue creation.

### Multi-Repo

- **MULTI-01**: User can view and switch the bound repository from the menu-bar UI.

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Always-listening wake phrase | Battery/privacy cost, false triggers; push-to-talk is sufficient |
| Embedded/in-app **LLM** runtime | The drafting/filing LLM is reached through the user's AI CLI + MCP, not hosted in-app. (Note: a **STT** model *is* bundled — whisper.cpp — for zero-config transcription; this exclusion is LLM-only as of the 2026-06-25 realignment.) |
| `gh issue create` / app-held GitHub auth | Retired 2026-06-25 — the user's AI CLI files via its own MCP (OAuth), so the app holds no tokens and shells out no `gh`. |
| Multi-repo switching UI (v1) | Binding comes from the launching command's cwd; UI deferred to v2 (MULTI-01) |
| Manual title/body review screen (v1) | Breaks the fast voice-only flow; deferred to v2 (REVIEW-01) |
| Advanced failure recovery (v1) | Retries/queue/partial-state repair out of v1 happy-path scope (v2 RESIL-02) |

## Traceability

Each v1 requirement maps to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| LAUNCH-01 | Phase 1 | Complete |
| LAUNCH-02 | Phase 1 | Complete |
| LAUNCH-03 | Phase 1 | Complete |
| CAPTURE-01 | Phase 2 | Complete |
| CAPTURE-02 | Phase 2 | Complete |
| CAPTURE-03 | Phase 2 | Complete |
| TRANSCRIBE-01 | Phase 3 (rework) | Needs rework |
| TRANSCRIBE-02 | Phase 3 | Complete |
| ANALYZE-01 | Phase 4 (merged) | Pending |
| ANALYZE-02 | Phase 4 (merged) | Pending |
| ISSUE-01 | Phase 4 (merged) | Pending |
| ISSUE-02 | Phase 4 (merged) | Pending |
| FEEDBACK-01 | Phase 4 (merged) | Pending |
| PROVIDER-01 | Phase 4 (merged) | Pending |
| AUTH-01 | Phase 4 (merged) | Pending |

**Coverage:**

- v1 requirements: 15 total
- Mapped to phases: 15
- Unmapped: 0 ✓
- Phases covering each requirement: exactly 1 ✓

> **Realigned 2026-06-25** (`/gsd-explore`): bundled-whisper transcription (TRANSCRIBE-01 reworked);
> Phases 4 + 5 merged into one AI-CLI-files-via-MCP phase; `gh issue create` retired; added
> PROVIDER-01 + AUTH-01. See `.planning/notes/v1-realign-bundled-whisper-ai-cli-mcp.md`.

---
*Requirements defined: 2026-06-23*
*Last updated: 2026-06-25 after mid-milestone realignment (bundled whisper + AI-CLI/MCP filing)*
