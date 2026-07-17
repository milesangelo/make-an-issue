---
phase: 08-editable-system-prompt-finding-06-cleanup
plan: 03
subsystem: ui
tags: [swift, swiftui, settings, appkit]

requires:
  - phase: 08-editable-system-prompt-finding-06-cleanup
    provides: "AppState.instructionsKey persistence-key constant (Plan 01); IssueFilingConfig.defaultInstructions + IssueFilingRunner.enforcedTrailer source-of-truth constants (Plan 02)"
provides:
  - "SettingsView TabView with 'Shortcut' and 'Instructions' tabs"
  - "Editable, persisted drafting-instructions TextEditor bound to @AppStorage(AppState.instructionsKey)"
  - "'Reset to Default' button that visibly refills the editor with IssueFilingConfig.defaultInstructions"
  - "Read-only, greyed-out display of the always-appended enforced contract (IssueFilingRunner.enforcedTrailer + IssueFilingConfig.claudeGitHub.allowedToolsArgument)"
affects: []

tech-stack:
  added: []
  patterns: ["TabView + .tabItem for multi-pane Settings windows", "read-only Text display sourced directly from real constants (never a hardcoded/paraphrased duplicate) to prevent UI-vs-behavior drift"]

key-files:
  created: []
  modified:
    - Sources/MakeAnIssue/SettingsView.swift

key-decisions:
  - "Explicit window height (460) added to the settings NSWindow/TabView container after human-verify surfaced that a width-only frame let AppKit collapse content height to ~zero, rendering both tabs empty"

patterns-established:
  - "Read-only contract-display text must render the real symbol (enforcedTrailer, allowedToolsArgument) rather than a hardcoded copy, so the UI cannot silently drift from what the app actually appends to the prompt"

requirements-completed: [SETTINGS-02, SETTINGS-03]

duration: 12min
completed: 2026-07-01
status: complete
---

# Phase 8 Plan 3: TabView Reorg + Instructions Tab Summary

**Two-tab Settings window (Shortcut / Instructions) with a persisted, editable drafting-instructions `TextEditor`, a "Reset to Default" button, and a read-only display of the always-appended enforced contract sourced directly from `IssueFilingRunner.enforcedTrailer` and `IssueFilingConfig.claudeGitHub.allowedToolsArgument`.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-07-01T14:05:00-06:00 (approx.)
- **Completed:** 2026-07-01T14:17:00-06:00 (approx.)
- **Tasks:** 2 completed (1 auto + 1 checkpoint:human-verify, approved)
- **Files modified:** 1

## Accomplishments
- Wrapped `SettingsView`'s body in a `TabView` with a "Shortcut" tab (the existing push-to-talk `KeyboardShortcuts.Recorder`, unchanged) and a new "Instructions" tab (D-09).
- Instructions tab: a multi-line `TextEditor` bound to `@AppStorage(AppState.instructionsKey) private var instructions: String = IssueFilingConfig.defaultInstructions`, with a fixed `.frame(minHeight: 160)` so it scrolls internally rather than resizing the window (D-10) — satisfying SETTINGS-02 (edits persist across app relaunch).
- "Reset to Default" `Button` whose action assigns `instructions = IssueFilingConfig.defaultInstructions`, visibly refilling the box and persisting the reverted value via `@AppStorage` (SETTINGS-03, D-07).
- Read-only, greyed-out display beneath the editor rendering `IssueFilingRunner.enforcedTrailer` and a note referencing `IssueFilingConfig.claudeGitHub.allowedToolsArgument` verbatim from the real constants — no hardcoded/paraphrased duplicate, so the UI cannot drift from what the app actually enforces (D-04).
- No `.resizable` styleMask added to the Settings window; the window stays fixed-size per D-10.
- Human-verify checkpoint (Task 2) confirmed all 8 verification steps pass, including the SETTINGS-05 regression check (no "CLI Command" field in the popover).

## Task Commits

1. **Task 1: TabView reorg + Instructions tab (editor, Reset, read-only enforced-contract display)** - `d8b9deb` (feat)
2. **Follow-up fix: explicit TabView height so tab content renders** - `74623ab` (fix) — found during Task 2 human-verify
3. **Task 2: Human-verify the Instructions tab** - checkpoint task, no code commit — user replied "approved"

**Plan metadata:** (recorded below, this commit)

## Files Created/Modified
- `Sources/MakeAnIssue/SettingsView.swift` - `TabView` with "Shortcut"/"Instructions" tabs; `@AppStorage(AppState.instructionsKey)` `TextEditor`; "Reset to Default" `Button`; read-only enforced-contract `Text` sourced from `IssueFilingRunner.enforcedTrailer` + `IssueFilingConfig.claudeGitHub.allowedToolsArgument`; explicit window height fix

## Decisions Made
- Added an explicit height (460) to the Settings window/TabView container. The original plan only specified a fixed `.frame(width: 360)` carried over from the pre-existing single-`Form` shell; with only a width constraint, `NSWindow(contentViewController:)` sized the window to near-zero content height, so both tabs appeared to render empty bodies during human-verify. Adding a fixed height fixed rendering while keeping the window non-resizable (D-10 preserved — the `Form` still scrolls internally).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] TabView content invisible due to missing window height constraint**
- **Found during:** Task 2 (human-verify checkpoint) — verifier reported both tabs appeared empty
- **Issue:** `SettingsView`'s container only carried a `.frame(width: 360)` constraint (inherited from the prior single-`Form` layout). AppKit's `NSWindow(contentViewController:)` computed a ~zero content height for the `TabView`, so neither the "Shortcut" recorder nor the "Instructions" editor/button/read-only text was visible on screen, even though the view hierarchy was correct.
- **Fix:** Added an explicit `height: 460` to the frame so AppKit sizes the window with enough vertical space to render both tabs' content. The `Form` inside the Instructions tab still scrolls internally per D-10; the window remains fixed-size (no `.resizable` styleMask).
- **Files modified:** `Sources/MakeAnIssue/SettingsView.swift`
- **Verification:** `swift build` clean; human verifier re-ran all 8 how-to-verify steps after the fix and confirmed both tabs render their content, persistence works across relaunch, Reset refills visibly, the read-only contract text is present, and no "CLI Command" field exists in the popover.
- **Committed in:** `74623ab`

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Necessary correctness fix surfaced by human verification — without it the entire Instructions tab (and Shortcut tab) would have been unusable. No scope creep; single-line frame change.

## Issues Encountered
None beyond the auto-fixed rendering bug documented above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All three plans of Phase 8 (editable system prompt + FINDING-06 cleanup) are complete: `AppState.instructionsKey` (Plan 01), `IssueFilingConfig.defaultInstructions` + `IssueFilingRunner.enforcedTrailer` + `buildPrompt` restructuring (Plan 02), and the Settings Instructions tab UI (Plan 03).
- `swift build` green; `swift test` 144/144 passing.
- Human verifier confirmed (2026-07-01, "approved"): two-tab Settings window; edited instructions persist across app relaunch (SETTINGS-02); "Reset to Default" visibly refills the field (SETTINGS-03); the read-only enforced-contract display shows the "Issue URL:" trailer and scoped tool grant, non-editable (D-04); the popover has no "CLI Command" field (SETTINGS-05 regression check passed).
- Phase 8 is ready for phase-level verification/close-out.
- Carried concern from STATE.md (unrelated to this plan's scope): hardening `IssueResultParser`'s prose fallback to match the *last* URL/line rather than the first occurrence remains open — tracked separately, not part of SETTINGS-02/SETTINGS-03.

## Self-Check: PASSED

- `[ -f Sources/MakeAnIssue/SettingsView.swift ]` → FOUND
- `git log --oneline --all --grep="08-03"` → returns `d8b9deb`, `74623ab`
- `git show --stat d8b9deb` → touches `Sources/MakeAnIssue/SettingsView.swift` (45 insertions, 9 deletions)
- `git show --stat 74623ab` → touches `Sources/MakeAnIssue/SettingsView.swift` (1 insertion, 1 deletion)
- `grep -n "TabView\|instructionsKey\|defaultInstructions\|enforcedTrailer\|allowedToolsArgument" Sources/MakeAnIssue/SettingsView.swift` → all present
- Human-verify checkpoint (Task 2): user replied "approved" confirming all 8 verification steps

---
*Phase: 08-editable-system-prompt-finding-06-cleanup*
*Completed: 2026-07-01*
