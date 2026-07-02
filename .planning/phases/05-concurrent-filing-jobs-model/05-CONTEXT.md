# Phase 5: Concurrent Filing Jobs Model - Context

**Gathered:** 2026-06-28
**Status:** Ready for planning

<domain>
## Phase Boundary

Lift issue-filing out of the single `captureState` enum into a per-job model so that:
- Capture returns to `.idle` the instant transcription completes (no waiting on the prior filing).
- Multiple filings run concurrently in the background (unbounded — no concurrency-limit scheduler).
- Each filing independently speaks its own result when it completes.
- Per-invocation MCP tempfile isolation is preserved across concurrent jobs.

**This is a refactor of the existing serial pipeline**, not a new user-facing surface. The jobs **list UI** (rows, per-job Stop, dismiss/clear) is Phase 9; cancellation is Phase 6. Recording stays **serial** (one mic) — only filing is concurrent. The only user-facing output this phase adds is spoken confirmations/failures.

Delivers: CONCUR-01, CONCUR-02, CONCUR-03.

</domain>

<decisions>
## Implementation Decisions

### Spoken Confirmation Content
- **D-01:** Success confirmation stays `"created issue #N"` — unchanged from v1.0. No repo name, no title snippet. Issue numbers are unique enough to distinguish back-to-back announcements; this avoids any change to `IssueResultParser` (which extracts only number + URL today).

### Announcement vs. Live Recording
- **D-02:** Filing is concurrent but recording is serial, so a job can complete while the user is holding push-to-talk on a new dictation. Confirmations (and failures, D-04) MUST be **deferred until the mic is idle** — held in a pending-announcement queue and spoken the moment recording stops. Rationale: TTS over a live mic would bleed into the new recording and corrupt the whisper transcript.
- **D-03:** The defer gate is the active-recording window only (the mic is off during transcription/filing, so those states do not need to suppress speech). Multiple announcements that accumulate during a hold fire back-to-back when recording stops (consistent with D-01 — AVSpeechSynthesizer already enqueues utterances sequentially).

### Interim Failure Feedback (pre-Phase 9)
- **D-04:** A failed background filing MUST speak a brief, **generic** `"issue filing failed"` — for any failure type (timeout / permissionDenied / cliFailed / parseFailed). This deliberately **updates the v1.0 success-only TTS contract**, because with capture back at idle and the popover usually closed, a silent failure would vanish unseen before Phase 9's UI exists.
- **D-05:** No per-type spoken reason in Phase 5 — one phrase covers all failures. The detailed message + originating transcript surface in Phase 9's persistent job row (RESIL-01). The failure announcement obeys the same defer-until-mic-idle rule as success (D-02).

### Jobs Model Shape & Retention
- **D-06:** The Phase 5 jobs model **retains terminal jobs** (done / failed / cancelled) rather than dropping them on completion. Each job stores at minimum: a stable id, the originating transcript, the bound repo, its state, and its outcome (result number/url on success, error on failure). Rationale: Phase 9's jobs list, RESIL-01's "shown with originating transcript" persistent error rows, and Phase 6's cancel path all build directly on this shape — retaining now avoids a model rework later.
- **D-07:** Retained terminal jobs live in **session memory only** — no persistence across launches (out of scope: "Persistent job history across launches"). They accumulate for the session; a dismiss/clear affordance is Phase 9's concern, not this phase's.

### Capture State Refactor (follows from the above)
- **D-08:** `captureState` loses its `.filing` case. Capture transitions are recording → transcribing → idle; filing no longer occupies `captureState`. The `.finished` transient that immediately chained into `beginFiling()` is replaced by: on successful transcription, spawn a filing job into the jobs model and return capture to `.idle` immediately.
- **D-09:** The PTT re-entry guard changes meaning: today `startRecording()` blocks while `captureState == .filing`; under the jobs model, re-pressing PTT while filings are in flight is now **allowed** (it's the feature). The guard should only prevent overlapping *recordings*, not filings.

### Claude's Discretion
- Where the jobs collection lives (e.g., a `@Published` array on `AppState` vs. a dedicated jobs manager/actor), how each job's async Task/handle is stored, and the exact `Job` struct/enum shape — planner/researcher decide. D-06 only fixes *what* each job must carry, not its type design.
- Whether to keep a cancellation handle on each job now (forward-prep for Phase 6) or add it in Phase 6 — planner's call; Phase 6 explicitly owns the cancel mechanics.
- The pending-announcement queue's exact implementation (D-02/D-03) — a simple buffer flushed on `.recording` → `.idle` is sufficient.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike Findings (project blueprint — implementation patterns & non-negotiables)
- `.claude/skills/spike-findings-make-an-issue/SKILL.md` — scoped `--allowedTools` grant, structured-output `permission_denials` inspection, cwd=bound-repo, parse issue number from `url` not `id`.
- `.claude/skills/spike-findings-make-an-issue/references/headless-cli-invocation.md` — exact `claude -p` invocation flags, watchdog timeout pattern.
- `.claude/skills/spike-findings-make-an-issue/references/github-issue-filing.md` — `issue_write method=create`, MCP config (Docker `--rm` container, `GITHUB_TOOLSETS=issues`, token passthrough), URL→number parsing.

### Current Filing Pipeline (the code this phase refactors)
- `Sources/MakeAnIssue/AppState.swift` — `CaptureState` enum (lines 6-14), `beginFiling()` (line ~257), filing Task + TTS success path, success-only contract comment (~line 323).
- `Sources/MakeAnIssue/IssueFilingRunner.swift` — `static func file(...) async throws -> IssueFilingResult` (line ~111); per-invocation MCP tempfile `make-an-issue-mcp-<UUID>.json` with `defer` cleanup (lines ~141-147).
- `Sources/MakeAnIssue/IssueResultParser.swift` — `IssueFilingResult { number, url }` (lines 4-10).
- `Sources/MakeAnIssue/IssueFilingConfig.swift` — `IssueFilingError` enum (timeout/cliFailed/permissionDenied/parseFailed/tokenAcquisitionFailed); `mcpConfigJSON`.
- `Tests/MakeAnIssueTests/AppStateTests.swift` — `.filing`-asserting tests to rewrite: `testFilingEntersFilingState`, `testPushToTalkDuringFilingIsIgnored`, `testStartRecordingAfterFilingReturnsToIdleStartsNewRecording`, `.filing` assertions in `testSuccessfulTranscriptionStoresText`.

### Planning Source
- `.planning/ROADMAP.md` §Phase 5 — goal + 4 success criteria.
- `.planning/REQUIREMENTS.md` — CONCUR-01/02/03; Out-of-Scope (no overlapping captures, no persistent history, no concurrency-limit scheduler).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `IssueFilingRunner.file(...) async throws -> IssueFilingResult`: already async and self-contained per call — becomes the per-job unit of work. No change needed to its signature for concurrency.
- Per-invocation MCP tempfile (`make-an-issue-mcp-<UUID>.json` + `defer` cleanup): already isolated per call by UUID, so concurrent jobs do not collide — **success criterion 4 is satisfied by construction**; planner verifies, doesn't rebuild.
- `AVSpeechSynthesizer` (stored property, line ~48) + `speak(_:)` (lines ~302-305): natively enqueues utterances, so queued announcements (D-03) play sequentially for free. Keep it a stored property (Pitfall 1: avoids dealloc before speech completes).

### Established Patterns
- Filing already runs in a spawned `Task` off the main actor; results return via `await MainActor.run`. The jobs model generalizes this from one Task to N.
- Testability seams on `AppState`: `onRunIssueFiling`, `onSpeak`, `onRunTranscription`, `onCheckMicAuthorization` — preserve these so the jobs model stays unit-testable (tests inject filing outcomes + capture spoken text).

### Integration Points
- `AppState.beginTranscription()` success path: instead of chaining into `beginFiling()` (which set `.filing`), spawn a filing job into the jobs model and set `captureState = .idle`.
- TTS call sites (success + new failure path) route through the defer-until-mic-idle queue (D-02), not directly to `onSpeak`/`speak`.

</code_context>

<specifics>
## Specific Ideas

- User consistently chose the **minimal** option (plain `#N`, generic failure text) — bias the implementation toward the smallest change that satisfies the requirement; defer enrichment to the phases that own it (Phase 9).

</specifics>

<deferred>
## Deferred Ideas

- **Enriched confirmations** (repo name / title snippet in spoken text) — not wanted for v1.1; would require the parser to also capture the drafted title. Revisit only if back-to-back `#N` announcements prove confusing in practice.
- **Per-type spoken failure reasons** and the detailed failure message/transcript surface — Phase 9 (RESIL-01).
- **Dismiss / clear-completed / cancel-all** for retained terminal jobs — Phase 9 (JOBS-04 is explicitly future).
- **Cross-launch job history** — out of scope for v1.1 by decision.

None of the above is new scope for Phase 5 — all map to already-planned later phases or explicit out-of-scope items.

</deferred>

---

*Phase: 5-Concurrent Filing Jobs Model*
*Context gathered: 2026-06-28*
