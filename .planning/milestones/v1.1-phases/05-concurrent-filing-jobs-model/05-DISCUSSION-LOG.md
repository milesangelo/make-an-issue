# Phase 5: Concurrent Filing Jobs Model - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-28
**Phase:** 5-Concurrent Filing Jobs Model
**Areas discussed:** Confirmation content, Announce vs. recording, Interim failure feedback, Jobs model retention

---

## Confirmation content

| Option | Description | Selected |
|--------|-------------|----------|
| Just "#N" (keep current) | "created issue #142". Simplest; issue numbers unique so back-to-back announcements still distinguishable. No parser change. | ✓ |
| Number + repo | "created issue #142 in netshooter". Distinguishes filings across repos (but v1 shares one bound repo). | |
| Number + title snippet | "created issue #142: fix login crash". Most informative; requires capturing drafted title (parser extracts only number + URL today). | |

**User's choice:** Just "#N" (keep current)
**Notes:** Consistent minimal-change bias. Resolved in one question.

---

## Announce vs. recording

| Option | Description | Selected |
|--------|-------------|----------|
| Defer until mic idle | Hold confirmation; speak when recording stops. Prevents TTS bleeding into the live mic / corrupting the new whisper transcript. Needs a small pending-announcement queue gated on capture state. | ✓ |
| Speak immediately | Announce even over a live recording. Simplest; risks speaker audio leaking into the mic. | |
| You decide | Let planner/research determine feasibility. | |

**User's choice:** Defer until mic idle
**Notes:** Gate is the active-recording window only (mic off during transcribe/filing). Queued announcements fire back-to-back when recording stops.

---

## Interim failure feedback

| Option | Description | Selected |
|--------|-------------|----------|
| Speak a brief failure now | "issue filing failed" via TTS so background failures aren't lost before Phase 9's UI. Breaks success-only TTS contract. | ✓ |
| Stay silent (defer to Phase 9) | Keep success-only contract; record error state silently until Phase 9 surfaces it. | |
| You decide | Planner picks based on Phase 9 pull-forward. | |

**Follow-up — failure wording:**

| Option | Description | Selected |
|--------|-------------|----------|
| Generic "issue filing failed" | One phrase for any failure type. Phase 9 adds detail + transcript row. | ✓ |
| Short reason per type | "filing timed out" / "tool not permitted" etc. More actionable; phrasing for ~4 cases now. | |

**User's choice:** Speak a brief, generic "issue filing failed" now
**Notes:** Deliberate update to the v1.0 success-only TTS contract — failures are invisible with the popover closed. Detailed message + originating transcript deferred to Phase 9 (RESIL-01). Failure announcement obeys the same defer-until-mic-idle rule.

---

## Jobs model retention

| Option | Description | Selected |
|--------|-------------|----------|
| Retain terminal jobs + transcript | Keep each job through done/failed/cancelled + originating transcript. Phase 6/9/RESIL-01 plug in with no model rework. | ✓ |
| In-flight only, drop on completion | Track only active jobs; remove on completion. Leanest now; Phase 9 must add retention + transcript storage later. | |
| You decide | Planner chooses based on how cleanly the lean model extends. | |

**User's choice:** Retain terminal jobs + transcript
**Notes:** Session-memory only (no cross-launch history — out of scope). Jobs accumulate for the session; dismiss/clear is Phase 9. Each job stores id, transcript, repo, state, outcome.

---

## Claude's Discretion

- Jobs collection location/type design (`@Published` array on `AppState` vs. dedicated manager/actor), per-job Task/handle storage, exact `Job` type shape — planner/researcher decide (CONTEXT D-06 fixes only what each job carries).
- Whether to add the cancellation handle now (forward-prep) or in Phase 6 — planner's call.
- Pending-announcement queue implementation details.

## Deferred Ideas

- Enriched confirmations (repo/title in spoken text) — not for v1.1.
- Per-type spoken failure reasons + detailed failure message/transcript — Phase 9 (RESIL-01).
- Dismiss / clear-completed / cancel-all for retained jobs — Phase 9 (JOBS-04 future).
- Cross-launch job history — out of scope for v1.1.
