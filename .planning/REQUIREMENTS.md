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

- [ ] **TRANSCRIBE-01**: The app invokes the user-configured local ASR CLI on the recorded WAV.
- [x] **TRANSCRIBE-02**: The ASR CLI output is captured as transcript text for the request.

### Repo Investigation

- [ ] **ANALYZE-01**: The app invokes the user-configured local model CLI with the transcript and bound-repo context.
- [ ] **ANALYZE-02**: The model CLI output is parsed into a GitHub issue title and body.

### Issue Creation & Confirmation

- [ ] **ISSUE-01**: The app creates the issue automatically via `gh issue create` in the bound repository using the generated title and body.
- [ ] **ISSUE-02**: The created issue number is parsed from the `gh` output (after a success exit code).
- [ ] **FEEDBACK-01**: The app speaks "created issue #NUMBER" using native macOS text-to-speech.

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
| Embedded/in-app model runtime | Large binary, runtime management; local models reached via configured CLIs |
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
| TRANSCRIBE-01 | Phase 3 | Pending |
| TRANSCRIBE-02 | Phase 3 | Complete |
| ANALYZE-01 | Phase 4 | Pending |
| ANALYZE-02 | Phase 4 | Pending |
| ISSUE-01 | Phase 5 | Pending |
| ISSUE-02 | Phase 5 | Pending |
| FEEDBACK-01 | Phase 5 | Pending |

**Coverage:**

- v1 requirements: 13 total
- Mapped to phases: 13
- Unmapped: 0 ✓
- Phases covering each requirement: exactly 1 ✓

---
*Requirements defined: 2026-06-23*
*Last updated: 2026-06-23 after initial definition*
