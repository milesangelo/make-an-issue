# Phase 6: Cancellation / Stop Control - Context

**Gathered:** 2026-06-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver the **cancellation mechanism** for in-flight filings and guarantee clean shutdown:

- Aborting an in-flight filing terminates its full `claude → docker` process tree — no orphaned
  `claude` process and no leaked `--rm` Docker container (verifiable via `pgrep -f claude` /
  `docker ps`).
- A cancelled filing surfaces a "filing cancelled" outcome (spoken + status), marks the job
  `.cancelled`, and files no issue.
- Quitting the app while filings are in flight terminates their subprocess trees and removes their
  per-invocation MCP tempfiles, leaving no orphans.
- The single-resume continuation invariant holds under cancel and quit — no double-resume crash,
  no hung "Filing…" job.

**This phase ships the cancel *mechanism* + quit teardown, not a user-facing Stop UI.** The
per-job Stop button and jobs list are Phase 9 (JOBS-02); the NSStatusItem shell is Phase 7. The
current `MenuBarExtra` menu is being replaced in Phase 7, so no interim cancel affordance is built
here. Criterion #1 is verified by integration tests, not by a UI surface.

Delivers: CANCEL-01, CANCEL-02, CANCEL-03.

</domain>

<decisions>
## Implementation Decisions

### Cancel Trigger Surface
- **D-01:** Phase 6 is **mechanism-only**. Build `cancel(jobID:)` (cancel one job) and a
  `cancelAll()` / quit-time teardown path on the jobs model, proven via integration tests that
  assert no orphaned `claude` process and no leaked container remain (`pgrep -f claude` /
  `docker ps`). **No interim "Stop filing" menu item** — the `MenuBarExtra` menu is replaced in
  Phase 7 and the real per-job Stop button lands in Phase 9 (JOBS-02), so a throwaway affordance
  is avoided. The `FilingJob.task` cancel handle that Phase 5 already stores (forward-prep) is
  what gets wired up here.

### Cancelled Job State & Retention
- **D-02:** A cancelled job is marked `FilingJobState.cancelled` and **retained** in the session
  jobs list, exactly like `.done` / `.failed` jobs. This uses the `.cancelled` case Phase 5
  already added and stays consistent with the retain-terminal-jobs model (Phase 5 D-06/D-07).
  Phase 9's list renders the row and owns dismiss/clear.
- **D-03:** Roadmap criterion #2's wording "removes the job" is interpreted as **removes it from
  the active/in-flight set** (it is no longer `.filing`), **not** literal deletion from `jobs[]`.
  This resolves the apparent conflict with Phase 5's retained-terminal-jobs decision in favor of
  Phase 5's locked model.

### Quit-Time Cleanup Envelope
- **D-04:** On quit with filings in flight, intercept termination
  (`applicationShouldTerminate` → `.terminateLater`) and run a **brief blocking graceful
  teardown**: send each in-flight tree a graceful signal first so Docker `--rm` can stop and
  auto-remove the container, then **escalate to a force-kill after a bounded grace window**
  (planner picks the exact duration; the conversation used ~2s as a reference — the same grace
  used in `CLIRunner`'s SIGTERM→SIGKILL escalation), then sweep `make-an-issue-mcp-*.json`
  tempfiles, then allow the app to terminate. Rationale: SIGKILL-ing the `claude` / `docker run`
  client can leave a daemon-managed container running, so a graceful-first teardown is required to
  reliably satisfy "no leaked `--rm` container" on quit. Quit is delayed only by the bounded grace
  window.

### Cancelled Announcement Behavior
- **D-05:** Every cancel — user-initiated or quit-driven — speaks `"filing cancelled"`, routed
  through Phase 5's `announce()` defer-until-mic-idle queue (Phase 5 D-02/D-03), consistent with
  how `.done` / `.failed` announce. Generic single phrase (consistent with Phase 5 D-04/D-05 — no
  per-type detail in this phase).
- **D-06:** On actual app **quit**, the process is exiting, so a quit-time cancel realistically
  will not get to speak — status text / log is the practical surface in that case. This is
  **accepted**; CANCEL-02's "spoken" requirement is satisfied by the user-initiated cancel path.

### Claude's Discretion (routed to research/planning — technical, not user decisions)
- **Process-tree termination mechanics** — the core technical problem: today `CLIRunner` spawns
  `/bin/zsh -lc "claude -p … --mcp-config <tempfile>"`, and `claude` spawns
  `docker run -i --rm ghcr.io/github/github-mcp-server` as its MCP server. The current
  `process.terminate()` / `kill(pid, SIGKILL)` signals **only the `zsh` PID** — it does NOT reach
  `claude` or the Docker container. Researcher/planner decide: process-group creation so the kill
  reaches the whole tree (e.g. spawn the child as a process-group leader and `killpg`), the
  SIGTERM→grace→SIGKILL strategy, and whether to rely on `claude` tearing down its `docker run`
  child vs. signalling the tree directly — whatever **provably** leaves no orphaned `claude` and no
  leaked `--rm` container.
- **`CLIRunner` cancellation seam** — how `CLIRunner.run` observes cancellation (cooperative Swift
  `Task` cancellation vs. an explicit cancel/terminate handle) while preserving its existing
  single-resume `RunState` lock invariant. The cancel path must drive the process termination →
  `terminationHandler` → single `claim()` resume, with **no double-resume and no hung `.filing`
  job** (criterion #4). Planner decides where the per-job cancel handle lives relative to the
  existing `FilingJob.task` and whether `IssueFilingRunner.file` needs a new termination seam.
- **Exact grace-window duration** for D-04's escalation — planner's call.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike Findings (project blueprint — implementation patterns & non-negotiables)
- `.claude/skills/spike-findings-make-an-issue/SKILL.md` — scoped `--allowedTools` grant,
  structured-output inspection, cwd=bound-repo, parse issue number from `url`.
- `.claude/skills/spike-findings-make-an-issue/references/github-issue-filing.md` — **the exact
  Docker MCP invocation that must be torn down**: `docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN
  -e GITHUB_TOOLSETS=issues ghcr.io/github/github-mcp-server`, run over stdio as a child of `claude`.
- `.claude/skills/spike-findings-make-an-issue/references/headless-cli-invocation.md` — exact
  `claude -p` invocation flags + the watchdog-kill pattern (`kill -9 "$pid"`) the spike used.

### Code This Phase Modifies (the cancellation seam)
- `Sources/MakeAnIssue/CLIRunner.swift` — **primary file**. Spawns `Process()` → `/bin/zsh -lc`
  (lines 82–92); the single-resume `RunState`/`NSLock` invariant (lines 32–59); the existing
  SIGTERM→2s-grace→SIGKILL timeout escalation (lines 158–186) — the model to extend for an explicit
  cancel. Note `kill(process.processIdentifier, SIGKILL)` (line 183) currently kills **only the zsh
  PID**, not the `claude → docker` descendants — this is the gap to close.
- `Sources/MakeAnIssue/AppState.swift` — `spawnFilingJob(transcript:repo:)` (lines 260–292) stores
  each job's `Task` handle on `FilingJob.task`; `announce(_:)` defer-until-mic-idle queue
  (lines 295–310). Add `cancel(jobID:)` / `cancelAll()` here and route the cancelled announcement
  through `announce()`.
- `Sources/MakeAnIssue/FilingJob.swift` — `FilingJobState.cancelled` (already present, line 11);
  `task: Task<Void, Never>?` cancel handle (already present) — `.cancel()` wiring is this phase.
- `Sources/MakeAnIssue/IssueFilingRunner.swift` — `file(...)` (line 111); per-invocation MCP
  tempfile `make-an-issue-mcp-<UUID>.json` written at lines 143–147 with `defer` cleanup — note the
  `defer` runs on normal return/throw but **not** on app-process exit, so quit needs an explicit
  tempfile sweep (D-04).
- `Sources/MakeAnIssue/AppDelegate.swift` — `NSApplicationDelegate`; add
  `applicationShouldTerminate` → `.terminateLater` quit-teardown hook (D-04).

### Planning Source
- `.planning/ROADMAP.md` §Phase 6 — goal + 4 success criteria.
- `.planning/REQUIREMENTS.md` — CANCEL-01/02/03; Out-of-Scope (advanced failure recovery — basic
  clear errors only).
- `.planning/phases/05-concurrent-filing-jobs-model/05-CONTEXT.md` — upstream jobs model: D-06/D-07
  (retain terminal jobs, session-memory only), D-02/D-03 (defer-until-mic-idle announcements),
  D-04/D-05 (generic outcome phrasing), and the `FilingJob.task` forward-prep this phase builds on.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `CLIRunner.RunState` (`NSLock`-backed single-resume claim, lines 32–59): the exact mechanism that
  guarantees criterion #4 (no double-resume). The cancel path must funnel through `claim()` like the
  timeout path already does (lines 162–170) — terminate, claim the slot, resume once.
- `CLIRunner`'s timeout escalation (lines 158–186): a working **SIGTERM→2s grace→SIGKILL** template.
  Cancellation is the same shape (terminate → grace → force-kill) but triggered by a cancel signal
  instead of a wall-clock timeout — and must reach the whole process tree, not just the zsh PID.
- `AppState.announce(_:)` + `pendingAnnouncements` (lines 295–310): the cancelled outcome speaks
  through this for free, inheriting the defer-until-mic-idle behavior (D-05).
- `FilingJob.task` + `FilingJobState.cancelled`: both already exist as Phase 5 forward-prep — no
  model rework needed, just wiring.

### Established Patterns
- Filing already runs in a spawned `@MainActor`-inherited `Task` whose handle is stored on the job
  (`spawnFilingJob`, lines 260–292). Cancel keys off that stored handle.
- Per-invocation MCP tempfile isolation by UUID (`make-an-issue-mcp-<UUID>.json`): each job's
  tempfile is independent, so a quit-time sweep can safely glob-delete all `make-an-issue-mcp-*.json`.
- Testability seams on `AppState` (`onRunIssueFiling`, `onSpeak`, etc.): preserve so the cancel path
  stays unit-testable (inject a long-running/cancellable filing stub; assert `.cancelled` state +
  captured "filing cancelled" spoken text).

### Integration Points
- **Swift `Task.cancel()` is not enough** — cancelling the job's `Task` does not terminate the
  subprocess, because `CLIRunner.run` resolves a `withCheckedContinuation` that does not observe
  cancellation and the OS process tree outlives the Task. The plan must add an explicit
  process-termination seam (reaching `claude → docker`) and connect it to `cancel(jobID:)` and the
  quit path.
- **Quit teardown lives in `AppDelegate`**, but the in-flight job/process handles live on
  `AppState` — the plan must give `AppDelegate` a way to drive `AppState.cancelAll()` (or equivalent)
  synchronously enough to satisfy `.terminateLater`.

</code_context>

<specifics>
## Specific Ideas

- User consistently chose the **minimal / recommended** option in every area (mechanism-only,
  reuse the existing `.cancelled` state, no throwaway UI) — bias the implementation toward the
  smallest change that provably satisfies CANCEL-01/02/03, deferring all surfacing to Phase 9.
- The acceptance bar is **verification-first**: criterion #1 must be demonstrable via
  `pgrep -f claude` / `docker ps` showing zero orphans after a cancel — design the tests around
  that observable, not around UI.

</specifics>

<deferred>
## Deferred Ideas

- **Per-job Stop button + jobs list UI** — Phase 9 (JOBS-01/JOBS-02). Phase 6 ships only the
  mechanism behind it.
- **NSStatusItem shell / right-click menu** — Phase 7 (the reason no interim cancel menu item is
  built now).
- **Per-type / detailed cancelled messaging** and persistent recoverable error rows — Phase 9
  (RESIL-01); Phase 6 keeps the single generic "filing cancelled" phrase.
- **Cancel-all / dismiss-completed affordances** for retained terminal jobs — Phase 9 (JOBS-04 is
  explicitly future). Phase 6's `cancelAll()` is an internal quit-path API, not a user control.

None of the above is new scope for Phase 6 — all map to already-planned later phases.

</deferred>

---

*Phase: 6-Cancellation / Stop Control*
*Context gathered: 2026-06-29*
