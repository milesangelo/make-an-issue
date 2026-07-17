# Phase 9: Jobs List UI + Per-Job Stop + Surfaced Errors - Context

**Gathered:** 2026-07-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Surface the **existing** `AppState.jobs` model (built in Phase 5, cancel wired in Phase 6) inside the left-click popover as a visible jobs list. Delivers JOBS-01, JOBS-02, RESIL-01:

- **JOBS-01:** A list of filing jobs, each showing its state (filing / done / failed / cancelled) with an activity indicator.
- **JOBS-02:** Each active (filing) job row has a **Stop** control that cancels that specific job (the UI surface over the already-built `cancel(jobID:)`).
- **RESIL-01:** A failed filing surfaces a **recoverable** error — spoken already exists (Phase 5 D-04), and now a **persistent job row** with the message + originating transcript that stays until the user dismisses it.

**This is almost entirely a UI phase.** The backend already exists: `@Published var jobs: [FilingJob]`, `cancel(jobID:)`, `cancelAll()`, `forceKillAllProcessTrees()`, and an `IssueFilingError` → user-message mapper. The **only** non-UI additions are a job-removal path (`dismiss(jobID:)` + `clearFinished()`) — none exists today — and exposing the currently-private message mapper to the view. The current `MenuView` renders **no jobs at all**.

**Out of scope (unchanged from PROJECT.md):** in-app retries / queuing / partial-state repair; cross-launch job persistence (session memory only, per Phase 5 D-07). "Recoverable" here means *visible + transcript-preserving + dismissable* — the user re-dictates or fixes the underlying cause and tries again manually; there is no Retry button.

</domain>

<decisions>
## Implementation Decisions

### Which Jobs Render & Lifecycle
- **D-01:** Render **active + all terminal** jobs in one list — filing, done, failed, and cancelled rows together. Matches JOBS-01's literal "each with its state (filing/done/failed/cancelled)" wording and is the simplest render (a single `ForEach` over `jobs[]`).
- **D-02:** **All terminal rows persist until the user dismisses them** — done, failed, and cancelled alike. One rule for everything, no auto-clear timers/animations. Consistent with Phase 5 D-06/D-07 (terminal jobs retained in session memory).
- **D-03:** **Newest on top.** The list scrolls inside a **fixed max-height** area (reuse the `TranscriptCard` `ScrollView { … }.frame(maxHeight:)` pattern) so recent activity stays visible and the popover never grows unbounded.

### Dismissal
- **D-04:** **Per-row ✕ on terminal rows** (done/failed/cancelled) **plus a bulk "Clear all/finished"** control. Because everything persists (D-02), a bulk clear is needed so cleanup isn't one-click-per-row in a busy session.
- **D-05:** **Clear-all removes ONLY terminal rows.** It never stops or removes in-flight jobs. Active (filing) rows have **Stop only — no ✕**. Stopping an active job routes through the existing cancel path → the row becomes `.cancelled` → then it is dismissable like any terminal row. No accidental loss of running work; no redundant Stop-vs-✕ on the same row.
- **D-06:** Requires **new `AppState` methods**: `dismiss(jobID:)` (remove one terminal job from `jobs[]`) and `clearFinished()` (remove all non-`.filing` jobs). These are pure array mutations — do **not** call `cancel`/`task.cancel()` (dismissal ≠ cancellation).

### Failed Row Content & "Recoverable"
- **D-07:** **Dismiss-only — no in-app Retry.** "Recoverable" = the error is visible, the originating transcript is preserved, and the user can act (re-dictate; or fix auth/Docker/network then try again). An in-app Retry that re-files the transcript is **out of scope** per PROJECT.md ("Advanced failure recovery (retries, queuing, partial-state repair) — beyond v1").
- **D-08:** A failed row shows the **mapped `IssueFilingError` message** (e.g. "AI CLI timed out — check your internet connection") **+ a truncated transcript snippet** (1–2 lines); the full transcript stays reachable via text selection / expand. Compact rows, full text still recoverable.
- **D-09:** Requires **exposing the currently-private `AppState.message(for: IssueFilingError)`** (line ~412) to the view layer (make it accessible / lift into a shared place). The mapping already exists — do not re-author error strings.

### Done (Success) Row Content
- **D-10:** A done row shows **"Issue #N filed" where `#N` is clickable** and opens `result.url` in the browser via `NSWorkspace.shared.open(...)`. The data already exists on the job (`FilingJob.result` → `IssueFilingResult { number, url }`); this turns the popover into a quick jump-to-issue surface at near-zero cost.

### Popover Layout / Placement
- **D-11:** Add a **new "Filing Jobs" section at the bottom of the popover, after the `TranscriptCard`.** Keeps the familiar capture flow (header → repo → action → transcript) on top; jobs accumulate below. The existing "last transcript" `TranscriptCard` stays (not replaced).
- **D-12:** The section is **hidden entirely when `jobs[]` is empty** (including its Clear-all control). When present, a small header — `FILING JOBS (N)` with the Clear-all control beside it — sits above the rows, matching the existing card-header style (cf. `TranscriptCard`'s "Transcript" + CopyButton header).

### Claude's Discretion (routed to research/planning)
- The exact row component design/visual style (spacing, per-state color/icon), the activity-indicator choice for `.filing` rows (the codebase already has `ActivitySpinner` and `WaveformView` to draw from), and the cancelled-row wording/styling.
- Where `dismiss(jobID:)` / `clearFinished()` and the exposed message mapper physically live, and how the row view reads them.
- How the transcript snippet is truncated/expanded (lineLimit + selection vs. disclosure) — D-08 fixes intent (snippet with full text reachable), not the mechanism.
- Whether the failed/error row reuses `StatusBanner`'s amber/warning treatment or gets its own row styling.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Planning Source
- `.planning/ROADMAP.md` §Phase 9 — goal + 3 success criteria (JOBS-01, JOBS-02, RESIL-01).
- `.planning/REQUIREMENTS.md` — JOBS-01, JOBS-02 (§Job Surfacing), RESIL-01 (§Recoverable Errors).
- `.planning/PROJECT.md` — Out of Scope: "Advanced failure recovery (retries, queuing, partial-state repair)"; Active req list includes "missing binding / failed filing" surfacing under RESIL-01.

### Prior-Phase Context (the model this phase renders)
- `.planning/phases/05-concurrent-filing-jobs-model/05-CONTEXT.md` — D-06/D-07 (jobs model shape; terminal jobs retained in session memory; dismiss/clear-all explicitly deferred to **this phase**); D-04/D-05 (generic spoken "issue filing failed" already ships — the closed-popover feedback that this phase's row complements).
- `.planning/phases/07-appkit-status-item-ui-settings-window-shell/07-CONTEXT.md` — D-06: the left-click popover is **transient** (auto-closes on outside click). Implication: the persistent failed row is the record seen **on reopen**; the spoken failure (Phase 5 D-04) is the live-while-closed signal. No design change needed, but planners must not assume the popover stays open.

### Current Code (the surface being built / extended)
- `Sources/MakeAnIssue/MenuView.swift` — the popover; currently renders **no jobs**. Body composition (header/StateBadge, `RepositoryCard`, `ActionCard`, `StatusBanner`, `TranscriptCard`) at lines 10–63; `frame(width: 320)`. Reusable: `TranscriptCard` ScrollView+maxHeight pattern (422–455), `CopyButton` (457–488), `ActivitySpinner` (309–328), `StatusBanner` amber style (389–420), card `.overlay`/`.cornerRadius` idiom.
- `Sources/MakeAnIssue/FilingJob.swift` — `FilingJob { id, transcript, repo, state, result, error, task, processGroupID }` (`Identifiable` for the `ForEach`); `FilingJobState { filing, done, failed, cancelled }`.
- `Sources/MakeAnIssue/AppState.swift` — `@Published var jobs: [FilingJob]` (line ~46); `cancel(jobID:)` (~333, `.filing`-guarded, wires JOBS-02 Stop); `cancelAll()` (~340); **`message(for: IssueFilingError)` is `private static` (~412) — must be exposed (D-09)**; no `dismiss`/`clear` exists yet (D-06).
- `Sources/MakeAnIssue/IssueResultParser.swift` — `IssueFilingResult { number, url }` (done-row clickable `#N` → `url`, D-10).
- `Sources/MakeAnIssue/IssueFilingConfig.swift` — `IssueFilingError` cases (timeout/cliFailed/permissionDenied/parseFailed/tokenAcquisitionFailed) that the mapper renders.

### Spike Findings (project blueprint — read before implementing)
- `.claude/skills/spike-findings-make-an-issue/SKILL.md` — implementation patterns & non-negotiables (auto-loaded during implementation).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `TranscriptCard` (MenuView 422–455): `ScrollView { … }.frame(maxHeight: 100)` + card chrome — direct model for the scrolling, fixed-height "Filing Jobs" section (D-03) and its header row (D-12 mirrors the "Transcript" + `CopyButton` header).
- `CopyButton` (457–488): reusable if a copy affordance is wanted; also the styling reference for small inline row buttons (Stop, ✕, Clear all).
- `ActivitySpinner` (309–328) / `WaveformView` (283–307): existing animated indicators for the `.filing` activity indicator (JOBS-01).
- `StatusBanner` + `Color.amberStyle` (389–420): warning treatment available to reuse for failed rows.
- `AppState.cancel(jobID:)`: the JOBS-02 Stop button target — already correct and `.filing`-guarded. **Reuse, don't rebuild.**
- `AppState.message(for: IssueFilingError)`: the failed-row message source (D-08/D-09) — expose, don't re-author.

### Established Patterns
- MenuView is a composition of small `struct … : View` subviews each rendering one card; the jobs section + a `JobRow` view should follow the same pattern.
- `jobs` is `@Published`; the list is a plain `ForEach(appState.jobs)` (FilingJob is `Identifiable`). Newest-first = iterate `.reversed()` or sort by insertion (jobs are appended in spawn order).
- Row controls mutate through `AppState` methods (`cancel`, and new `dismiss`/`clearFinished`) — keep all `jobs[]` mutation on `@MainActor AppState`, never in the view.

### Integration Points
- New `JobsSection` (+ `JobRow`) inserted into `MenuView.body` after `TranscriptCard` (D-11), gated on `!appState.jobs.isEmpty` (D-12).
- New `AppState.dismiss(jobID:)` and `AppState.clearFinished()` (D-06) — pure `jobs.removeAll`/`remove(at:)` mutations, main-actor, no cancellation side effects.
- Expose `message(for: IssueFilingError)` for `JobRow` to render failed messages (D-09).
- Done-row link → `NSWorkspace.shared.open(result.url)` (D-10).

</code_context>

<specifics>
## Specific Ideas

- The user consistently biased toward **the render that matches the requirement wording literally and reuses existing assets** (show all states; reuse `TranscriptCard` scroll pattern; reuse the existing error-message mapper and `cancel(jobID:)`), and toward **keeping in-app scope tight** (dismiss-only, no Retry). Bias the implementation toward the smallest change that satisfies JOBS-01/JOBS-02/RESIL-01.
- Clean control separation is a stated preference: **active rows = Stop only; terminal rows = ✕; Clear-all = terminal-only.** Do not blur these (no ✕-that-also-cancels on active rows).

</specifics>

<deferred>
## Deferred Ideas

- **In-app Retry / re-file the same transcript** — out of scope for v1.1 (PROJECT.md: no retries/queuing/partial-state repair). If back-to-back failures prove painful in practice, revisit as its own phase.
- **Cross-launch job history persistence** — explicitly out of scope (Phase 5 D-07); jobs live in session memory only.
- **Copy-transcript / copy-URL buttons on rows** — considered as middle-ground options but not chosen (clickable `#N` covers the success case; selection covers transcript). Trivial to add later if wanted.
- **In-flight "Filing issue…" progress detail beyond the activity indicator** — the Phase 6 UAT follow-up ("add an in-flight 'Filing issue…' indicator") is partially served by the `.filing` row + spinner; richer per-stage progress (investigating vs. filing) is not in this phase's scope.

None of the above is new scope for Phase 9 — all map to explicit out-of-scope items or later revisits.

</deferred>

---

*Phase: 9-Jobs List UI + Per-Job Stop + Surfaced Errors*
*Context gathered: 2026-07-01*
