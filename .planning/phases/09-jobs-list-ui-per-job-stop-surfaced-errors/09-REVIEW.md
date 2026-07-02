---
phase: 09-jobs-list-ui-per-job-stop-surfaced-errors
reviewed: 2026-07-02T13:39:07Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/JobRowStyle.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
  - Tests/MakeAnIssueTests/JobRowStyleTests.swift
findings:
  critical: 0
  warning: 4
  info: 2
  total: 6
status: issues_found
---

# Phase 09: Code Review Report

**Reviewed:** 2026-07-02T13:39:07Z
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Reviewed the Phase 9 diff against `f760d48` — the terminal-only `dismiss(jobID:)`/`clearFinished()` mutations on `AppState`, the newly-exposed `message(for: IssueFilingError)` mapper, the new `JobRowStyle` pure-function namespace (icon/color/https-guard), and the new SwiftUI jobs-list surface in `MenuView.swift` (`JobsSection`/`JobRow`/`DismissButton`/`ClearAllButton`/`TranscriptSnippet`).

The core state mutations (`dismiss`, `clearFinished`) are correct: both use the explicit `state != .filing` predicate consistently (no drift between the two, and no drift with `ClearAllButton`'s visibility predicate), never touch in-flight jobs, and are exercised by matching unit tests. `message(for:)`'s access-level widening from `private` to internal is the minimum change needed for `MenuView` to consume it and is correctly scoped (not `public`).

The `openableIssueURL` https guard is sound as implemented and is genuinely necessary: `IssueResultParser`'s regexes accept `https?://` (not just `https`), so a `http://github.com/...` URL can legitimately reach `JobRowStyle.openableIssueURL`, and the guard correctly rejects it. However, the guard validates scheme only, not host — see WR-02 below.

No critical/blocker-level issues were found. Four warnings and two info items are listed below, centered on: (1) a dead/duplicated styling path for the `.filing` state that defeats the single-source-of-truth purpose `JobRowStyle` documents for itself, (2) an incomplete defense-in-depth claim on the URL guard, (3) a silent no-op with no user feedback on the done-row open action, and (4) a documented-but-untested SwiftUI interaction risk (`.textSelection` + `.onTapGesture`) on the new `TranscriptSnippet` view, which the codebase's own comments acknowledge has no automated coverage (view composition is "manual-UAT-only").

## Warnings

### WR-01: `JobRowStyle.iconName`/`tintColor(for: .filing)` are dead code in production — the `.filing` row hardcodes `.blue` instead of using them

**File:** `Sources/MakeAnIssue/MenuView.swift:552-564` (production call site), cross-reference `Sources/MakeAnIssue/JobRowStyle.swift:13-24` and `:29-40` (the unused `.filing` branches)

**Issue:** `JobRowStyle`'s own doc comment states its purpose is to be "the" per-state icon/color mapping so that "the view composition ... is a thin ... shell over these pure functions." `JobRow` correctly calls `JobRowStyle.iconName(for:)`/`tintColor(for:)` for `.done`, `.failed`, and `.cancelled` — but for `.filing` it does not call either function; it hardcodes `ActivitySpinner(color: .blue)` directly:

```swift
case .filing:
    HStack(spacing: 8) {
        ActivitySpinner(color: .blue)   // JobRowStyle.tintColor(for: .filing) is never called here
            .frame(width: 16, height: 16)
        Text("Filing…")
```

`JobRowStyle.tintColor(for: .filing)` happens to also return `.blue` today, so the two values are coincidentally in sync — but `JobRowStyleTests.testJobRowStyleColorPerState` asserts `.tintColor(for: .filing) == .blue` while nothing in production code actually reads that value. A future edit to `JobRowStyle.tintColor(for: .filing)` (e.g. to fix the doc comment's stated intent of avoiding collision with `StateBadge`'s palette) will pass its unit test yet produce **no visible change** in the app, because the UI never consults it. This is a duplicated magic value with an untested drift risk, not merely unused code.

**Fix:** Either route the `.filing` row through `JobRowStyle.tintColor(for: .filing)` (e.g. `ActivitySpinner(color: JobRowStyle.tintColor(for: .filing))`), or remove the `.filing` case from `JobRowStyle` entirely and adjust the test to cover only the three states actually consumed by the view, so the tested surface matches the real one.

### WR-02: `openableIssueURL` validates scheme only, not host — the "defense-in-depth" claim is incomplete

**File:** `Sources/MakeAnIssue/JobRowStyle.swift:49-54`

**Issue:** The doc comment frames this function explicitly as a security control: "This is the D-10 done-row open guard ... The parser's github-anchored regex is the first layer of trust; this is defense-in-depth at the `NSWorkspace.shared.open` call site ... (ASVS V5 input validation)." A genuine second, independent layer of defense-in-depth would re-validate the property the first layer is trusted to guarantee (host == `github.com`), not just the scheme. As written, `openableIssueURL("https://evil.example/x")` returns a non-nil URL and will be opened — the function only protects against non-`https` schemes (javascript:, file:, custom app schemes), it provides no protection if `IssueResultParser`'s host anchoring is ever weakened, bypassed by a future parsing path, or if `IssueFilingResult.url` is ever constructed from a different, less-trusted source.

Currently not exploitable in practice because the only producer of `IssueFilingResult.url` (`IssueResultParser`) anchors both its regexes to a literal `github.com/` substring — but the guard's own documentation over-claims what it verifies.

**Fix:** Either verify the host explicitly (`url.host?.lowercased() == "github.com"`, mirroring the parser's trust boundary) to make the "defense-in-depth" claim true independent of the parser, or narrow the doc comment to state plainly that only the scheme is checked and the host is trusted transitively from the parser.

### WR-03: Silent no-op — no user feedback when the done-row URL fails the `openableIssueURL` guard

**File:** `Sources/MakeAnIssue/MenuView.swift:571-574`

**Issue:**
```swift
Button(action: {
    if let url = JobRowStyle.openableIssueURL(result.url) {
        NSWorkspace.shared.open(url)
    }
}) {
    Text("Issue #\(result.number) filed")
        .font(.system(size: 12))
}
```
If `openableIssueURL` returns `nil` (e.g. a `http://` URL — a real possibility since `IssueResultParser`'s regexes match `https?://`), the button click does nothing at all: no status text update, no alert, no visual indication that the click was received but rejected. A user clicking "Issue #N filed" and seeing nothing happen has no way to tell the difference between "browser is slow to launch" and "this URL was rejected by policy." This degrades the resilience/error-surfacing goal that is otherwise the explicit point of this phase (RESIL-01 in the surrounding docs).

**Fix:** On guard failure, route through `appState.statusText` (or an equivalent local `@State` message) so the rejection is visible, e.g. `appState.statusText = "Could not open issue URL"` in the `else` branch.

### WR-04: `TranscriptSnippet`'s tap-to-expand may be defeated by `.textSelection(.enabled)`, with no test to catch it

**File:** `Sources/MakeAnIssue/MenuView.swift:527-543`

**Issue:**
```swift
struct TranscriptSnippet: View {
    let transcript: String
    @State private var isExpanded = false

    var body: some View {
        Text(transcript)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(isExpanded ? nil : 2)
            .textSelection(.enabled)
            .onTapGesture {
                withAnimation {
                    isExpanded.toggle()
                }
            }
    }
}
```
On macOS, `Text` with `.textSelection(.enabled)` is backed by a selectable-text host view that is known to intercept single-click/tap events for selection purposes, which can prevent a co-located `.onTapGesture` from firing reliably (a well-known SwiftUI-on-macOS interaction gap). If that happens here, the only way to read a truncated `.failed`-row transcript beyond two lines is broken silently — the row still renders and looks interactive (it's the only element in the file with an `onTapGesture`), but nothing happens on tap. `JobRowStyle.swift`'s own doc comment acknowledges this whole view layer has zero automated coverage ("view composition in Plan 09-02 is a thin, manual-UAT-only shell"), so this is exactly the kind of regression that would ship silently.

**Fix:** Verify interactively (drag-select vs. single-click behavior) on the actual target macOS version. If tap-to-expand doesn't fire reliably with text selection enabled, replace the bare `.onTapGesture` with an explicit disclosure control (e.g. a small chevron `Button`) that doesn't compete with the selectable-text hit-testing, or drop `.textSelection(.enabled)` on this specific snippet if selection isn't essential for a truncated preview.

## Info

### IN-01: "FILING JOBS (N)" header count includes terminal (done/failed/cancelled) jobs, not just in-flight ones

**File:** `Sources/MakeAnIssue/MenuView.swift:482`

**Issue:** `Text("FILING JOBS (\(appState.jobs.count))")` counts every entry in `appState.jobs`, including `.done`, `.failed`, and `.cancelled` jobs that are simply retained for display (per D-06/D-07). A user with three finished jobs and zero active ones will see "FILING JOBS (3)", which reads as "3 jobs currently filing" when in fact none are. This is a labeling nit, not a functional defect — the count is technically correct as "number of rows shown," just ambiguous given the section title.

**Fix:** Either rename the header to something count-agnostic ("JOBS (N)" / "RECENT JOBS (N)"), or compute the count as `appState.jobs.filter { $0.state == .filing }.count` if the header is meant to convey active work.

### IN-02: Stale doc comment on `AppState.message(for: IssueFilingError)`

**File:** `Sources/MakeAnIssue/AppState.swift:423-425`

**Issue:** The doc comment above the now-internal `message(for:)` still reads: "Only the success path speaks (v1 contract); failures surface as status text only." That was accurate pre-Phase-9, but this exact method is now also called directly from `JobRow`'s `.failed` case (`Sources/MakeAnIssue/MenuView.swift:593`) to render per-job error text in the jobs list — i.e. failures now surface in a second UI surface beyond `statusText`. The comment should be updated so a future reader doesn't assume `message(for:)` is status-text-only and duplicate the logic elsewhere.

**Fix:** Update the comment to note the method is shared between `statusText` and the per-job `JobRow` failed-row display.

---

_Reviewed: 2026-07-02T13:39:07Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
