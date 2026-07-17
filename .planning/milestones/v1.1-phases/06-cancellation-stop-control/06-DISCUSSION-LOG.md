# Phase 6: Cancellation / Stop Control - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-29
**Phase:** 6-Cancellation / Stop Control
**Areas discussed:** Cancel trigger surface, Cancelled job remove vs. retain, Quit-time cleanup envelope, Cancelled announcement behavior

---

## Cancel Trigger Surface This Phase

| Option | Description | Selected |
|--------|-------------|----------|
| Mechanism-only | `cancel(jobID:)` + `cancelAll()` APIs + on-quit teardown, wired into the jobs model, proven via integration tests (pgrep/docker ps). No throwaway menu item. | ✓ |
| Interim 'Stop all filing' menu item | Also add a 'Stop all filing' affordance to the current MenuBarExtra menu for hand-testing now; discarded when Phase 7 replaces the menu / Phase 9 adds per-job Stop. | |

**User's choice:** Mechanism-only
**Notes:** MenuBarExtra is replaced in Phase 7 and the real per-job Stop UI is Phase 9, so any menu affordance now is throwaway. Criterion #1 verified by tests, not UI.

---

## Cancelled Job: Remove vs. Retain

| Option | Description | Selected |
|--------|-------------|----------|
| Retain as .cancelled | Mark the job `.cancelled` and keep it like done/failed; consistent with Phase 5 D-06/D-07; gives Phase 9 a row. Treat roadmap "removes the job" as removes from the in-flight set. | ✓ |
| Literally remove from jobs[] | Drop the job from the array entirely; matches roadmap literal wording but contradicts Phase 5's retained-terminal-jobs model. | |

**User's choice:** Retain as `.cancelled`
**Notes:** Uses the `.cancelled` state Phase 5 already added. Resolves the roadmap-vs-Phase-5 conflict in favor of the locked Phase 5 model.

---

## Quit-Time Cleanup Envelope

| Option | Description | Selected |
|--------|-------------|----------|
| Brief blocking graceful teardown | `applicationShouldTerminate` → `.terminateLater`; graceful signal first so Docker `--rm` stops+reaps the container, escalate to force-kill after a bounded grace, sweep tempfiles, then quit. | ✓ |
| Best-effort immediate | Force-kill all trees + sweep tempfiles synchronously, terminate immediately; risks a momentarily-leaked `--rm` container. | |
| You decide / research it | Lock only the requirement; let researcher/planner choose the mechanism. | |

**User's choice:** Brief blocking graceful teardown
**Notes:** SIGKILL-ing the `claude`/`docker run` client can leave a daemon-managed container running, so graceful-first teardown is needed to reliably satisfy "no leaked container" on quit. Quit delayed only by the bounded grace window (~2s reference, planner picks exact value).

---

## Cancelled Announcement Behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Speak always, obey defer-until-idle | Every cancel speaks "filing cancelled" via Phase 5's `announce()` defer-until-mic-idle queue (D-02/D-03). Quit-time cancels realistically won't get to speak — status/log only, accepted. | ✓ |
| Speak only on quit/implicit, silent on user Stop | Skip TTS on explicit user Stop; speak only for implicit/quit cancels. Adds a branch, diverges from CANCEL-02's blanket wording. | |

**User's choice:** Speak always, obey defer-until-idle
**Notes:** Consistent with how Phase 5's done/failed outcomes announce. Generic single phrase (Phase 5 D-04/D-05).

---

## Claude's Discretion

Routed to research/planning as technical (not user) decisions:
- **Process-tree termination mechanics** — process-group creation so the kill reaches `claude → docker` (today only the `zsh` PID is signalled), SIGTERM→grace→SIGKILL strategy, and whether to rely on `claude` tearing down its `docker run` MCP child vs. signalling the tree directly. Must provably leave no orphaned `claude` and no leaked `--rm` container.
- **`CLIRunner` cancellation seam** — how `CLIRunner.run` observes cancellation while preserving its single-resume `RunState`/`NSLock` invariant (no double-resume, no hung `.filing` job — criterion #4).
- **Exact grace-window duration** for the quit/cancel escalation.

## Deferred Ideas

- Per-job Stop button + jobs list UI — Phase 9 (JOBS-01/02).
- NSStatusItem shell / right-click menu — Phase 7.
- Per-type / detailed cancelled messaging + persistent recoverable error rows — Phase 9 (RESIL-01).
- Cancel-all / dismiss-completed user controls for retained terminal jobs — Phase 9 (JOBS-04, future).
