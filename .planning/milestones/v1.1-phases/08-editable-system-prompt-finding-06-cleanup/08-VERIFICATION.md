---
phase: 08-editable-system-prompt-finding-06-cleanup
verified: 2026-07-01T14:29:00Z
status: passed
score: 14/14 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: human_needed
  previous_score: 13/14
  gaps_closed:
    - "Truth 9 — persisted instructions are read fresh per filing invocation, no concurrent-job staleness (D-02)"
  gaps_remaining: []
  regressions: []
---

# Phase 8: Editable System Prompt + FINDING-06 Cleanup Verification Report

**Phase Goal:** Editable, persisted drafting instructions in Settings with an unbreakable enforced contract; resolve the orphaned "CLI Command" field.
**Verified:** 2026-07-01T14:29:00Z
**Status:** passed
**Re-verification:** Yes — after gap closure (commit `39258ad`)

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The menu-bar popover shows no "CLI Command" field — no false affordance remains (SETTINGS-05, D-01) | VERIFIED | `grep -n "CLI Command" Sources/MakeAnIssue/MenuView.swift` → no matches; `grep -n "DisclosureGroup" MenuView.swift` → no matches |
| 2 | `AppState.cliCommandKey` no longer exists anywhere in the source tree (D-01) | VERIFIED | `grep -rn "cliCommandKey" Sources/ Tests/` → no matches (only a doc-comment prose mention of the former name, not a symbol reference) |
| 3 | `AppState.instructionsKey` exists as the shared UserDefaults key for the editable instructions field (D-05) | VERIFIED | `AppState.swift:23` → `nonisolated static let instructionsKey = "instructions"`, doc comment cross-references `SettingsView` and `(D-05)` |
| 4 | The app still builds and the existing AppState/MenuView tests still pass after the removal | VERIFIED | `swift build` → Build complete, no errors (re-run by verifier); full `swift test` re-run by verifier: 145/145, 0 failures |
| 5 | `buildPrompt` appends the enforced URL-line trailer regardless of the instructions value (SETTINGS-04, D-03) | VERIFIED | Ran `swift test --filter testBuildPromptWithArbitraryInstructionsEndsWithEnforcedTrailer` directly → passed. Source: `IssueFilingRunner.swift:86-96`, `enforcedTrailer` appended last, after `guidance`. |
| 6 | The assembled command still carries the scoped `--allowedTools` grant no matter what the user typed (SETTINGS-04) | VERIFIED | Ran `swift test --filter testAssembleCommandStillContainsScopedAllowedToolsWithArbitraryInstructions` directly → passed. Source: `assembleCommand` derives `--allowedTools` from `config.allowedToolsArgument` only; `instructions` never reaches it. |
| 7 | A blank or whitespace-only instructions value falls back to `IssueFilingConfig.defaultInstructions` at build time (D-08) | VERIFIED | Ran `swift test --filter testBuildPromptWithWhitespaceOnlyInstructionsFallsBackToDefault` directly → passed. Source: `IssueFilingRunner.swift:81-84` trim-and-check idiom. |
| 8 | The default drafting guidance lives in exactly one canonical constant (D-06) | VERIFIED | `grep -rn "defaultInstructions" Sources/` shows exactly one declaration (`IssueFilingConfig.swift:102`) and three consumers (`buildPrompt`, `SettingsView` `@AppStorage` default, `SettingsView` Reset button) — all reference the same symbol, no duplicate literal. |
| 9 | The persisted instructions are read fresh per filing invocation — no concurrent-job staleness (D-02 concurrency safeguard) | VERIFIED | Gap closed by commit `39258ad`. `AppState.swift:29-33` extracts the read into `nonisolated static func currentPersistedInstructions(_ defaults: UserDefaults = .standard) -> String { defaults.string(forKey: AppState.instructionsKey) ?? "" }`; the production default `onRunIssueFiling` closure (`AppState.swift:122`) calls this exact function — confirmed the only call site besides the new test (`grep -rn "currentPersistedInstructions"` → 1 production call, 4 test calls, no other reads of `instructionsKey`). New test `testCurrentPersistedInstructionsReadsFreshPerInvocation` (`AppStateTests.swift:1349-1370`) uses an isolated `UserDefaults(suiteName:)`, asserts blank-when-unset, then reads "first guidance", then **mutates the key between invocations** to "second guidance" and asserts the very next call returns the new value — deterministically proving no per-instance caching. Re-ran directly by this verifier: `swift test --filter testCurrentPersistedInstructionsReadsFreshPerInvocation` → 1 test, 0 failures. Full suite re-run by this verifier: `swift test` → 145 tests, 0 failures. The function is stateless/pure (no instance vars, no memoization) and reads a thread-safe store (`UserDefaults`), so the mutate-between-calls proof of freshness directly establishes the "no concurrent-job staleness" property — a stale read could only occur via caching or init-time capture, both of which this test falsifies. |
| 10 | The Settings window has a "Shortcut" tab and an "Instructions" tab (D-09) | VERIFIED | Source: `SettingsView.swift` `TabView` with `.tabItem { Text("Shortcut") }` / `.tabItem { Text("Instructions") }`. Human-verify checkpoint (08-03 Task 2) confirmed both tabs render and are reachable — approved by user. |
| 11 | The Instructions tab shows an editable multi-line instructions field whose contents persist across app launches (SETTINGS-02) | VERIFIED (human-confirmed) | Source: `@AppStorage(AppState.instructionsKey) private var instructions` bound to `TextEditor(text: $instructions)`. Human-verify checkpoint step 5 confirmed persistence across an actual app relaunch — approved. |
| 12 | A "Reset to Default" control visibly refills the field with the shipped default and persists it (SETTINGS-03, D-07) | VERIFIED (human-confirmed) | Source: `Button("Reset to Default") { instructions = IssueFilingConfig.defaultInstructions }`. Human-verify checkpoint step 6 confirmed visible refill — approved. |
| 13 | The always-appended enforced trailer + scoped tool grant are shown read-only beneath the editor (D-04) | VERIFIED (human-confirmed) | Source: `Text(IssueFilingRunner.enforcedTrailer)` and `Text("Always-applied tool grant: \(IssueFilingConfig.claudeGitHub.allowedToolsArgument)")` — both non-editable `Text` views sourced directly from the real constants (no hardcoded/paraphrased duplicate). Human-verify checkpoint step 7 confirmed visible + non-editable — approved. |
| 14 | The Settings window stays a fixed size; the editor has a fixed min-height and scrolls internally (D-10) | VERIFIED | Source: `SettingsView.swift:54` `.frame(width: 360, height: 460)`, no `.resizable` styleMask; `TextEditor(...).frame(minHeight: 160)` (line 34). Human-verify checkpoint noted the window rendering fix (74623ab) and confirmed no awkward resizing — approved. |

**Score:** 14/14 truths verified (0 present + wired, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/MenuView.swift` | Popover UI with orphaned CLI Command DisclosureGroup removed | VERIFIED | No `DisclosureGroup`, no `cliCommand`, no `isSettingsExpanded`; `updateShortcutText()`/`ShortcutPillView`/`ActionCard` untouched |
| `Sources/MakeAnIssue/AppState.swift` | `instructionsKey` added; `cliCommandKey` removed; `currentPersistedInstructions()` helper added (gap closure) | VERIFIED | Line 23: `nonisolated static let instructionsKey = "instructions"`; lines 29-33: `nonisolated static func currentPersistedInstructions`; no `cliCommandKey` symbol anywhere |
| `Sources/MakeAnIssue/IssueFilingConfig.swift` | Canonical `defaultInstructions` constant (D-06) | VERIFIED | Line 102, single declaration, non-empty, doc-commented with D-06/D-08 cross-references |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | `enforcedTrailer` + restructured `buildPrompt(instructions:)` + `file(instructions:)` | VERIFIED | `enforcedTrailer` (lines 43-48), `buildPrompt` 4-segment restructure (lines 68-97), `file(instructions:)` threading (lines 137-180) |
| `Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift` | SETTINGS-04 tests — trailer + tool scope survive arbitrary/blank instructions | VERIFIED | 6 new tests present (lines 96-190), 3 re-run directly by verifier and passed |
| `Sources/MakeAnIssue/SettingsView.swift` | `TabView` (Shortcut + Instructions); `@AppStorage(instructionsKey)` `TextEditor`; Reset button; read-only enforced-trailer display | VERIFIED | All elements present and wired to real constants (lines 7, 11-53) |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | `testCurrentPersistedInstructionsReadsFreshPerInvocation` exercising the real (non-stubbed) read path (gap closure) | VERIFIED | Lines 1349-1370; re-run directly by verifier, passed |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `SettingsView.swift` | `AppState.swift` | `@AppStorage(AppState.instructionsKey)` binding | WIRED | `SettingsView.swift:7` |
| `AppState.swift` | `IssueFilingRunner.swift` | default `onRunIssueFiling` closure calls `AppState.currentPersistedInstructions()`, passes `instructions:` to `file()` | WIRED — now behaviorally verified (Truth 9) | `AppState.swift:118-124` |
| `AppState.currentPersistedInstructions()` | `UserDefaults` | direct `.string(forKey:)` read, no caching, parameterized on `defaults` for testability | WIRED, behavior-verified | `AppState.swift:29-33`; test-confirmed fresh-per-invocation |
| `IssueFilingRunner.swift` | `IssueFilingConfig.swift` | `buildPrompt` D-08 blank-fallback substitutes `defaultInstructions` | WIRED | `IssueFilingRunner.swift:81-84`; test-confirmed |
| `SettingsView.swift` | `IssueFilingConfig.swift` | `@AppStorage` default + Reset use `defaultInstructions` | WIRED | `SettingsView.swift:7, 37` |
| `SettingsView.swift` | `IssueFilingRunner.swift` | read-only display renders `enforcedTrailer` verbatim | WIRED | `SettingsView.swift:44` |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Build is green | `swift build` | Build complete, no errors | PASS |
| Trailer survives adversarial instructions | `swift test --filter testBuildPromptWithArbitraryInstructionsEndsWithEnforcedTrailer` | passed | PASS |
| Whitespace-only instructions fall back to default | `swift test --filter testBuildPromptWithWhitespaceOnlyInstructionsFallsBackToDefault` | passed | PASS |
| Tool scope independent of instructions | `swift test --filter testAssembleCommandStillContainsScopedAllowedToolsWithArbitraryInstructions` | passed | PASS |
| Instructions read fresh per invocation, no caching (D-02 gap closure) | `swift test --filter testCurrentPersistedInstructionsReadsFreshPerInvocation` | 1 test, 0 failures | PASS |
| Full regression suite | `swift test` | 145 tests, 0 failures | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|--------------|--------|----------|
| SETTINGS-02 | 08-02, 08-03 | Editable instructions field, persisted across launches | SATISFIED | `@AppStorage(instructionsKey)` binding + human-confirmed persistence; freshness-per-invocation now test-proven |
| SETTINGS-03 | 08-03 | "Reset to Default" control | SATISFIED | Reset button + human-confirmed visible refill |
| SETTINGS-04 | 08-02 | Enforced contract cannot be removed by edits | SATISFIED | `enforcedTrailer` always-appended-last + `--allowedTools` independence, both test-proven directly by verifier |
| SETTINGS-05 | 08-01 | Orphaned "CLI Command" field resolved, no false affordance | SATISFIED | Field + DisclosureGroup fully removed; grep-confirmed. Minor caveat: see WR-01 below (non-blocking, does not gate this requirement per explicit scoping). |

No orphaned requirements: `REQUIREMENTS.md` maps only SETTINGS-02/03/04/05 to Phase 8, and all four appear across the three plans' `requirements` frontmatter.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Sources/MakeAnIssue/AppState.swift` | 411 | `.permissionDenied` maps to `"Issue tool not granted — check CLI Command config"` — references a config field this very phase deleted | WARNING (from 08-REVIEW.md WR-01) | User-facing message points to a non-existent control. Does not block SETTINGS-05 (the false affordance removed was the popover field itself, not this error string), but is a residual inconsistency introduced by this phase's own cleanup. Confirmed still present at verification time via direct file read. |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | 37-48 | `enforcedTrailer` doc comment frames the trailer as part of the "unbreakable" SETTINGS-04 contract without distinguishing it from the hard `--allowedTools` boundary | WARNING (from 08-REVIEW.md WR-02) | Documentation/precision issue only — the trailer is a soft, prompt-level, best-effort instruction (adversarial guidance could in principle cause the model to ignore it), whereas the tool-scope grant is a hard CLI-argument boundary. No code defect; only the framing overstates the guarantee. |

Both items are pre-existing findings from `08-REVIEW.md` (0 critical / 2 warning / 2 info), independently re-confirmed by this verifier via direct source read. Neither is a debt marker (no TBD/FIXME/XXX), and neither blocks a must-have truth. Unchanged since the initial verification pass — not affected by the gap-closure commit.

### Gaps Summary

No gaps remain. All 14 observable truths, all 4 roadmap success criteria, and all 4 requirement IDs (SETTINGS-02/03/04/05) have direct, verifiable implementation evidence: source artifacts exist, are substantive (no stubs, no placeholder text), and are wired end-to-end (Settings UI ↔ AppState ↔ IssueFilingRunner ↔ IssueFilingConfig).

The previously open item (Truth 9 — D-02 concurrency-freshness invariant) is now closed. Commit `39258ad` extracted the inline `UserDefaults` read into `AppState.currentPersistedInstructions()`, a stateless static function the production closure calls verbatim, and added a test that mutates the persisted value between two invocations to prove no caching/staleness. This verifier independently re-read both changed files, confirmed the extraction is the sole production call site (no divergent duplicate read path), and re-ran both the single named test and the full 145-test suite directly — all green.

Two non-blocking WARNING-level findings from `08-REVIEW.md` (WR-01: stale "CLI Command config" string in the `.permissionDenied` error path; WR-02: `enforcedTrailer` documentation overstates a soft guarantee as equivalent to the hard tool-scope boundary) remain unaddressed but do not gate any of the four SETTINGS requirements and were out of scope for this gap-closure commit.

---

*Verified: 2026-07-01T14:29:00Z*
*Verifier: Claude (gsd-verifier)*
