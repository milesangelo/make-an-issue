# Phase 2: Push-to-Talk Voice Capture - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-24
**Phase:** 2-Push-to-Talk Voice Capture
**Areas discussed:** Shortcut behavior, Recording file contract

---

## Shortcut Behavior

| Option | Description | Selected |
|--------|-------------|----------|
| No default shortcut | User must set a shortcut in the menu/settings before recording. Safest for conflicts, but adds setup friction. | |
| Ship a sensible default | Faster first-run path; user can change it later. | yes |
| You decide | Downstream agents choose the simplest happy-path option consistent with `KeyboardShortcuts.Recorder`. | |

**User's choice:** Ship a sensible default and let the user change it.
**Notes:** Follow-up selected `Control-Option-I` as the default shortcut.

| Option | Description | Selected |
|--------|-------------|----------|
| `Control-Option-Space` | Low-conflict and easy to hold. | |
| `Control-Option-I` | Mnemonic for issue. | yes |
| Planner chooses | Lock default-shortcut behavior but leave the exact combo to planning. | |
| Other | Freeform shortcut choice. | |

**User's choice:** `Control-Option-I`.
**Notes:** This locks the default shortcut for Phase 2 planning.

| Option | Description | Selected |
|--------|-------------|----------|
| First key-down starts, key-up stops | Best fit for push-to-talk; ignore repeats while already recording. | yes |
| Repeating key-down keeps recording alive | More moving parts and likely unnecessary for a held shortcut. | |
| Planner decides | Leaves the detail to implementation. | |

**User's choice:** First key-down starts, key-up stops.
**Notes:** Repeating key-down events should be ignored while recording.

---

## Recording File Contract

| Option | Description | Selected |
|--------|-------------|----------|
| App Support capture directory | Stable for the app pipeline and avoids cluttering the bound repo. | yes |
| Bound repo directory | Easier to inspect per repo, but writes app artifacts into the user's project. | |
| Temporary directory | Clean by default, but riskier for downstream phases if files disappear. | |
| Other | Freeform location. | |

**User's choice:** Application Support capture directory.
**Notes:** Do not write Phase 2 recording artifacts into the bound repository.

| Option | Description | Selected |
|--------|-------------|----------|
| Replace prior recording | Simplest handoff to Phase 3 and enough for v1 happy path. | yes |
| Timestamp every recording | Better for debugging, but requires cleanup policy later. | |
| Timestamp and keep latest N | More complete, but adds retention behavior outside the core happy path. | |
| Other | Freeform lifetime behavior. | |

**User's choice:** Replace the prior recording with one known file path.
**Notes:** The pipeline should not need to discover a newest timestamped file in v1.

| Option | Description | Selected |
|--------|-------------|----------|
| Phase 2 writes `16 kHz` mono WAV directly | Matches `CAPTURE-03`; Phase 3 can consume it without conversion. | yes |
| Record native format, convert later | Simpler recording code now, but pushes requirement risk into Phase 3. | |
| Planner decides based on AVFoundation constraints | Keeps the requirement locked but leaves exact mechanism to planning. | |
| Other | Freeform format contract. | |

**User's choice:** Phase 2 writes `16 kHz` mono WAV directly.
**Notes:** This is part of the Phase 2 output contract, not a Phase 3 conversion task.

| Option | Description | Selected |
|--------|-------------|----------|
| `Application Support/MakeAnIssue/latest.wav` | Single obvious path; simplest handoff. | yes |
| `Application Support/MakeAnIssue/Recordings/latest.wav` | Slightly more structured and leaves room for other app files. | |
| Planner decides | Locks App Support plus replace-latest behavior but leaves exact name to implementation. | |
| Other | Freeform path. | |

**User's choice:** `Application Support/MakeAnIssue/latest.wav`.
**Notes:** This is the stable handoff path for Phase 3.

## the agent's Discretion

None.

## Deferred Ideas

None.
