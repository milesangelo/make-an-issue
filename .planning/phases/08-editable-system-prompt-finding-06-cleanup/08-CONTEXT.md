# Phase 8: Editable System Prompt + FINDING-06 Cleanup - Context

**Gathered:** 2026-07-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Add an **editable, persisted drafting-instructions field** to the Settings window so a developer
can tune how the AI drafts issues — while the app keeps enforcing an **unbreakable contract** (the
scoped `--allowedTools` grant + the "Issue URL on the last line" instruction) that no user edit can
remove. Also resolve **FINDING-06**: the orphaned "CLI Command" field.

Delivers: **SETTINGS-02, SETTINGS-03, SETTINGS-04, SETTINGS-05**.

**Out of scope (own phases):** jobs list, per-job Stop, and persistent error rows in the popover
are **Phase 9** (JOBS-01/02, RESIL-01). Non-Claude providers (`codex` + Jira) remain deferred — this
phase does NOT add a provider/CLI-switching capability (see D-01).

</domain>

<decisions>
## Implementation Decisions

### FINDING-06 — orphaned "CLI Command" field (SETTINGS-05)
- **D-01: Remove it entirely.** Delete the "CLI Command" `TextField` from `MenuView.swift`'s inline
  Settings disclosure and remove the now-dead `AppState.cliCommandKey` constant + its `@AppStorage`
  binding. Do **not** relocate or wire it. Rationale: it is confirmed dead code (stored to
  UserDefaults, never read back, never reaches the runner); only `claude`+GitHub is proven; and the
  enforced flags (`--mcp-config`, `--strict-mcp-config`, `--allowedTools`,
  `--output-format stream-json --verbose`) are **claude-shaped**, so a free-text CLI box is itself a
  false affordance (typing `codex` would produce a broken invocation). After removal,
  `IssueFilingConfig.claudeGitHub` remains the single source of truth for the CLI command.
- **D-01a (cleanup):** If removing the field leaves any orphaned imports/helpers in `MenuView.swift`
  (e.g. the `DisclosureGroup` becomes empty), clean those up too — but only what D-01 orphans.

### Enforced-contract boundary (SETTINGS-02 / SETTINGS-04)
- **D-02: Guidance-only editable field.** The user-editable field holds **only** the free-form
  drafting/investigation guidance (persona, how to investigate the repo, tone). The app owns
  everything structural and non-editable: the transcript injection, the repo reference, the "file the
  issue via `<mcpToolName>` method=create" directive, the "On the LAST line output ONLY the Issue
  URL: …" trailer, and the `--allowedTools` command-line flag. Matches SC3's "the editable field is
  instructions-only; flags and the enforced trailer live outside it."
- **D-03: Extract the URL trailer out of the editable template.** The "Issue URL on the last line"
  instruction is currently **interleaved inside `IssueFilingRunner.buildPrompt()` (step 3)** — it
  MUST be moved into the app-owned enforced trailer so it survives any edit. This is the core
  SETTINGS-04 guarantee: `buildPrompt()` becomes `{app framing + transcript} + {user guidance} +
  {enforced trailer}`, and the trailer + `--allowedTools` are appended by the app regardless of the
  editable value.
- **D-04: Show the enforced trailer read-only beneath the editor.** Display the always-appended
  enforced trailer as greyed-out, non-editable text under the editable box so the user understands
  the URL-line + tool-scope contract is always added and why their edits cannot break filing.

### Persistence, Reset, and empty-field rules (SETTINGS-02 / SETTINGS-03)
- **D-05: Persist via `@AppStorage`** following the existing pattern (mirror `AppState.cliCommandKey`
  usage) — a new `AppState.instructionsKey` string constant + `@AppStorage` binding in the Settings
  view. Persists across launches (SETTINGS-02).
- **D-06: Single canonical default.** The shipped default guidance lives in ONE canonical constant
  (the source of both the initial `@AppStorage` default and Reset). The default value = the current
  drafting/investigation guidance extracted from `buildPrompt()` (the persona + "investigate the
  repo" steps), NOT the enforced trailer.
- **D-07: "Reset to Default" repopulates the field (SETTINGS-03).** Reset writes the shipped default
  guidance text back into the editable box **and persists it**, so the user immediately sees exactly
  what they reverted to. No invisible state.
- **D-08: Blank field → fall back to the shipped default at prompt-build time.** If the editable
  guidance is empty/whitespace, `buildPrompt()` substitutes the default guidance. Filing stays robust
  (the LLM always gets the "investigate the repo" guidance); the enforced trailer + tool scope apply
  regardless.

### Settings window layout
- **D-09: TabView split.** Reorganize `SettingsView` into a `TabView` with a **"Shortcut"** tab (the
  existing push-to-talk `KeyboardShortcuts.Recorder`) and a **"Instructions"** tab (the editable
  guidance editor + read-only enforced-trailer display + Reset-to-Default button). Honors PROJECT.md's
  "editable system-prompt tab" language and gives the multi-line editor its own pane.
- **D-10: Fixed-size editor.** The instructions `TextEditor` gets a sensible fixed min-height
  (~8–10 lines) and scrolls internally; the Settings window stays a **fixed size** (no `.resizable`
  added this phase), consistent with the Phase 7 shell.

### Claude's Discretion (routed to research/planning)
- Exact home for the canonical default-instructions constant (e.g. on `IssueFilingConfig`, on the
  runner, or a dedicated `DefaultInstructions` file) — pick the cleanest seam that both the Settings
  view (for `@AppStorage` default + Reset) and `IssueFilingRunner.buildPrompt()` can read.
- Whether/how to migrate or simply drop the old `"cliCommand"` UserDefaults value on upgrade
  (low-stakes — it was never functional; a silent drop is acceptable).
- How the persisted instructions are threaded into `buildPrompt()` (new parameter vs read at call
  site) — must keep per-invocation isolation intact and not regress concurrent filing.
- Precise wording/formatting of the read-only enforced-trailer display (D-04).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase requirements & scope
- `.planning/ROADMAP.md` § "Phase 8: Editable System Prompt + FINDING-06 Cleanup" — goal + 4 success
  criteria (esp. SC3: enforced contract survives edits; SC4: no false affordance left in the menu).
- `.planning/REQUIREMENTS.md` — **SETTINGS-02** (editable, persisted instructions), **SETTINGS-03**
  (Reset to Default), **SETTINGS-04** (edits can never remove the enforced contract), **SETTINGS-05**
  (resolve orphaned "CLI Command" field / FINDING-06).

### Non-negotiable contract (governs SETTINGS-04)
- `.claude/skills/spike-findings-make-an-issue/SKILL.md` § Requirements — the app MUST pass a
  **scoped** `--allowedTools "mcp__<server>__<tool> …"` grant (least privilege, never
  `--permission-mode bypassPermissions`); the issue number MUST be parsed from the result **URL**
  (`/issues/<N>`), never the `id` field. These are why the trailer + tool grant must stay app-owned.
- `.planning/milestones/v1.0-MILESTONE-AUDIT.md` — origin of FINDING-06 (the orphaned "CLI Command"
  field carried as tech debt).

### Prior-phase decisions that constrain this phase
- `.planning/phases/07-appkit-status-item-ui-settings-window-shell/07-CONTEXT.md` — **D-03** (the
  push-to-talk Recorder already moved into the Settings window; this phase fills the rest) and
  **D-04** (the "CLI Command" field was intentionally left in the popover *for Phase 8* to
  relocate/remove — now resolved by D-01: removal).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Sources/MakeAnIssue/SettingsView.swift` (lines 4–21) — the Phase 7 Settings `Form` hosting the
  `KeyboardShortcuts.Recorder`. This is where the `TabView` reorg (D-09) and the new Instructions
  editor land.
- `Sources/MakeAnIssue/AppDelegate.swift` (lines 132–149, `showSettingsWindow()`) — the self-owned
  `NSWindow` (`NSHostingController(SettingsView())`, fixed styleMask `[.titled, .closable,
  .miniaturizable]`, single-instance). Keep fixed-size per D-10.
- `@AppStorage` persistence pattern (`MenuView.swift:8` + `AppState.swift:22` `cliCommandKey`) — the
  template to follow for the new `instructionsKey` (D-05), and the exact code being removed for
  FINDING-06 (D-01).

### Established Patterns
- `IssueFilingRunner.buildPrompt()` (`IssueFilingRunner.swift:48–73`) — builds the full `-p` prompt.
  Step 3 (the "Issue URL on the LAST line" instruction) is the interleaved contract that D-03
  extracts into an app-owned trailer; the persona + "investigate the repo" steps become the editable
  default (D-06).
- `IssueFilingRunner.assembleCommand()` (`IssueFilingRunner.swift:88–91`) — already appends
  `--allowedTools \(config.allowedToolsArgument)` **outside** the prompt ✓ (no change needed to keep
  the flag enforced; `allowedToolsArgument` is defined at `IssueFilingConfig.swift:56–58`).
- `IssueResultParser` (`IssueResultParser.swift`) — parses the issue number from the result URL only
  (structured `tool_result` regex, prose `Issue URL:` fallback). **No changes needed**; it depends on
  the D-03 trailer staying enforced, which is the whole point of SETTINGS-04.

### Integration Points
- `SettingsView` gains the Instructions tab bound to `@AppStorage(AppState.instructionsKey)`.
- `IssueFilingRunner.buildPrompt()` must read the persisted (or default-fallback) guidance and
  compose `{framing + transcript} + {guidance} + {enforced trailer}`.
- `MenuView.swift` loses the "CLI Command" `DisclosureGroup` field; `AppState` loses `cliCommandKey`.

</code_context>

<specifics>
## Specific Ideas

- The editable field is explicitly **guidance-only** — the user should never be able to see or edit
  the transcript slot, the file-it directive, the URL trailer, or the tool flags.
- The enforced trailer should be **visible but read-only** below the editor so the contract is
  transparent, not hidden machinery.
- "Reset to Default" should visibly refill the box, not silently clear state.

</specifics>

<deferred>
## Deferred Ideas

- **Non-Claude provider / CLI switching** (`codex` + Jira) — remains deferred (gated on upstream
  MCP-write feasibility). D-01 deliberately does NOT add a CLI-command setting; that is not this
  phase's job.
- **Jobs list, per-job Stop, persistent recoverable error rows** → **Phase 9** (JOBS-01/02, RESIL-01).

None of the above is scope creep into Phase 8 — discussion stayed within the editable-instructions +
FINDING-06 boundary.

</deferred>

---

*Phase: 8-Editable System Prompt + FINDING-06 Cleanup*
*Context gathered: 2026-07-01*
