# Phase 8: Editable System Prompt + FINDING-06 Cleanup - Pattern Map

**Mapped:** 2026-07-01
**Files analyzed:** 6 (5 modified, 1 no-change dependency)
**Analogs found:** 6 / 6 (all in-repo — this is a small, self-contained SwiftUI app; every analog is a sibling file already in the phase's own touch-list)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|--------------------|------|-----------|-----------------|----------------|
| `Sources/MakeAnIssue/SettingsView.swift` (TabView reorg + Instructions tab) | component (SwiftUI View) | request-response (form binding → `@AppStorage`) | itself, current `Form` (lines 4-21) | exact — extend existing file, same idiom |
| `Sources/MakeAnIssue/AppState.swift` (`instructionsKey` add / `cliCommandKey` remove) | model / config constant holder | CRUD (UserDefaults key definition) | itself, `cliCommandKey` (line 22) | exact — literal template to copy-and-rename |
| `Sources/MakeAnIssue/MenuView.swift` (remove CLI Command field) | component (SwiftUI View) | request-response | itself, `DisclosureGroup` block (lines 61-84) + `@AppStorage` decl (line 8) | exact — this is the deletion target itself |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` (`buildPrompt()` restructure + enforced trailer builder) | service (pure string-building function) | transform | itself, `buildPrompt()` (lines 48-73) | exact — refactor site itself |
| `Sources/MakeAnIssue/IssueFilingConfig.swift` (new canonical default-instructions constant) | config (static struct constants) | CRUD (static data) | itself, `IssueFilingConfig.claudeGitHub` (lines 80-89) | exact — same file/struct is the natural home |
| `Sources/MakeAnIssue/AppDelegate.swift` (no functional change expected — verify window still fits TabView) | controller (NSWindowController glue) | request-response | itself, `showSettingsWindow()` (lines 132-149) | exact — read-only reference, D-10 says window stays fixed-size |
| `Sources/MakeAnIssue/IssueResultParser.swift` | service (pure parser) | transform | N/A — **no changes**, dependency-only | n/a |

## Pattern Assignments

### `Sources/MakeAnIssue/AppState.swift` — new `instructionsKey` / remove `cliCommandKey`

**Analog:** itself, line 22 (the exact pattern to mirror and the exact line to delete)

**Current key-constant pattern** (`AppState.swift:19-23`):
```swift
@MainActor
final class AppState: ObservableObject {
    /// Shared UserDefaults key for the CLI command — must match @AppStorage in MenuView (Pitfall 5).
    static let cliCommandKey = "cliCommand"
```

**Apply:**
- Delete the `cliCommandKey` constant + its doc comment (D-01).
- Add a same-shaped constant, e.g.:
  ```swift
  /// Shared UserDefaults key for the editable drafting-instructions field — must match
  /// @AppStorage in SettingsView (Pitfall 5 pattern, mirrors former cliCommandKey).
  static let instructionsKey = "instructions"
  ```
- Note the existing doc-comment convention explicitly calls out "must match @AppStorage in <consumer view>" — replicate that cross-reference comment for the new key, updated to point at `SettingsView`.

---

### `Sources/MakeAnIssue/MenuView.swift` — remove orphaned "CLI Command" field (D-01)

**Analog:** itself — this IS the deletion target.

**Lines to remove:**
- `MenuView.swift:8` — `@AppStorage(AppState.cliCommandKey) private var cliCommand: String = "claude"`
- `MenuView.swift:61-84` — the entire `DisclosureGroup` body's `VStack` containing the "CLI Command" `Text` label + `TextField`:
```swift
DisclosureGroup(isExpanded: $isSettingsExpanded) {
    VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
            Text("CLI Command")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            TextField("e.g. claude", text: $cliCommand)
                .textFieldStyle(.roundedBorder)
        }
    }
    .padding(.bottom, 4)
} label: {
    HStack(spacing: 6) {
        Image(systemName: "gearshape.fill")
        Text("Settings")
        Spacer()
    }
    .foregroundColor(.secondary)
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

**D-01a orphan check:** After removing the `TextField`, the `DisclosureGroup`'s content `VStack` becomes empty (it held only the one `VStack(CLI Command)` child). Per D-01a, remove the now-pointless `DisclosureGroup`/`Divider` (lines 58-84) entirely if nothing else lives there — confirmed by reading the full file: no other settings live in this disclosure group, so the whole block (including the `Divider()` at line 59 introducing it and `isSettingsExpanded` @State at line 10) is orphaned and should be deleted, not just the TextField. Grep for `isSettingsExpanded` before deleting to confirm no other usage (only line 10 decl + line 61 binding found in current read).
- Leave `updateShortcutText()`/`shortcutText` alone — unrelated to this cleanup, used by `ActionCard`.

---

### `Sources/MakeAnIssue/SettingsView.swift` — TabView reorg + Instructions tab (D-09, D-10)

**Analog:** itself (lines 1-21) — current single-`Form` shell is the base to extend, not replace wholesale.

**Current shell** (`SettingsView.swift:1-21`):
```swift
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Push-to-Talk Shortcut")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    KeyboardShortcuts.Recorder("", name: .pushToTalk)
                        .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding()
    }
}
```

**Apply (D-09/D-10):**
- Wrap in `TabView { ... }` with two tabs, each keeping the existing `Form { Section { ... } }.formStyle(.grouped)` idiom per-tab (matches Phase 7's established `.formStyle(.grouped)` convention — reuse verbatim inside each tab, don't invent a new form style).
- Tab 1 "Shortcut": exact existing `Form`/`Section`/`KeyboardShortcuts.Recorder` block unchanged, just nested inside `.tabItem { Text("Shortcut") }`.
- Tab 2 "Instructions": new `Form`/`Section` with:
  - `TextEditor(text: $instructions)` bound to `@AppStorage(AppState.instructionsKey) private var instructions: String = <default>` (mirrors the `@AppStorage` decl pattern at `MenuView.swift:8`, same file-level property-wrapper style, just relocated to `SettingsView` and renamed).
  - `.frame(minHeight: 8*lineheight...)` per D-10 fixed min-height (no `.resizable` on the window — `AppDelegate.showSettingsWindow()` sets no `.resizable` styleMask, so the window itself stays fixed by omission; only the editor content needs the internal min-height/scroll).
  - Read-only enforced-trailer `Text` block below the editor (D-04) — style it greyed-out, e.g. `.foregroundColor(.secondary)` + smaller font, matching the existing `.foregroundColor(.secondary)` convention used for field labels throughout this file and `MenuView.swift`.
  - "Reset to Default" `Button` that writes the canonical default constant back into `instructions` (D-07) — a plain `Button(action:)` in the SwiftUI idiom already used in `MenuView.swift`'s `CopyButton`/`Button(action: {...})` pattern (`MenuView.swift:493-504`).
- Keep the overall `.frame(width: 360)` sizing convention from the current file; widen only if the multi-line editor needs it, but do not add `.resizable`.

**Note on window frame:** `AppDelegate.showSettingsWindow()` (`AppDelegate.swift:138-149`) constructs the `NSWindow` from `NSHostingController(rootView: SettingsView()...)` with `styleMask = [.titled, .closable, .miniaturizable]` and no explicit size — the window auto-sizes to the hosted SwiftUI content's intrinsic size. Adding a `TabView` + `TextEditor` with a fixed min-height will change the intrinsic content size (likely taller); no code change needed in `AppDelegate.swift` itself, but visually verify the window still looks fixed/sane after the SettingsView layout change (D-10's "fixed size" constraint is satisfied by SwiftUI's `.frame`, not by `AppDelegate`).

---

### `Sources/MakeAnIssue/IssueFilingConfig.swift` — new canonical default-instructions constant (D-06, Claude's Discretion)

**Analog:** `IssueFilingConfig.claudeGitHub` static constant (`IssueFilingConfig.swift:80-89`)

**Pattern to mirror** (static constant living in the same struct/file as other provider-config defaults):
```swift
static let claudeGitHub = IssueFilingConfig(
    cliCommand: "claude",
    ...
)
```

**Recommended seam:** Add a second top-level `static let defaultInstructions: String = "..."` (or a small enum/struct `DefaultInstructions`) in this same file, right after `claudeGitHub`, under a `// MARK: - Default drafting instructions` comment matching the existing `// MARK: - Default` convention (line 69). This file is already "the single source of truth for the CLI command" per the phase brief — extending it to also be the single source of truth for the default guidance text keeps both canonical constants co-located and importable from both `SettingsView` (for `@AppStorage` default + Reset) and `IssueFilingRunner.buildPrompt()` without new cross-file coupling. `IssueFilingRunner.swift` already imports nothing special to reach `IssueFilingConfig` (same module, no import needed — confirm both files have `import Foundation` only, no module boundary).

**Content of the default constant (D-06):** extract verbatim from the current `buildPrompt()` step 1 + persona framing (`IssueFilingRunner.swift:61-67`, excluding step 3's URL trailer):
```
You are make-an-issue: you turn a developer's spoken thought into a GitHub issue for \(repoRef).
...
Steps:
1. Briefly investigate the repo (README, relevant source files) to write a specific, accurate issue.
2. File the issue using the \(config.mcpToolName) tool with method=create.
```
Note `repoRef` and `config.mcpToolName` are runtime-interpolated by the app framing, NOT part of the user-editable guidance — the extracted default constant should be the **static prose only** ("Briefly investigate the repo (README, relevant source files) to write a specific, accurate issue." style persona/investigation guidance), not the templated step-2 file-it directive (that stays app-owned per D-02, since it references `config.mcpToolName`).

---

### `Sources/MakeAnIssue/IssueFilingRunner.swift` — `buildPrompt()` restructure (D-02, D-03, D-08)

**Analog:** itself, `buildPrompt()` (`IssueFilingRunner.swift:48-73`)

**Current interleaved structure:**
```swift
static func buildPrompt(
    transcript: String,
    ownerRepo: String?,
    config: IssueFilingConfig
) -> String {
    let repoRef: String
    if let ownerRepo = ownerRepo {
        repoRef = "the repository \(ownerRepo) (current working directory)"
    } else {
        repoRef = "the repository in the current working directory"
    }

    return """
    You are make-an-issue: you turn a developer's spoken thought into a GitHub issue for \(repoRef).

    Spoken transcript: "\(transcript)"

    Steps:
    1. Briefly investigate the repo (README, relevant source files) to write a specific, accurate issue.
    2. File the issue using the \(config.mcpToolName) tool with method=create.
    3. On the LAST line of your response, output ONLY the new issue URL in this exact format:
       Issue URL: https://github.com/<owner>/<repo>/issues/<NUMBER>

    Do not ask for confirmation; file it directly.
    """
}
```

**Apply (D-02/D-03/D-08):**
- Add an `instructions: String` parameter (Claude's Discretion: "new parameter vs read at call site" — a parameter keeps `buildPrompt` a pure, testable function consistent with the file's existing "Pure helpers (fully unit-testable, no I/O)" MARK at line 22-23; prefer this over reading `@AppStorage`/`UserDefaults` inside the runner, which would break the pure-function testability the file already documents).
- D-08 fallback: caller (or `buildPrompt` itself) substitutes `IssueFilingConfig.defaultInstructions` when the passed `instructions` is empty/whitespace-only — `.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` check, consistent with existing trim-and-check idiom already used in this file for the token (`IssueFilingRunner.swift:133`: `stdout.trimmingCharacters(in: .whitespacesAndNewlines)` / `guard !trimmed.isEmpty`).
- Split the return into `{app framing + transcript}` + `{user guidance}` + `{enforced trailer}` per D-02/D-03. Extract step 3 (URL trailer) into a separate static helper, e.g. `enforcedTrailer` (String constant or computed static var), living in this file near `buildPrompt` (mirrors `shellEscape` being a small standalone static pure helper right above `buildPrompt`, lines 32-35) OR as a new field on `IssueFilingConfig` if it should vary per-provider — given D-04 says "the app owns... the enforced trailer" and it's currently provider-agnostic prose (only the URL format is GitHub-specific, matching `config.mcpToolName`'s GitHub-only usage already in step 2), keep it in `IssueFilingRunner.swift` as a static helper alongside `buildPrompt`, not in `IssueFilingConfig`.
- Example resulting shape (illustrative, not final wording — D-04 discretion covers exact trailer text):
```swift
static func buildPrompt(
    transcript: String,
    ownerRepo: String?,
    instructions: String,
    config: IssueFilingConfig
) -> String {
    let repoRef = ...  // unchanged
    let guidance = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? IssueFilingConfig.defaultInstructions
        : instructions
    return """
    You are make-an-issue: ... for \(repoRef).

    Spoken transcript: "\(transcript)"

    \(guidance)

    File the issue using the \(config.mcpToolName) tool with method=create.

    \(enforcedTrailer)
    """
}
```
- **Do not touch** `assembleCommand()` (`IssueFilingRunner.swift:81-92`) or the `--allowedTools` line (line 90) — already correctly app-owned/outside-the-prompt per the phase brief; this is confirmed by direct read, no change needed.
- Update the one call site inside `file()` (`IssueFilingRunner.swift:153`: `let prompt = buildPrompt(transcript: transcript, ownerRepo: ownerRepo, config: config)`) to thread the new `instructions` parameter through — this likely means `file()` itself gains an `instructions: String = ...` parameter, and `AppState.swift`'s `onRunIssueFiling` closure signature (`AppState.swift:107-109`) and its call site (`AppState.swift:280`: `try await onRunIssueFiling(transcript, repo, onStarted)`) need the instructions value threaded in too — read at call time from `@AppStorage`/`UserDefaults(AppState.instructionsKey)` in `AppState` or `AppDelegate`, NOT stored as fresh `@Published` state (keeps per-invocation isolation per Claude's Discretion note; `UserDefaults.standard.string(forKey: AppState.instructionsKey)` read fresh at each `spawnFilingJob` call avoids the concurrent-job staleness `AppState.swift`'s existing `[weak self, id, transcript, repo]` capture-by-value pattern (`AppState.swift:277`) already protects against for other parameters).

## Shared Patterns

### `@AppStorage` persistence
**Source:** `MenuView.swift:8` (`@AppStorage(AppState.cliCommandKey) private var cliCommand: String = "claude"`) — the pattern being removed, and also the exact template for the new instructions binding in `SettingsView.swift`.
**Apply to:** `SettingsView.swift` (new `instructionsKey` binding), `AppState.swift` (new key constant).

### Static config constants co-located with their consumer struct
**Source:** `IssueFilingConfig.swift:80-89` (`static let claudeGitHub`).
**Apply to:** new `static let defaultInstructions` in the same file/struct.

### Pure, testable static helper functions with doc comments explaining the "why"
**Source:** `IssueFilingRunner.swift:32-73` (`shellEscape`, `buildPrompt` — both under the `// MARK: - Pure helpers (fully unit-testable, no I/O)` heading).
**Apply to:** new `enforcedTrailer` helper — keep it a pure static function/constant under the same MARK, with a doc comment cross-referencing D-03/SETTINGS-04 the way existing comments cross-reference spike findings and decision IDs (e.g. `IssueFilingRunner.swift:29` "(T-04-04)", `IssueFilingConfig.swift:55` "[Spike 001]").

### Trim-and-fallback-to-default idiom
**Source:** `IssueFilingRunner.swift:133-137` (token trim + empty check).
**Apply to:** D-08's blank-instructions-falls-back-to-default logic in `buildPrompt()`.

### Decision-ID doc-comment convention
**Source:** pervasive throughout `AppState.swift`, `AppDelegate.swift`, `IssueFilingRunner.swift` (e.g. `AppState.swift:34` "(D-06/D-07)", `AppDelegate.swift:34` "(D-04)"). Every non-trivial line in this codebase carries an inline `// (D-xx)` or `(SPIKE/Pitfall N)` cross-reference to its origin decision.
**Apply to:** all new code this phase — annotate new lines with `(D-01)`, `(D-03)`, `(D-06)` etc. matching the existing house style; the planner/implementer should NOT skip this even though it's not "logic."

## No Analog Found

None — this is a small, single-target-app codebase where every touched file already contains the exact pattern to extend (the phase is almost entirely surgical edits to existing files, not new-file creation). No external/library analog search was needed beyond the files listed in `<required_reading>`/the touch-list.

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/` (all 7 files explicitly listed in the task were read directly; no broader Glob/Grep sweep was needed since CONTEXT.md and the task prompt already enumerated the exact touch-list and every file is small enough to read in full).
**Files scanned:** 7 (all fully read, no file exceeded ~460 lines, no offset/limit paging needed)
**Pattern extraction date:** 2026-07-01
