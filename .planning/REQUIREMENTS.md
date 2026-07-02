# Requirements: make-an-issue — Milestone v1.1 (Concurrent Filing & Control)

**Defined:** 2026-06-28
**Core Value:** Capture a repo-aware tracker issue by voice in seconds — spoken word to filed issue, end to end.

## v1.1 Requirements

Requirements for this milestone. Each maps to a roadmap phase. (v1.0 requirements are Validated in PROJECT.md.)

### Concurrent Filing (CONCUR)

- [x] **CONCUR-01**: After transcription completes, the app returns to idle immediately so the user can start a new recording without waiting for the current filing to finish.
- [x] **CONCUR-02**: Multiple issue filings run concurrently in the background — a second (and third) request can be in flight while the first is still filing.
- [x] **CONCUR-03**: Each filing independently speaks its own "created issue #N" confirmation when it completes, regardless of what the user is doing at the time.

### Stop / Cancel (CANCEL)

- [x] **CANCEL-01**: User can stop an in-flight filing, which terminates its subprocess and the full `claude → docker` process tree — no orphaned `claude` process or leaked `--rm` Docker container.
- [x] **CANCEL-02**: A cancelled filing surfaces a "filing cancelled" outcome (spoken + status) and removes the job; no issue is filed.
- [x] **CANCEL-03**: Quitting the app while filings are in flight cleans up their subprocesses and per-invocation MCP tempfiles (no orphans left behind).

### Settings & Editable Prompt (SETTINGS)

- [x] **SETTINGS-01**: Right-clicking the menu-bar icon opens a menu with "Settings…" and "Quit"; left-click still opens the status popover.
- [x] **SETTINGS-02**: A Settings window exposes an editable field for the LLM investigation/drafting **instructions**, persisted across launches.
- [x] **SETTINGS-03**: A "Reset to Default" control restores the shipped default prompt instructions.
- [x] **SETTINGS-04**: Editing the instructions can never remove the enforced contract — the app always appends the scoped tool grant and "Issue URL on the last line" instruction, so issue-number parsing and tool scoping cannot be broken by user edits.
- [x] **SETTINGS-05**: The orphaned "CLI Command" field (FINDING-06) is resolved — relocated into Settings (wired or removed), with no false affordance left in the menu.

### Jobs Visibility & Control (JOBS)

- [x] **JOBS-01**: The menu shows a list of active filing jobs, each with its state (filing / done / failed / cancelled) and an activity indicator.
- [x] **JOBS-02**: Each active job row has a Stop control that cancels that specific job (the UI surface for CANCEL-01).

### Recoverable Errors (RESIL)

- [x] **RESIL-01**: A failed filing surfaces a recoverable error — spoken (since the popover is usually closed) and shown as a persistent job row with the message and originating transcript until dismissed — instead of silently disappearing.

### Live Feedback (FEEDBACK)

- [x] **FEEDBACK-02**: While push-to-talk is held and recording is live, the menu-bar icon itself shows an active-recording indicator (e.g. tinted/highlighted button background or a recording symbol) — visible even when the popover is closed — and reverts when recording stops.

## Future Requirements

Deferred — acknowledged but not in this milestone's roadmap.

### Prompt (PROMPT)

- **PROMPT-01**: `{{placeholder}}` tokens in the editable prompt (e.g. `{{transcript}}`) with a validation guard so a deleted required token can't produce empty issues.
- **PROMPT-02**: Live "effective prompt" preview showing instructions + enforced contract combined.

### Jobs (JOBS — future)

- **JOBS-03**: Retry a failed job in place, reusing the stored transcript + repo (avoids re-dictation).
- **JOBS-04**: Menu-bar badge showing the active-job count; "clear completed" / "cancel all" actions.

### Carried from v1.0

- **REVIEW-01**: Review/edit the drafted title & body before filing.
- **MULTI-01**: View and switch the bound repository from the menu.
- **DIST-01**: Developer-ID signing + notarization of the bundled whisper binary for clean-machine distribution.
- **PROVIDER-01**: Prove/wire non-Claude providers — `codex` + Atlassian/Jira (gated by upstream MCP-write feasibility).

## Out of Scope

Explicitly excluded for v1.1. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Overlapping / queued microphone captures | One mic; recording stays serial. Only filing is concurrent. |
| Persistent job history across launches | Overbuild for a single-user menu-bar tool; the in-flight list is enough. |
| Concurrency-limit scheduler / Notification Center alerts | Anti-features for a single-user tool; spoken + popover feedback suffices. |
| Editing the enforced contract (tool scope, URL-output line) itself | Would break issue parsing and least-privilege security scoping. |
| SwiftUI `Settings` scene / `SettingsLink` | `showSettingsWindow:` removed in macOS 14; a self-owned `NSWindow` is used instead for macOS 13+ parity. |

## Traceability

Which phases cover which requirements. Filled during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| CONCUR-01 | Phase 5 | Complete |
| CONCUR-02 | Phase 5 | Complete |
| CONCUR-03 | Phase 5 | Complete |
| CANCEL-01 | Phase 6 | Complete |
| CANCEL-02 | Phase 6 | Complete |
| CANCEL-03 | Phase 6 | Complete |
| SETTINGS-01 | Phase 7 | Complete |
| SETTINGS-02 | Phase 8 | Complete |
| SETTINGS-03 | Phase 8 | Complete |
| SETTINGS-04 | Phase 8 | Complete |
| SETTINGS-05 | Phase 8 | Complete |
| JOBS-01 | Phase 9 | Complete |
| JOBS-02 | Phase 9 | Complete |
| RESIL-01 | Phase 9 | Complete |
| FEEDBACK-02 | Phase 7 | Complete |

**Coverage:**

- v1.1 requirements: 15 total
- Mapped to phases: 15 ✓
- Unmapped: 0 ✓

---
*Requirements defined: 2026-06-28*
*Last updated: 2026-06-28 — roadmap created (Phases 5-9); all 15 requirements mapped*
