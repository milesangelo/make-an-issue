# Milestones

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
