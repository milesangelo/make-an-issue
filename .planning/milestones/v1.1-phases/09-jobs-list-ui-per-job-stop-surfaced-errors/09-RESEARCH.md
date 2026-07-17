# Phase 9: Jobs List UI + Per-Job Stop + Surfaced Errors - Research

**Researched:** 2026-07-01
**Domain:** SwiftUI menu-bar popover UI over an existing `@Published` jobs model (macOS, AppKit host)
**Confidence:** HIGH

## Summary

This is a small, almost entirely additive UI phase on top of a fully-built and fully-tested
backend (`AppState.jobs`, `cancel(jobID:)`, `cancelAll()`, `forceKillAllProcessTrees()` from
Phases 5–6). `MenuView.swift` currently renders zero job state — the entire "Filing Jobs" surface
(JOBS-01/JOBS-02/RESIL-01) is new code, but every piece of it composes directly from patterns
already proven in the file: the `TranscriptCard` scroll pattern, the `ActivitySpinner`/
`WaveformView` indicators, the `StatusBanner` amber treatment, and the `CopyButton` small-pill
button idiom.

Two concrete, code-verified findings shape the plan:

1. **`AppState.message(for error: IssueFilingError)` (line 412) is dead code today** — declared
   `private static`, never called anywhere in the file (confirmed via grep; only the
   `TranscriberError` overload at line 395 is invoked, from line 253). D-09's "expose" is
   therefore a one-line change (drop `private`, leaving default `internal` access — MenuView.swift
   is in the same target, so no `public`/module boundary is crossed) plus wiring it into the new
   failed-row view.
2. **No snapshot/view-inspection test infra exists** (`Package.swift` has zero test dependencies
   beyond XCTest; no ViewInspector, no SnapshotTesting). Every prior phase's SwiftUI logic is
   verified indirectly through `AppState` state assertions (see `AppStateTests.swift`), never
   through rendered-view assertions. This constrains the Validation Architecture: per-state
   icon/label/color decisions should be pulled out as pure, testable functions; actual pixel/row
   rendering is necessarily manual-only (UAT), consistent with every phase before this one.

**Primary recommendation:** Add a `JobsSection` + `JobRow` view pair inserted into `MenuView.body`
after `TranscriptCard` (D-11/D-12), reusing `TranscriptCard`'s `ScrollView{}.frame(maxHeight:)`
pattern for the list and `ActivitySpinner` for the `.filing` indicator; add `dismiss(jobID:)` and
`clearFinished()` next to `cancel`/`cancelAll` in `AppState.swift`; expose
`message(for: IssueFilingError)` by dropping `private`; use a tap-to-expand `@State` toggle (not
bare `lineLimit` + `textSelection`) for the D-08 transcript snippet, since `lineLimit`-truncated
`Text` + `.textSelection(.enabled)` reaching hidden/overflow text is unverified SwiftUI behavior.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JOBS-01 | Menu shows a list of active filing jobs, each with state (filing/done/failed/cancelled) and an activity indicator | Architecture Patterns → `JobsSection`/`JobRow`; Code Examples; reuse of `ActivitySpinner` (MenuView.swift:309–328) |
| JOBS-02 | Each active job row has a Stop control that cancels that specific job | Code Examples → `JobRow` Stop button calling `appState.cancel(jobID: job.id)` (AppState.swift:333–337, already tested) |
| RESIL-01 | Failed filing surfaces a recoverable error — spoken + persistent dismissable job row with message + originating transcript | Code Examples → failed-row using exposed `AppState.message(for:)` (line 412) + transcript snippet mechanism; `dismiss(jobID:)`/`clearFinished()` design |
</phase_requirements>

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Render **active + all terminal** jobs in one list — filing, done, failed, and cancelled rows together. Matches JOBS-01's literal "each with its state (filing/done/failed/cancelled)" wording and is the simplest render (a single `ForEach` over `jobs[]`).
- **D-02:** **All terminal rows persist until the user dismisses them** — done, failed, and cancelled alike. One rule for everything, no auto-clear timers/animations. Consistent with Phase 5 D-06/D-07 (terminal jobs retained in session memory).
- **D-03:** **Newest on top.** The list scrolls inside a **fixed max-height** area (reuse the `TranscriptCard` `ScrollView { … }.frame(maxHeight:)` pattern) so recent activity stays visible and the popover never grows unbounded.
- **D-04:** **Per-row ✕ on terminal rows** (done/failed/cancelled) **plus a bulk "Clear all/finished"** control. Because everything persists (D-02), a bulk clear is needed so cleanup isn't one-click-per-row in a busy session.
- **D-05:** **Clear-all removes ONLY terminal rows.** It never stops or removes in-flight jobs. Active (filing) rows have **Stop only — no ✕**. Stopping an active job routes through the existing cancel path → the row becomes `.cancelled` → then it is dismissable like any terminal row. No accidental loss of running work; no redundant Stop-vs-✕ on the same row.
- **D-06:** Requires **new `AppState` methods**: `dismiss(jobID:)` (remove one terminal job from `jobs[]`) and `clearFinished()` (remove all non-`.filing` jobs). These are pure array mutations — do **not** call `cancel`/`task.cancel()` (dismissal ≠ cancellation).
- **D-07:** **Dismiss-only — no in-app Retry.** "Recoverable" = the error is visible, the originating transcript is preserved, and the user can act (re-dictate; or fix auth/Docker/network then try again). An in-app Retry that re-files the transcript is **out of scope** per PROJECT.md ("Advanced failure recovery (retries, queuing, partial-state repair) — beyond v1").
- **D-08:** A failed row shows the **mapped `IssueFilingError` message** (e.g. "AI CLI timed out — check your internet connection") **+ a truncated transcript snippet** (1–2 lines); the full transcript stays reachable via text selection / expand. Compact rows, full text still recoverable.
- **D-09:** Requires **exposing the currently-private `AppState.message(for: IssueFilingError)`** (line ~412) to the view layer (make it accessible / lift into a shared place). The mapping already exists — do not re-author error strings.
- **D-10:** A done row shows **"Issue #N filed" where `#N` is clickable** and opens `result.url` in the browser via `NSWorkspace.shared.open(...)`. The data already exists on the job (`FilingJob.result` → `IssueFilingResult { number, url }`); this turns the popover into a quick jump-to-issue surface at near-zero cost.
- **D-11:** Add a **new "Filing Jobs" section at the bottom of the popover, after the `TranscriptCard`.** Keeps the familiar capture flow (header → repo → action → transcript) on top; jobs accumulate below. The existing "last transcript" `TranscriptCard` stays (not replaced).
- **D-12:** The section is **hidden entirely when `jobs[]` is empty** (including its Clear-all control). When present, a small header — `FILING JOBS (N)` with the Clear-all control beside it — sits above the rows, matching the existing card-header style (cf. `TranscriptCard`'s "Transcript" + CopyButton header).

### Claude's Discretion

- The exact row component design/visual style (spacing, per-state color/icon), the activity-indicator choice for `.filing` rows (the codebase already has `ActivitySpinner` and `WaveformView` to draw from), and the cancelled-row wording/styling.
- Where `dismiss(jobID:)` / `clearFinished()` and the exposed message mapper physically live, and how the row view reads them.
- How the transcript snippet is truncated/expanded (lineLimit + selection vs. disclosure) — D-08 fixes intent (snippet with full text reachable), not the mechanism.
- Whether the failed/error row reuses `StatusBanner`'s amber/warning treatment or gets its own row styling.

### Deferred Ideas (OUT OF SCOPE)

- **In-app Retry / re-file the same transcript** — out of scope for v1.1 (PROJECT.md: no retries/queuing/partial-state repair). If back-to-back failures prove painful in practice, revisit as its own phase.
- **Cross-launch job history persistence** — explicitly out of scope (Phase 5 D-07); jobs live in session memory only.
- **Copy-transcript / copy-URL buttons on rows** — considered as middle-ground options but not chosen (clickable `#N` covers the success case; selection covers transcript). Trivial to add later if wanted.
- **In-flight "Filing issue…" progress detail beyond the activity indicator** — the Phase 6 UAT follow-up ("add an in-flight 'Filing issue…' indicator") is partially served by the `.filing` row + spinner; richer per-stage progress (investigating vs. filing) is not in this phase's scope.
</user_constraints>

## Project Constraints (from CLAUDE.md / AGENTS.md)

- **Global (`~/.claude/CLAUDE.md`):** Simplicity first (minimum code, no speculative abstractions), surgical changes only (touch only what's needed, don't refactor adjacent code), goal-driven execution with explicit verification. Directly applicable here: `JobsSection`/`JobRow` should be added, not the existing card components restyled; `dismiss`/`clearFinished` should be pure array mutations with no speculative generality (no generic "job filter" abstraction).
- **Project (`./CLAUDE.md`):** Skill routing only — `spike-findings-make-an-issue` is the implementation blueprint (already loaded; see below). No additional directives.
- **`AGENTS.md`** (this project's configured instructions file, GSD-generated): confirms the stack (Swift/SwiftUI, non-sandboxed, `Process`-based CLI invocation) and the "happy-path only" v1 scope — no items that add new constraints for Phase 9 beyond what CONTEXT.md/REQUIREMENTS.md already state.
- **Spike findings (`spike-findings-make-an-issue`):** Non-negotiables are about the filing pipeline (scoped `--allowedTools`, issue number from `url` not `id`, no `bypassPermissions`) — none of the spike findings are load-bearing for Phase 9's UI work; the filing pipeline is unchanged by this phase.

## Architectural Responsibility Map

This is a single-process native macOS app, not a multi-tier web app — the standard
Browser/SSR/API/CDN/DB tiers don't apply. The equivalent tiers for this codebase are:

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Render job list, per-row state/icon, Stop/✕ buttons | **View (SwiftUI, `MenuView.swift`)** | — | Pure presentation over `@Published var jobs`; no business logic belongs here |
| Job state transitions (filing→done/failed/cancelled) | **State (`@MainActor AppState`)** | — | Already fully built (Phase 5/6); Phase 9 does not touch `spawnFilingJob`/the catch arms |
| Cancel a specific job (Stop button target) | **State (`AppState.cancel(jobID:)`)** | View (button wiring only) | Already built and unit-tested (`testCancelJobIdTransitionsToCancel`); View only supplies the `jobID` |
| Remove a terminal job from the list (✕ / Clear-all) | **State (new `AppState.dismiss`/`clearFinished`)** | View (button wiring only) | D-06: pure `jobs[]` mutation, must stay on `@MainActor AppState`, never mutate `jobs` from the View |
| Error-message text for a failed job | **State (`AppState.message(for: IssueFilingError)`)** | View (renders the returned string) | D-09: the mapping is domain logic (which message per error case), not presentation — stays a static function on `AppState`, just made accessible |
| Opening the filed issue URL | **View → OS (`NSWorkspace.shared.open`)** | State (data source: `job.result.url`) | AppKit/OS integration call; must scheme-validate before calling (see Security Domain) |

## Standard Stack

No new external dependencies. This phase is 100% SwiftUI + AppKit (`NSWorkspace`) using only
framework APIs already imported in `MenuView.swift` (`AppKit`, `SwiftUI`) and `AppState.swift`
(`Darwin` for existing `kill(-pgid, …)`, untouched by this phase).

### Core (existing, reused — no installation needed)

| Component | Location | Purpose | Why reuse it |
|-----------|----------|---------|---------------|
| `TranscriptCard` scroll pattern | MenuView.swift:422–455 | `ScrollView { … }.frame(maxHeight: 100)` + card chrome | D-03 explicitly calls for reusing this exact pattern for the jobs list |
| `ActivitySpinner` | MenuView.swift:309–328 | Circular indeterminate spinner, parameterized by `color` | `.filing` row activity indicator (JOBS-01) — already used for `.transcribing` in `ActionCard` |
| `WaveformView` | MenuView.swift:283–307 | 7-bar animated waveform | Semantically tied to **live audio recording**, not "AI CLI is investigating/filing" — do not reuse for job rows (see Pitfalls) |
| `StatusBanner` / `Color.amberStyle` | MenuView.swift:389–420, 416–420 | Amber warning treatment | Candidate for failed-row styling (Claude's Discretion) — recommend a **compact variant**, not the full-width banner (see Architecture Patterns) |
| `CopyButton` | MenuView.swift:457–488 | Small pill button, `.buttonStyle(.plain)`, state-toggling label | Direct styling reference for Stop / ✕ / Clear-all row-level buttons |
| `FilingJob` / `FilingJobState` | FilingJob.swift:1–39 | `Identifiable` struct, 4-case state enum | The `ForEach` data source (already `Identifiable`, no changes needed) |
| `AppState.cancel(jobID:)` | AppState.swift:333–337 | Cancels one `.filing` job by id | JOBS-02 Stop target — already `.filing`-guarded, already unit-tested |
| `AppState.message(for: IssueFilingError)` | AppState.swift:412–425 | Error → user message string | RESIL-01 failed-row text — **currently dead code, must be exposed (D-09)** |
| `IssueFilingResult` | IssueResultParser.swift:3–10 | `{ number: Int, url: String }` | D-10 done-row `#N` + `NSWorkspace.shared.open(url)` target |

### Supporting

None — no new libraries, no new SPM package entries in `Package.swift` are needed for this phase.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `ActivitySpinner` for `.filing` rows | `WaveformView` | Wrong metaphor (waveform = live mic input, not background CLI activity); would also be visually confusing next to the recording state's own `WaveformView` in `ActionCard` |
| Reusing full `StatusBanner` for failed rows | A compact per-row amber treatment (smaller padding/font, no full popover width) | Full `StatusBanner` is designed as a single top-level, full-bleed notice; using it per-row inside a scrolling list would be visually heavy at N failed rows — recommend a scaled-down variant that borrows only the color/icon, not the component |
| `lineLimit` + `.textSelection(.enabled)` for D-08's "reachable via selection" | Tap-to-expand `@State` toggle swapping `lineLimit(2)` ↔ `lineLimit(nil)` | Unverified whether `.textSelection(.enabled)` on a truncated `Text` exposes hidden/overflow characters to selection at all (no confirming source found — see Assumptions Log); disclosure toggle is unambiguous and trivially testable by eye during UAT |

**Installation:** None — no packages to install for this phase.

**Version verification:** Not applicable — no new packages. `Package.swift` dependency
(`KeyboardShortcuts` from `3.0.1`) is untouched by this phase.

## Package Legitimacy Audit

**Not applicable.** This phase installs zero external packages — it is pure SwiftUI/AppKit code
using only framework APIs already present in the target. `Package.swift` requires no changes.

**Packages removed due to [SLOP] verdict:** none (n/a — no packages evaluated)
**Packages flagged as suspicious [SUS]:** none (n/a — no packages evaluated)

## Architecture Patterns

### System Architecture Diagram

```
┌─────────────────────────────── MenuView (SwiftUI, popover) ───────────────────────────────┐
│                                                                                              │
│  Header / RepositoryCard / ActionCard / StatusBanner / TranscriptCard   (existing, D-11)   │
│                                                                                              │
│  ┌─────────────────────── JobsSection (NEW, D-11/D-12) ─────────────────────────────────┐  │
│  │  gated: if !appState.jobs.isEmpty { … }                                              │  │
│  │                                                                                        │  │
│  │  Header: "FILING JOBS (N)"  ──────────────────────────  [Clear all]  (D-04, D-12)     │  │
│  │                                                              │                         │  │
│  │  ScrollView { VStack {                                       │ clearFinished()         │  │
│  │    ForEach(appState.jobs.reversed()) { job in   ← D-03 newest-first                    │  │
│  │      JobRow(job: job, appState: appState)  (NEW)                                       │  │
│  │        ├─ .filing    → ActivitySpinner + "Filing…" + [Stop]───┐  cancel(jobID:)        │  │
│  │        ├─ .done      → checkmark + "Issue #N filed" (tap)─────┼─────────────┐          │  │
│  │        │                                          + [✕]───────┤ dismiss(jobID:)         │  │
│  │        ├─ .failed    → amber icon + message(for:) + snippet   │              │          │  │
│  │        │                                          + [✕]───────┤              │          │  │
│  │        └─ .cancelled → secondary icon + "Filing cancelled"    │              │          │  │
│  │                                                    + [✕]───────┘              │          │  │
│  │    }                                                                          │          │  │
│  │  }}.frame(maxHeight: …)   ← D-03 fixed scroll area                           │          │  │
│  └────────────────────────────────────────────────────────────────────────────┼──────────┘  │
└───────────────────────────────────────────────────────────────────────────────┼─────────────┘
                                                                                   │
                              ┌────────────────────────────────────────────────────────────────┐
                              │        AppState (@MainActor, ObservableObject) — EXISTING       │
                              │  @Published var jobs: [FilingJob]                               │
                              │  cancel(jobID:)         ← Phase 6, unit-tested, unchanged        │
                              │  dismiss(jobID:)        ← NEW (D-06): jobs.removeAll(where:)     │
                              │  clearFinished()        ← NEW (D-06): jobs.removeAll(where:)     │
                              │  message(for: IssueFilingError) ← expose (drop `private`, D-09)  │
                              └────────────────────────────────────────────────────────────────┘
                                                                                   │
                              done-row tap  ──────────────────────────────────────┘
                                       │
                                       ▼
                     NSWorkspace.shared.open(URL) — validate scheme == "https" first (D-10, security)
```

### Recommended Project Structure

No new files needed — the project keeps all views in one file (`MenuView.swift`, currently 490
lines) as a composition of small `struct … : View` subviews. Following that established
convention (surgical, no new module boundary):

```
Sources/MakeAnIssue/
├── MenuView.swift      # append: JobsSection, JobRow (+ small per-state helpers), after TranscriptCard
├── AppState.swift       # append: dismiss(jobID:), clearFinished(); edit: drop `private` on message(for: IssueFilingError)
├── FilingJob.swift      # unchanged — already Identifiable, already has all needed fields
└── IssueResultParser.swift # unchanged — IssueFilingResult already has number/url
```

### Pattern 1: Reuse the TranscriptCard scroll shell for the jobs list (D-03, D-12)

**What:** A card with a bold small-caps header row (label + trailing control) above a
`ScrollView` capped with `.frame(maxHeight:)`.
**When to use:** Any bounded-height, growing list inside the fixed-width (320pt) popover.
**Example:**
```swift
// Source: MenuView.swift:422-455 (existing TranscriptCard, direct structural model)
struct JobsSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if !appState.jobs.isEmpty {   // D-12: hidden entirely when empty
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("FILING JOBS (\(appState.jobs.count))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if appState.jobs.contains(where: { $0.state != .filing }) {
                        ClearAllButton(appState: appState)   // D-04/D-05: terminal-only
                    }
                }
                ScrollView {
                    VStack(spacing: 6) {
                        // D-03: newest first — jobs are appended in spawn order.
                        ForEach(appState.jobs.reversed()) { job in
                            JobRow(job: job, appState: appState)
                        }
                    }
                }
                .frame(maxHeight: 180)   // discretion: tuned to ~2-3 rows before scroll
            }
            .padding(10)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}
```
Insert as the last item in `MenuView.body`'s `VStack`, immediately after the existing
`TranscriptCard` block (D-11) — no `EmptyView()` needed since the `if` at the top of the struct's
own `body` already collapses to nothing when `jobs.isEmpty`.

### Pattern 2: Per-state row styling as a pure, testable mapping (JOBS-01)

**What:** Extract icon/label/color per `FilingJobState` as a static/pure function rather than
inline `switch` in the view body.
**When to use:** Always, in this codebase specifically — because there is no ViewInspector/
snapshot test dependency (see `Package.swift`), a pure mapping function is the *only* part of
`JobRow`'s state-dependent styling that can be unit tested. Everything left inline in `body` is
untestable without a human looking at the popover.
**Example:**
```swift
// New — no existing precedent in this codebase for a per-state style mapper, but StateBadge
// (MenuView.swift:81-109) already uses the identical `switch state { case … return … }` shape
// for label/color, just inline. Lifting it to a standalone type/function makes it testable.
enum JobRowStyle {
    static func iconName(for state: FilingJobState) -> String {
        switch state {
        case .filing:    return "arrow.triangle.2.circlepath"  // paired with ActivitySpinner overlay, or omit if spinner alone suffices
        case .done:      return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
    static func tintColor(for state: FilingJobState) -> Color {
        switch state {
        case .filing:    return .blue     // distinct from StateBadge's .orange (=.transcribing)
        case .done:      return .green
        case .failed:    return .amberStyle   // reuse existing Color.amberStyle (MenuView.swift:416-419)
        case .cancelled: return .secondary
        }
    }
}
```
This mirrors `StateBadge`'s existing `label`/`backgroundColor` computed-property idiom
(MenuView.swift:94–108) closely enough to match house style, while being a `static func` so
`XCTAssertEqual(JobRowStyle.tintColor(for: .failed), .amberStyle)` is a real, fast unit test.

### Pattern 3: Failed-row error text via the exposed mapper (D-08, D-09, RESIL-01)

**What:** `JobRow` calls `AppState.message(for: job.error!)` for `.failed` rows — never
re-authors error strings in the view.
**Example:**
```swift
// AppState.swift:412 — change from `private static` to (default) `internal static`.
// Before: private static func message(for error: IssueFilingError) -> String { ... }
// After:           static func message(for error: IssueFilingError) -> String { ... }
// No other change needed — MenuView.swift is in the same target (Sources/MakeAnIssue),
// so default (internal) access is visible; `public` is not required and would be a wider
// surface than needed (CLAUDE.md: minimum code, no speculative access widening).

// JobRow usage:
if job.state == .failed, let error = job.error {
    Text(AppState.message(for: error))
        .font(.system(size: 11))
        .foregroundColor(.primary.opacity(0.85))
}
```

### Pattern 4: Tap-to-expand transcript snippet (D-08 mechanism choice)

**What:** A `@State private var isExpanded = false` toggle swapping `lineLimit(2)` for
`lineLimit(nil)`, combined with `.textSelection(.enabled)` only once expanded.
**When to use:** Any row (failed rows per D-08; could extend to done/cancelled if useful) that
needs to show a possibly-long transcript compactly with a guaranteed path to the full text.
**Example:**
```swift
// New pattern — no existing disclosure/expand precedent in MenuView.swift to reuse, but
// mirrors CopyButton's @State-driven micro-interaction shape (MenuView.swift:457-488).
struct TranscriptSnippet: View {
    let transcript: String
    @State private var isExpanded = false

    var body: some View {
        Text(transcript)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(isExpanded ? nil : 2)
            .textSelection(.enabled)   // safe once expanded — no hidden-text selection question
            .onTapGesture { withAnimation { isExpanded.toggle() } }
    }
}
```
Recommend this over bare `lineLimit(2)` + `.textSelection(.enabled)` because whether SwiftUI's
text-selection reaches truncated/hidden glyphs is **not confirmed** by any source found in this
research pass (see Assumptions Log A1) — the disclosure toggle sidesteps the question entirely by
only relying on selection once the full string is actually rendered.

### Pattern 5: `dismiss`/`clearFinished` as pure array mutations (D-06)

**What:** New `AppState` methods that only mutate `jobs[]` — never touch `.task`/cancellation.
**Example:**
```swift
// AppState.swift — insert after forceKillAllProcessTrees() (line ~355), grouping all
// jobs-lifecycle mutation methods together (spawnFilingJob → cancel → cancelAll →
// forceKillAllProcessTrees → dismiss → clearFinished).

/// Remove a single terminal job from `jobs[]`. No-op for `.filing` jobs — dismissal is never
/// cancellation; call `cancel(jobID:)` first to stop an active job (D-05/D-06).
func dismiss(jobID: UUID) {
    jobs.removeAll { $0.id == jobID && $0.state != .filing }
}

/// Remove every non-`.filing` (terminal) job from `jobs[]`. Active jobs are untouched (D-05/D-06).
func clearFinished() {
    jobs.removeAll { $0.state != .filing }
}
```
Both are single-expression, main-actor-isolated (class is `@MainActor`), and directly mirror the
doc-comment convention already used for `cancel`/`cancelAll` (AppState.swift:329–344).

### Anti-Patterns to Avoid

- **Mutating `appState.jobs` directly from `JobRow`/`JobsSection`:** All mutation must go through
  `AppState` methods (`cancel`, `dismiss`, `clearFinished`), per the Established Patterns section
  of CONTEXT.md and the existing codebase convention (every `jobs[idx].state = …` write lives
  inside `AppState`, never in `MenuView.swift`).
- **A ✕ button on `.filing` rows, or a Stop button on terminal rows:** D-05 explicitly forbids
  blurring these — active rows get Stop only, terminal rows get ✕ only.
- **Reusing `WaveformView` for the `.filing` indicator:** wrong semantic (live audio vs.
  background subprocess activity); also visually redundant with `ActionCard`'s own `WaveformView`
  during `.recording`.
- **Re-deriving error message strings in the view** instead of calling the exposed
  `AppState.message(for:)` — D-09 is explicit that the mapping must not be re-authored.
- **Adding a Retry button:** explicitly deferred (D-07); a Retry affordance would silently expand
  RESIL-01's scope into JOBS-03 territory (Future Requirements).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Process-group cancellation | A new cancel/kill path for the Stop button | `AppState.cancel(jobID:)` (AppState.swift:333–337) | Already handles the `.filing`-guard and defers the `.cancelled` transition to the `CancellationError` catch arm — re-implementing any part of this in the view risks a race with the real cancellation flow (Phase 6 threat model, `06-SECURITY.md`) |
| Error → user-message mapping | A new `switch job.error { … }` in the view | `AppState.message(for: IssueFilingError)` (line 412, expose per D-09) | Mapping already exists, already covers all 5 `IssueFilingError` cases; duplicating it in the view creates two sources of truth that can drift |
| Bounded scrolling list chrome | A new `ScrollView`/height-clamp pattern | `TranscriptCard`'s existing `ScrollView { }.frame(maxHeight:)` shell (MenuView.swift:435–445) | D-03 explicitly calls for reuse; a second bespoke scroll pattern in the same file is unnecessary surface area |

**Key insight:** Every piece of "hard" logic this phase might be tempted to build (cancellation,
error messages, scroll chrome) already exists in this codebase from Phases 5, 6, and the
`TranscriptCard`. The actual net-new logic in Phase 9 is small: two pure array mutations
(`dismiss`, `clearFinished`) and view composition.

## Common Pitfalls

### Pitfall 1: Assuming `.textSelection(.enabled)` reaches text hidden by `lineLimit`

**What goes wrong:** Implementing D-08 as `Text(transcript).lineLimit(2).textSelection(.enabled)`
and assuming the user can select-all to copy the full transcript, when in fact selection may only
be able to reach the visibly-rendered (truncated) glyphs.
**Why it happens:** `.textSelection(.enabled)` is commonly assumed to operate on the underlying
string value rather than the rendered/visible content; this assumption is unverified for
truncated `Text` in this research pass (no confirming source found — see Assumptions Log A1).
**How to avoid:** Use the tap-to-expand `@State` toggle (Pattern 4) so the full string is always
literally rendered (and thus selectable) once expanded — never rely on selection reaching hidden
truncated content.
**Warning signs:** During UAT, select-all on a truncated failed-row snippet and paste elsewhere;
if the pasted text is shorter than the original transcript, the mechanism is wrong.

### Pitfall 2: Forgetting `.filing` jobs are excluded from Clear-all / dismiss

**What goes wrong:** `clearFinished()` implemented as `jobs.removeAll()` (removes everything,
including in-flight jobs) instead of `jobs.removeAll { $0.state != .filing }`.
**Why it happens:** "Clear all" reads like "clear the whole list" at a glance; D-05's
terminal-only scoping is easy to miss if not re-read carefully.
**How to avoid:** Name the check explicitly (`$0.state != .filing`, not a negated "is terminal"
helper that could silently include `.filing` if the enum grows a 5th case later); add a unit test
asserting an in-flight job survives `clearFinished()` (see Validation Architecture).
**Warning signs:** A job disappears from the list mid-filing after the user clicks Clear-all —
this would silently orphan a running subprocess from the UI's perspective (though the process
itself keeps running since `clearFinished()` must never call `.cancel()`).

### Pitfall 3: Iterating `jobs.reversed()` vs. sorting by a separate timestamp

**What goes wrong:** Adding a `createdAt: Date` field to `FilingJob` "to sort properly," when
`jobs` is already append-ordered (oldest first, from `spawnFilingJob`'s `jobs.append(...)`
AppState.swift:279) and `.reversed()` is sufficient and free.
**Why it happens:** Over-engineering impulse — a timestamp *feels* more robust than array order.
**How to avoid:** `jobs.reversed()` in the `ForEach` is correct and matches CLAUDE.md's
"simplicity first" (no speculative fields). `FilingJob` gains no new stored properties in this
phase.
**Warning signs:** A PR diff that touches `FilingJob.swift` to add a date field — should not
happen for this phase; flag in review if it does.

### Pitfall 4: Opening `result.url` without scheme validation

**What goes wrong:** `NSWorkspace.shared.open(URL(string: job.result!.url)!)` called directly on
a string that ultimately originated from AI-CLI-controlled subprocess output (parsed by
`IssueResultParser` via regex from `stdout`), without verifying the scheme is `https`.
**Why it happens:** The URL "feels" trusted because it came from GitHub's own MCP tool result —
but the string is still parsed via regex from CLI stdout the app doesn't fully control end-to-end
(the AI CLI's tool output), so scheme validation is cheap, defense-in-depth insurance.
**How to avoid:** See Security Domain — validate `URL.scheme == "https"` before calling
`NSWorkspace.shared.open`.
**Warning signs:** `IssueResultParser`'s regex (`structuredURLRegex`/`proseURLRegex`,
IssueResultParser.swift:39–54) already anchors on `https?://github\.com/...`, so in practice this
is a low-probability path — but the *opening* call site should not silently trust that upstream
anchor as its only defense.

## Code Examples

### JOBS-02 Stop button (AppState.swift:333–337, unchanged — view wiring only)

```swift
// Existing target — do not modify. JobRow's Stop button calls this directly:
Button("Stop") {
    appState.cancel(jobID: job.id)
}
```

### RESIL-01 failed row composition

```swift
// New — JobRow's .failed branch, combining Pattern 2/3/4.
case .failed:
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Image(systemName: JobRowStyle.iconName(for: .failed))
                .foregroundColor(JobRowStyle.tintColor(for: .failed))
            Text(job.error.map(AppState.message(for:)) ?? "Issue filing failed")
                .font(.system(size: 11))
            Spacer()
            DismissButton(appState: appState, jobID: job.id)   // D-04: ✕ on terminal rows
        }
        TranscriptSnippet(transcript: job.transcript)   // D-08
    }
```

### JOBS-01 activity indicator for `.filing` rows

```swift
// Reuses ActivitySpinner exactly as ActionCard already does for .transcribing
// (MenuView.swift:224), just at row scale.
case .filing:
    HStack(spacing: 8) {
        ActivitySpinner(color: .blue)
        Text("Filing…")
            .font(.system(size: 11))
        Spacer()
        Button("Stop") { appState.cancel(jobID: job.id) }
    }
```

## State of the Art

Not applicable — this is a small, internal, greenfield UI addition on a stable SwiftUI/AppKit
codebase; there is no "old approach → current approach" migration in play. `ActivitySpinner`/
`WaveformView`/`StatusBanner`/`TranscriptCard`/`CopyButton` are all current-generation (built in
this same project, Phases 1–8) and remain the correct patterns to extend.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `.textSelection(.enabled)` on a `lineLimit`-truncated `Text` may not expose hidden/overflow characters to selection (no confirming source found this pass) | Standard Stack (Alternatives Considered), Pattern 4, Pitfall 1 | Low — the recommendation (tap-to-expand disclosure) sidesteps the question entirely regardless of the true answer, so this assumption does not gate a decision the planner must confirm; flagging only so the planner doesn't independently choose the riskier lineLimit+selection route without knowing why it was avoided here |
| A2 | Validating `URL.scheme == "https"` before `NSWorkspace.shared.open` is "best practice" per community sources (ghostty issue #5256, feedback-assistant #292), not an Apple-authored security guide | Security Domain | Low-Medium — even if this exact guidance isn't Apple-canonical, scheme-restricting an externally-parsed URL before opening it is a conservative, low-cost mitigation; worst case it's unnecessary defense-in-depth, not a wrong recommendation |

**If this table is empty:** N/A — two low-risk assumptions logged above; neither blocks planning.

## Open Questions (RESOLVED)

Both questions below are non-blocking and carry a recommendation adopted by the plans; neither gates planning or execution.

1. **Exact `.frame(maxHeight:)` value for the jobs `ScrollView`** — RESOLVED: start at `180` as a UAT-tunable constant (adopted in Plan 09-02 Task 2); not a locked decision.
   - What we know: `TranscriptCard` uses `maxHeight: 100` for single-block transcript text; job
     rows are shorter/denser (one line + optional snippet) so more rows fit per point of height.
   - What's unclear: The ideal value depends on how tall a single `JobRow` renders once built —
     not knowable without building it.
   - Recommendation: Start around `160–200`, treat as a UAT-tunable constant, not a locked
     decision — CONTEXT.md leaves exact spacing/sizing to discretion.

2. **Whether `.filing` rows need an icon at all, or the `ActivitySpinner` alone suffices as JOBS-01's "activity indicator"** — RESOLVED: spinner-only for `.filing` (adopted in Plan 09-02 Task 1); satisfies JOBS-01 literally and is the minimum code.
   - What we know: JOBS-01 requires "an activity indicator" — `ActivitySpinner` alone satisfies
     the literal requirement.
   - What's unclear: Whether a static SF Symbol icon should also appear alongside the spinner for
     visual consistency with the other 3 states (done/failed/cancelled, which do have icons).
   - Recommendation: Spinner-only for `.filing` is sufficient and simpler (CLAUDE.md: minimum
     code) — the planner can decide either way without re-researching; not a blocking gap.

## Environment Availability

Skipped — this phase has no new external tool/service/runtime dependencies. It uses only
framework APIs (`SwiftUI`, `AppKit`) already present and already used by `MenuView.swift` and
`AppState.swift` in this same target. `swift build`/`swift test` availability was already
established by every prior phase in this project.

## Validation Architecture

Nyquist validation is ENABLED (`config.json` `workflow.nyquist_validation: true`).

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (existing; `Tests/MakeAnIssueTests/`) |
| Config file | `Package.swift` (existing test target `MakeAnIssueTests`) |
| Quick run command | `swift test --filter MakeAnIssueTests 2>&1` |
| Full suite command | `swift test 2>&1` |

**Constraint carried into every test:** no ViewInspector or SnapshotTesting dependency exists in
`Package.swift` (verified — only `KeyboardShortcuts` is a package dependency). Rendered-view
assertions (row layout, actual on-screen icon, actual button hit target) are **not automatable**
in this project as-is; every prior phase (5–8) verifies SwiftUI-adjacent behavior by asserting on
`AppState`'s `@Published` properties instead, and this phase should follow the same convention.
Adding a snapshot-testing dependency to close this gap is out of scope for a UI-only phase (would
itself need a Package Legitimacy Audit and is disproportionate to the phase size — CLAUDE.md
simplicity bias).

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JOBS-01 | `.filing`/`.done`/`.failed`/`.cancelled` states map to distinct icon/color via `JobRowStyle` (Pattern 2) | unit | `swift test --filter FilingJobTests` (new test method, e.g. `testJobRowStyleIconAndColorPerState`) | ❌ Wave 0 — new pure-function test, no rendering needed |
| JOBS-01 | Job list rendering, activity indicator visible on screen | manual-only | — (no ViewInspector/snapshot infra; see constraint above) | N/A — justified: rendering assertions are not automatable in this project |
| JOBS-02 | Stop button calls `cancel(jobID:)` for the correct job, leaves others untouched | unit (already covered) | `swift test --filter AppStateTests/testCancelJobIdTransitionsToCancel` | ✅ existing (AppStateTests.swift:1185) |
| JOBS-02 | Stop button visually present only on `.filing` rows, absent on terminal rows (D-05) | manual-only | — | N/A — justified: view composition, no rendering infra |
| RESIL-01 | `dismiss(jobID:)` removes exactly one terminal job, no-ops for a `.filing` job | unit | `swift test --filter AppStateTests` (new: `testDismissJobRemovesTerminalJob`, `testDismissJobIsNoOpForFilingJob`) | ❌ Wave 0 |
| RESIL-01 | `clearFinished()` removes all non-`.filing` jobs, leaves `.filing` jobs untouched | unit | `swift test --filter AppStateTests` (new: `testClearFinishedRemovesAllTerminalJobs`, `testClearFinishedPreservesFilingJobs`) | ❌ Wave 0 |
| RESIL-01 | `AppState.message(for: IssueFilingError)` is reachable (non-private) and returns the correct string per case | unit | `swift test --filter AppStateTests` (new: `testMessageForIssueFilingErrorCases`, one assertion per of the 5 cases) | ❌ Wave 0 — currently untestable since `private`; zero existing tests reference these message strings (verified via grep) |
| RESIL-01 | Spoken failure + persistent row both fire on a real failed filing (end-to-end) | integration (already covered for the state side) | `swift test --filter AppStateTests/testFailedFilingJobRetainedInJobsArray` + `testFailedFilingJobSpeaksGenericFailure` | ✅ existing (AppStateTests.swift:908, 1048) — Phase 9 adds the *rendering* of this already-tested state, which is manual-only |
| RESIL-01 | Transcript snippet expand/collapse toggles correctly, full text visible when expanded | manual-only | — | N/A — justified: `@State` toggle behavior on a rendered view |

### Sampling Rate

- **Per task commit:** `swift test --filter AppStateTests 2>&1` (fastest feedback for the new
  `dismiss`/`clearFinished`/`message` unit tests)
- **Per wave merge:** `swift test 2>&1` (full suite)
- **Phase gate:** Full suite green before `/gsd-verify-work`, plus manual UAT pass covering the
  manual-only rows above (job list appears with correct per-state styling, Stop/✕/Clear-all
  buttons behave per D-04/D-05, transcript snippet expands, done-row `#N` opens the browser)

### Wave 0 Gaps

- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — add `testDismissJobRemovesTerminalJob`,
      `testDismissJobIsNoOpForFilingJob`, `testClearFinishedRemovesAllTerminalJobs`,
      `testClearFinishedPreservesFilingJobs`, `testMessageForIssueFilingErrorCases` (covers
      RESIL-01's new `AppState` surface)
- [ ] `Tests/MakeAnIssueTests/FilingJobTests.swift` (or a new small test file) — add
      `testJobRowStyleIconAndColorPerState` once `JobRowStyle` (Pattern 2) exists, covering JOBS-01's
      state→style mapping as a pure function
- [ ] Framework install: none — XCTest is already configured; no new test target changes needed
      in `Package.swift`

## Security Domain

`security_enforcement: true`, `security_asvs_level: 1`, `security_block_on: "high"`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Phase 9 adds no auth surface |
| V3 Session Management | No | Phase 9 adds no session handling |
| V4 Access Control | No | The popover is already gated by the existing left-click surface (Phase 7); no new privilege boundary is introduced |
| V5 Input Validation | **Yes** | The done-row URL (`job.result.url`) and the failed-row message/transcript are all rendered as `Text` (SwiftUI auto-escapes; no `Text(markdown:)`/HTML interpolation used) — no injection surface. The one real input-validation point is the URL handed to `NSWorkspace.shared.open`: validate `URL(string: job.result.url)?.scheme == "https"` before opening (see Known Threat Patterns) |
| V6 Cryptography | No | No crypto in this phase |

### Known Threat Patterns for this Phase

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| `NSWorkspace.shared.open(result.url)` opening a URL whose string ultimately traces back to AI-CLI subprocess stdout, parsed by regex (`IssueResultParser`) | Tampering / Spoofing (unintended handler app opened via a manipulated scheme) | Validate `URL.scheme == "https"` (case-insensitive) before calling `NSWorkspace.shared.open`; reject/no-op otherwise. `IssueResultParser`'s regexes already anchor on `https?://github\.com/...` (IssueResultParser.swift:43, 52) as a first layer, but the open call site should not rely solely on that upstream anchor holding forever — cheap, local defense-in-depth [CITED: community guidance synthesized from github.com/ghostty-org/ghostty/issues/5256, github.com/feedback-assistant/reports/issues/292 — LOW confidence, no single authoritative Apple source found this pass, see Assumptions Log A2] |
| Rendering `job.error`-derived message text and `job.transcript` in `Text` views | Information Disclosure (low severity) | Both strings are already local, user-generated (transcript) or from a closed, typed enum (`IssueFilingError` cases → fixed strings in `message(for:)`) — no untrusted remote content is rendered. `Text` does not interpret HTML/script; no additional mitigation needed beyond what already exists |
| `dismiss(jobID:)` / `clearFinished()` as new state-mutating entry points reachable from the UI | Tampering (unintended data loss) | Both are scoped to terminal jobs only (`state != .filing`), enforced in the method body itself (Pattern 5) — a `.filing` job can never be silently dropped from the list via these calls, so no in-flight work becomes invisible to the user without an explicit Stop first |

**Net security impact:** Minimal, and narrower than Phase 7's already-minimal footprint. The one
concrete, actionable item for the planner is the `https`-scheme check before
`NSWorkspace.shared.open` (V5 Input Validation) — recommend the plan-checker/verifier confirm this
guard is present at the call site, since it's the only genuinely new I/O-adjacent surface this
phase introduces.

## Sources

### Primary (HIGH confidence)

- `Sources/MakeAnIssue/MenuView.swift` (this repo) — full file read, all line numbers in this
  document verified directly against source, not from CONTEXT.md's citations alone
- `Sources/MakeAnIssue/AppState.swift` (this repo) — full file read; confirmed via `grep -n
  "message(for"` that `message(for: IssueFilingError)` (line 412) has zero call sites
- `Sources/MakeAnIssue/FilingJob.swift`, `IssueResultParser.swift`, `IssueFilingConfig.swift` (this repo) — full files read
- `Tests/MakeAnIssueTests/AppStateTests.swift`, `FilingJobTests.swift` (this repo) — grepped for
  existing `jobs`/`cancel`/`message(for` coverage to establish the Wave 0 gap list precisely
- `Package.swift` (this repo) — confirmed zero test-time dependencies beyond `KeyboardShortcuts`
  (no ViewInspector/SnapshotTesting)
- `.planning/phases/09-.../09-CONTEXT.md`, `.planning/REQUIREMENTS.md`, `.planning/STATE.md` — this milestone's locked decisions and requirement text
- `.planning/phases/07-.../07-RESEARCH.md` — Validation Architecture / Security Domain section format precedent (test commands, ASVS table shape)
- `.planning/phases/06-.../06-SECURITY.md` — confirms the `cancel(jobID:)`/process-group cancellation path is already threat-modeled and closed; Phase 9 must not duplicate it

### Secondary (MEDIUM confidence)

- None this pass — both WebSearch queries returned LOW-confidence (single-source, non-cross-checked) results per `classify-confidence`.

### Tertiary (LOW confidence)

- WebSearch: "SwiftUI Text lineLimit truncation textSelection enabled…" — no source directly
  confirmed or denied whether truncated+selectable `Text` exposes hidden content; logged as
  Assumption A1, sidestepped via the disclosure-toggle recommendation rather than relied upon
- WebSearch: "NSWorkspace.shared.open URL security macOS app untrusted URL scheme" — community
  sources (GitHub issues, Apple dev forums), not an Apple-authored secure-coding guide; logged as
  Assumption A2, recommendation is directionally conservative regardless

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every recommended component is existing, working code in this repo,
  verified by direct file read (not from training-data memory of "typical SwiftUI patterns")
- Architecture: HIGH — the `JobsSection`/`JobRow` composition directly extends the file's own
  established `struct … : View` composition convention; no new architectural pattern introduced
- Pitfalls: MEDIUM — 3 of 4 pitfalls are grounded in this repo's actual code/decisions (D-05
  scoping, `.reversed()` vs. timestamp, URL scheme validation); Pitfall 1 (`textSelection`+
  `lineLimit`) is MEDIUM/LOW since the underlying SwiftUI behavior claim is unverified (see A1) —
  the *mitigation* recommended (disclosure toggle) is high-confidence regardless of the answer

**Research date:** 2026-07-01
**Valid until:** No expiry driver — this is internal-codebase research (file line numbers/APIs),
not third-party library research subject to version drift. Re-verify line numbers only if
`MenuView.swift`/`AppState.swift` are edited by another phase before Phase 9 executes.
