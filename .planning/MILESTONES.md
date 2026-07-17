# Milestones

## v1.1 Concurrent Filing & Control (Shipped: 2026-07-02)

**Delivered:** Concurrent background filing with per-job cancellation and visible outcomes, plus
an AppKit status-item shell, live recording indicator, and editable drafting instructions whose
security-sensitive filing contract remains app-owned.

**Phases completed:** 5 phases, 13 plans, 32 tasks

**Key accomplishments:**

- Replaced serial filing state with independent concurrent `FilingJob` tasks and deferred spoken
  announcements safely around microphone capture.
- Added process-group cancellation and quit teardown with TERM-to-KILL escalation, deterministic
  MCP tempfile cleanup, and retained cancelled outcomes.
- Replaced `MenuBarExtra` with an AppKit `NSStatusItem`/popover shell supporting left-click status,
  right-click Settings/Quit, and a recording-only red menu-bar indicator.
- Added persisted drafting instructions with Reset-to-Default while keeping tool scope and the
  issue-URL output contract outside user-editable text.
- Added the live filing-jobs list with per-job Stop, persistent recoverable errors, safe issue links,
  dismiss, and terminal-only Clear-all controls.

**Verification:** 15/15 requirements satisfied; 5/5 phases passed; 12/12 integrations and 5/5
end-to-end flows wired. Five non-blocking tech-debt items and partial Nyquist coverage are retained
in the archived audit.

**Stats:**

- 2,090 Swift additions and 299 Swift deletions from the v1.0 tag to the shipped boundary
- 5 phases, 13 plans, 32 tasks
- 4 days from milestone start to ship (2026-06-28 → 2026-07-02)

**Git range:** `adff579` → `5c26f6c`

**Archived:** 2026-07-17

**What's next:** v1.2 Issue-to-PR Worker planning starts from the post-v1.1 groundwork merged in
PRs #10–#15; that later work is not part of v1.1.

---

## v1.0 MVP (Shipped: 2026-06-28)

**Phases completed:** 4 phases, 15 plans, 19 tasks

**Delivered:** The full v1 happy path — speak a thought, an issue is filed in the bound GitHub repo, and the issue number is spoken back — proven end-to-end with real filings.

**Key accomplishments:**

- **Repo-bound menu-bar app (Phase 1):** Native SwiftUI `MenuBarExtra` agent (no Dock icon, single-instance) that a repo-local command launches/activates and binds to the launching directory's git root, shown in the menu.
- **Push-to-talk voice capture (Phase 2):** User-configurable global background hotkey (default Control-Option-I) records 16 kHz mono PCM WAV while held; mic-permission prompt + menu recording indicator; hardware-verified.
- **Zero-config bundled transcription (Phase 3):** Self-contained `whisper-cli` + SHA-pinned `small.en` model vendored into the app bundle (six `@rpath` dylibs rewritten to `@loader_path`, ad-hoc signed); the ASR-command config surface was removed entirely.
- **AI-CLI files the issue via MCP (Phase 4):** Transcript handed to `claude -p` running in the bound repo, which drafts and files the issue through its own scoped GitHub MCP — no `gh`, no app-held tokens (rides the CLI's OAuth session).
- **Spoken confirmation (Phase 4):** Issue number/URL parsed from CLI stdout and spoken back via native TTS ("created issue #N"); auto-transitions transcript → filing → confirmation.
- **Provider-agnostic seam (Phase 4):** `IssueFilingConfig` command seam keeps the backend pluggable; `claude` + GitHub is the proven v1 leg, with `codex` + Jira explicitly deferred.

**Known deferred items / carried tech debt (non-blocking — see v1.0-MILESTONE-AUDIT.md):**

- Phase 4: orphaned "CLI Command" UI field (FINDING-06 — false affordance; hide or wire before offering non-Claude providers).
- Nyquist/VALIDATION paperwork incomplete on Phases 1–3 and Phase 1 has no VERIFICATION.md (UAT-verified) — process/doc debt only; all verifications passed.

---
