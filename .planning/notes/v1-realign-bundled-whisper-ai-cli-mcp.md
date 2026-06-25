---
title: "v1 realignment — bundled whisper + AI-CLI-files-via-MCP"
date: 2026-06-25
context: Mid-milestone realignment after Phase 3, before Phase 4. Captured via /gsd-explore.
type: decision-record
---

# v1 Realignment: bundled whisper + AI-CLI-files-via-MCP

Mid-milestone course-correction (not a new milestone). Both shifts still serve the same
core value — voice → filed issue — by reducing setup friction and fitting enterprise constraints.
The original "user-configured local ASR CLI" + "local model CLI" + "`gh issue create`" design
assumed a power user; the real target is **enterprise teammates whose AI coding CLI already has
GitHub/Atlassian MCP wired to their cloud-provider subscription, and whose orgs forbid API tokens.**

## Driving change: who it's for

Currently dogfooded solo, but the destination is **distribution to enterprise teammates**. Design
requirements toward that future (zero-config transcription, no app-held credentials) while keeping
the immediate "works end-to-end for me" bar achievable.

## Fork 1 — Transcription: BUNDLE WHISPER, fully replace user config

**Decision:** Ship `whisper.cpp` (`whisper-cli`) + a bundled model inside the app. The
user-configurable ASR Command field is **fully removed** — transcription is always the bundled
binary + model. Zero config.

**Rationale:** Accuracy on technical vocabulary (library names, API/code identifiers) matters for
dictated issues; whisper-large beats native macOS STT there. Native `Speech`/`SpeechAnalyzer` was
considered (zero-setup, on-device) but rejected for accuracy.

**Commits us to:**
- App size + a vendored model license (e.g. `ggml-large-v3-turbo-q5_0.bin` ≈ 570 MB; `base.en` ≈ 140 MB — model choice is a planning decision).
- **Signing + hardened-runtime notarization** of the bundled `whisper-cli` executable, or Gatekeeper blocks teammates.
- Retires requirement "user-configured local ASR CLI" (TRANSCRIBE-01 reworded).

**Survives:** `CLIRunner` and `Transcriber` mostly stand — the app invokes the *bundled* binary at a
known bundle path with a bundled model instead of a *user* command. Moderate rework, not a rewrite.

## Fork 2 — Backend + issue creation: AI CLI drafts AND files via its own MCP

**Decision:** Hand transcript + bound-repo path to the user's AI coding CLI (`claude -p`, `codex exec`)
with working directory = bound repo. The CLI investigates the repo, drafts the issue, and **files it
through its own configured MCP server** (GitHub or Atlassian/Jira). The app regex-parses the issue
URL/number from stdout and speaks confirmation.

**This collapses Phase 4 (draft) and Phase 5 (`gh issue create`) into one merged phase**, retires the
`gh` dependency and `gh issue create`, and makes the issue **destination-agnostic** (GitHub or Jira).

**Auth constraint (reworded honestly):** No API tokens; **the app never handles credentials.** A
**one-time interactive OAuth grant per provider** (persisted in the CLI's own credential store) is
acceptable; everything after runs unattended.

**v1 scope:** All four combos (claude/codex × GitHub/Jira) are v1 targets via a provider-agnostic
"AI command" seam — BUT `codex` and Atlassian/Jira are **spike-gated** (see risks). The proven leg
is `claude -p` + GitHub remote MCP.

## Research findings (claude/codex non-interactive MCP write)

1. **`claude -p` works.** Non-interactive MCP write with tool scoping:
   `claude -p "<transcript>" --output-format json --mcp-config <file> --allowedTools "mcp__github__create_issue"`.
   Prefer `--allowedTools` scoping over `--dangerously-skip-permissions` (blanket bypass disables ALL guardrails).
2. **`codex exec` is the weak link.** Open upstream bug: non-interactive MCP tool calls auto-cancel
   (stdin EOF reads as "declined"); only `--dangerously-bypass-approvals-and-sandbox` runs them, and
   even that has read-only regressions (openai/codex issues #24135, #14068, #14345). Treat codex
   headless-MCP-write as **unreliable today** → spike-gated.
3. **GitHub *remote* MCP server supports OAuth** → satisfies no-PAT. (Local/Docker GitHub MCP needs a
   PAT — avoid.)
4. **⚠️ Atlassian/Jira risk:** remote MCP uses interactive OAuth 2.1 (browser consent, DCR-based,
   rejects outside tokens). Fully zero-touch non-interactive Jira write may NOT be achievable; relies
   on a persisted one-time OAuth grant in the CLI cred store, else needs a token.
5. **Output parsing is non-deterministic** even with `--output-format json` (URL sits in free-form
   `result` prose). Mitigate: instruct "reply with ONLY the issue URL on the last line" + regex
   `https://github.com/.../issues/\d+`.
6. **Latency:** seconds-to-a-minute (model reasoning + repo read + MCP call) — budget it into the
   spoken-confirmation UX.

Sources: code.claude.com/docs/en/cli-reference · github.com/openai/codex/issues/24135 ·
developers.openai.com/codex/agent-approvals-security · support.atlassian.com/atlassian-rovo-mcp-server

## Roadmap impact

- **Phase 3** → reopened for rework: vendor + sign/notarize `whisper-cli` + model, rewire `Transcriber`
  to the bundle path, remove the ASR Command field.
- **Phase 4 + Phase 5** → **merged** into one phase: invoke AI CLI (repo cwd) → it drafts & files via
  MCP → parse issue URL → speak confirmation. `gh`/`gh issue create` removed.
- **Spike gate:** prove non-interactive AI-CLI issue-filing via MCP end-to-end (claude+GitHub first;
  then codex + Jira) before committing build effort to the merged phase.

## Related
See [[v1-realign-roadmap]] decisions logged in PROJECT.md Key Decisions and REQUIREMENTS.md.
