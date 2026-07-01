---
phase: 08-editable-system-prompt-finding-06-cleanup
plan: 02
subsystem: api
tags: [swift, prompt-engineering, security, tdd]

requires:
  - phase: 08-editable-system-prompt-finding-06-cleanup
    provides: AppState.instructionsKey persistence-key constant (Plan 01)
provides:
  - IssueFilingConfig.defaultInstructions canonical drafting-guidance constant (D-06)
  - IssueFilingRunner.enforcedTrailer app-owned, non-editable URL-line + file-it-directly trailer (D-02/D-03)
  - buildPrompt(instructions:) restructured into ordered segments so the enforced contract survives any edit (SETTINGS-04)
  - file(instructions:) and AppState's default filing closure threading the persisted instructions fresh per invocation (D-02/SETTINGS-02)
affects: [08-03-SettingsView-instructions-tab]

tech-stack:
  added: []
  patterns: ["RED-GREEN TDD for pure prompt-assembly helpers", "trim-and-fallback-to-canonical-default idiom for optional user input", "fresh-per-invocation UserDefaults read (no self-cached state) to preserve concurrency isolation"]

key-files:
  created: []
  modified:
    - Sources/MakeAnIssue/IssueFilingConfig.swift
    - Sources/MakeAnIssue/IssueFilingRunner.swift
    - Sources/MakeAnIssue/AppState.swift
    - Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift
    - Tests/MakeAnIssueTests/IssueFilingConfigTests.swift

key-decisions:
  - "enforcedTrailer lives on IssueFilingRunner (not IssueFilingConfig) — it is provider-agnostic prose, mirroring shellEscape as a standalone pure static helper (Claude's Discretion, per 08-PATTERNS.md)"
  - "buildPrompt(instructions:) defaults to \"\" so all pre-existing call sites (tests and file()) remain source-compatible without modification"
  - "AppState reads UserDefaults(instructionsKey) inside the default onRunIssueFiling closure body at invocation time — never cached on self/@Published — preserving spawnFilingJob's existing capture-by-value concurrency isolation for concurrent filings (D-02, T-08-09)"
  - "onRunIssueFiling closure TYPE signature is unchanged (still 3-param) so no AppStateTests.swift injection required editing — only the default closure's implementation changed"

patterns-established:
  - "Enforced/non-editable contract segments are appended by the app AFTER user-editable guidance, never interpolated into it — the architectural pattern for making a user-editable text field un-overridable for specific structural guarantees"

requirements-completed: [SETTINGS-04, SETTINGS-02]

duration: 7min
completed: 2026-07-01
status: complete
---

# Phase 8 Plan 2: buildPrompt Restructure + Fresh-Per-Invocation Instructions Threading Summary

**Extracted the "Issue URL on last line" instruction into an app-owned `IssueFilingRunner.enforcedTrailer`, added the single canonical `IssueFilingConfig.defaultInstructions` constant, and restructured `buildPrompt`/`file()`/AppState's filing closure so user-editable drafting guidance can never remove the enforced tool-scope + issue-URL contract, with instructions read fresh from UserDefaults on every filing invocation.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-07-01T19:58:00Z (approx.)
- **Completed:** 2026-07-01T20:00:49Z
- **Tasks:** 2 completed
- **Files modified:** 5

## Accomplishments
- Added `IssueFilingConfig.defaultInstructions` (D-06) — the single canonical drafting-guidance constant, extracted verbatim from `buildPrompt`'s prior step-1 persona/investigation prose, excluding the app-owned `method=create` directive and URL trailer.
- Added `IssueFilingRunner.enforcedTrailer` (D-03/SETTINGS-04) — an app-owned static constant carrying the "Issue URL on the LAST line" output format contract + "Do not ask for confirmation; file it directly", doc-commented with its decision-ID cross-references.
- Restructured `buildPrompt` to accept an `instructions: String = ""` parameter and assemble the prompt as four ordered segments — `{app framing + transcript} + {guidance} + {app-owned file-it directive} + {enforcedTrailer}` — so `enforcedTrailer` is always appended last, after any user-editable text, making it structurally unremovable by edits (verified by an injection-style-instructions unit test).
- Implemented the D-08 blank-fallback: whitespace-only/empty `instructions` substitutes `IssueFilingConfig.defaultInstructions` at build time, using the file's existing trim-and-check idiom.
- Threaded `instructions` through `IssueFilingRunner.file(...)` into its internal `buildPrompt` call, and updated AppState's default `onRunIssueFiling` closure to read `UserDefaults.standard.string(forKey: AppState.instructionsKey)` fresh at invocation time (not cached on `self`), preserving the existing `spawnFilingJob` capture-by-value concurrency-isolation guarantee (D-02/SETTINGS-02/T-08-09).
- Left `assembleCommand` and the `--allowedTools` flag completely untouched — verified via a new test that the scoped tool grant is independent of arbitrary/injection-style instructions.
- Kept the `onRunIssueFiling` closure's TYPE signature unchanged (still 3-param), so none of the 30 `{ _, _, _ in ... }` injections in `AppStateTests.swift` required editing.

## Task Commits

Each task was committed atomically (Task 1 followed the TDD RED→GREEN cycle):

1. **Task 1 RED: Add failing tests for enforcedTrailer + defaultInstructions** - `428fb69` (test)
2. **Task 1 GREEN: Restructure buildPrompt with enforcedTrailer + defaultInstructions** - `696c178` (feat)
3. **Task 2: Thread persisted instructions through file() and AppState's filing seam** - `38c2dfc` (feat)

**Plan metadata:** (recorded below)

_Note: Task 1 had no separate refactor commit — the GREEN implementation was already the minimal, clean shape; no cleanup was needed._

## Files Created/Modified
- `Sources/MakeAnIssue/IssueFilingConfig.swift` - Added `defaultInstructions` canonical constant under a new `// MARK: - Default drafting instructions (D-06)` heading
- `Sources/MakeAnIssue/IssueFilingRunner.swift` - Added `enforcedTrailer` static constant; restructured `buildPrompt` to accept `instructions:` and assemble ordered segments; threaded `instructions` through `file()`
- `Sources/MakeAnIssue/AppState.swift` - Default `onRunIssueFiling` closure now reads `UserDefaults.standard.string(forKey: AppState.instructionsKey)` fresh per invocation and passes it to `IssueFilingRunner.file(instructions:)`
- `Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift` - 6 new tests: blank-instructions trailer survival, injection-style-instructions trailer survival, whitespace-only fallback to default, non-empty instructions embedded verbatim, method=create/tool-name preserved, `assembleCommand` tool-scope independence
- `Tests/MakeAnIssueTests/IssueFilingConfigTests.swift` - 1 new test: `defaultInstructions` is non-empty

## Decisions Made
- `enforcedTrailer` was placed on `IssueFilingRunner` (not `IssueFilingConfig`) since it is provider-agnostic prose, mirroring `shellEscape`'s existing standalone-pure-static-helper pattern under the `// MARK: - Pure helpers` heading — per 08-PATTERNS.md's discretion note.
- `buildPrompt`'s new `instructions` parameter defaults to `""`, so every pre-existing call site (all prior tests, plus `file()`'s call before Task 2) compiles unchanged and exercises the D-08 fallback path implicitly.
- AppState reads the persisted instructions inside the closure body at invocation time rather than storing them as `@Published`/cached state, preserving the per-job capture-by-value isolation `spawnFilingJob` already provides for `transcript`/`repo` — this is the D-02/T-08-09 concurrency safeguard the plan required.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `IssueFilingConfig.defaultInstructions` and `IssueFilingRunner.enforcedTrailer` are both in place and ready for Plan 03's `SettingsView` Instructions tab (`@AppStorage` default/Reset button, and the read-only enforced-trailer display).
- `buildPrompt`, `file()`, and AppState's filing closure all thread `instructions` correctly; full `swift test` suite (144 tests) is green.
- No blockers for Plan 03.

## Self-Check: PASSED

- `[ -f Sources/MakeAnIssue/IssueFilingConfig.swift ]` → FOUND
- `[ -f Sources/MakeAnIssue/IssueFilingRunner.swift ]` → FOUND
- `[ -f Sources/MakeAnIssue/AppState.swift ]` → FOUND
- `[ -f Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift ]` → FOUND
- `[ -f Tests/MakeAnIssueTests/IssueFilingConfigTests.swift ]` → FOUND
- `git log --oneline --all --grep="08-02"` → returns `428fb69`, `696c178`, `38c2dfc`
- `grep -n "enforcedTrailer" Sources/MakeAnIssue/IssueFilingRunner.swift` → present, defined and referenced in `buildPrompt`
- `grep -n "defaultInstructions" Sources/MakeAnIssue/IssueFilingConfig.swift` → present
- `swift build` → Build complete, no errors
- `swift test --filter IssueFilingRunnerTests` → 25/25 passed
- `swift test --filter IssueFilingConfigTests` → 14/14 passed
- `swift test` (full suite) → 144/144 passed

## TDD Gate Compliance

Task 1 (`tdd="true"`) followed RED→GREEN: `test(08-02)` commit `428fb69` precedes `feat(08-02)` commit `696c178`. No REFACTOR commit was needed — the GREEN implementation was already minimal and clean.

---
*Phase: 08-editable-system-prompt-finding-06-cleanup*
*Completed: 2026-07-01*
