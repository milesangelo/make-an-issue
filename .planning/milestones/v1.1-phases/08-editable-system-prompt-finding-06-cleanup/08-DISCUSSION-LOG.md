# Phase 8: Editable System Prompt + FINDING-06 Cleanup - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-01
**Phase:** 8-Editable System Prompt + FINDING-06 Cleanup
**Areas discussed:** FINDING-06 resolution, Enforced-contract boundary, Reset & empty-field rules, Settings window layout

---

## FINDING-06 — orphaned "CLI Command" field

| Option | Description | Selected |
|--------|-------------|----------|
| Remove it entirely | Delete the dead field; no CLI setting anywhere. Only claude+GitHub proven; enforced flags are claude-shaped so a free-text CLI box is itself a false affordance. | ✓ |
| Relocate into Settings + wire it | Move into Settings and make it change `IssueFilingConfig.cliCommand`; exposes an unproven codex path with mismatched flags. | |
| Relocate as read-only display | Show "claude" as a non-editable info row. Middle ground; low-value display element. | |

**User's choice:** Remove it entirely
**Notes:** Scout confirmed the field is dead code (`@AppStorage("cliCommand")`, never read back, never reaches the runner). Enforced flags (`--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `--output-format stream-json --verbose`) are claude-specific, reinforcing that a free-text CLI box is a false affordance. Cleanup includes the orphaned `AppState.cliCommandKey` constant.

---

## Enforced-contract boundary — what is editable vs enforced

| Option | Description | Selected |
|--------|-------------|----------|
| Guidance-only editable | Editable field holds only drafting/investigation guidance; app owns transcript injection, file-it directive, URL trailer, and tool flags. | ✓ |
| Editable body with {transcript} placeholder | User edits a larger body including the transcript slot; app still force-appends trailer + flags. More power, more footgun. | |

**User's choice:** Guidance-only editable

## Enforced-contract boundary — visibility of the enforced trailer

| Option | Description | Selected |
|--------|-------------|----------|
| Show read-only below the field | Display the always-appended enforced trailer as greyed-out non-editable text beneath the editor. | ✓ |
| Hidden entirely | Editable box only; enforced trailer is invisible machinery. | |

**User's choice:** Show read-only below the field
**Notes:** The "Issue URL on the last line" instruction is currently interleaved inside `buildPrompt()` step 3 and must be extracted into the app-owned enforced trailer. `--allowedTools` is already appended outside the prompt in `assembleCommand()`.

---

## Reset & empty-field rules

| Option | Description | Selected |
|--------|-------------|----------|
| Reset repopulates the field with default text | Reset writes the shipped default guidance back into the box and persists it — user sees exactly what they reverted to. | ✓ |
| Reset clears stored value, falls back silently | Reset deletes the override; box may show empty/default depending on binding. | |

**User's choice:** Repopulate the field with default text

## Reset & empty-field rules — blank field behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Fall back to shipped default | Blank guidance treated as "use the default" at prompt-build time; filing stays robust. | ✓ |
| Send empty guidance | Respect a blank field literally; LLM gets only the enforced trailer. | |

**User's choice:** Fall back to shipped default

---

## Settings window layout

| Option | Description | Selected |
|--------|-------------|----------|
| TabView: Shortcut + Instructions tabs | Real TabView splitting the Recorder from the instructions editor; honors PROJECT.md's "system-prompt tab" language. | ✓ |
| Single Form with two sections | Keep the existing grouped Form; add an Instructions section. Minimal UI, least code. | |

**User's choice:** TabView: Shortcut + Instructions tabs

## Settings window layout — editor sizing

| Option | Description | Selected |
|--------|-------------|----------|
| Fixed min-height, scrolls internally | TextEditor with ~8–10 line min height; window stays fixed-size. | ✓ |
| Make the window resizable | Add `.resizable` and let the editor grow. | |

**User's choice:** Fixed min-height, scrolls internally

---

## Claude's Discretion

- Exact home for the canonical default-instructions constant (must be readable by both `SettingsView` and `IssueFilingRunner.buildPrompt()`).
- Whether to migrate or silently drop the old `"cliCommand"` UserDefaults value on upgrade (low-stakes; silent drop acceptable).
- How the persisted instructions are threaded into `buildPrompt()` while preserving per-invocation isolation and concurrent-filing behavior.
- Precise wording/formatting of the read-only enforced-trailer display.

## Deferred Ideas

- Non-Claude provider / CLI switching (`codex` + Jira) — remains deferred; this phase deliberately adds no CLI-command setting.
- Jobs list, per-job Stop, persistent recoverable error rows → Phase 9 (JOBS-01/02, RESIL-01).
