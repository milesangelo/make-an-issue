# Phase 9: Jobs List UI + Per-Job Stop + Surfaced Errors - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-01
**Phase:** 9-Jobs List UI + Per-Job Stop + Surfaced Errors
**Areas discussed:** Which jobs show + lifecycle, Dismissal affordance, Failed row content + "recoverable", Popover layout / placement

---

## Which Jobs Show + Lifecycle

### Which jobs render
| Option | Description | Selected |
|--------|-------------|----------|
| Active + all terminal | One ForEach over jobs[]; matches JOBS-01 wording literally | ✓ |
| Active + failed only | Drop done/cancelled on completion | |
| Active only + failed persist | Only filing rows live; failed persists | |

### Terminal lifecycle
| Option | Description | Selected |
|--------|-------------|----------|
| All persist until dismissed | done/cancelled/failed all stay until removed | ✓ |
| Success auto-clears, rest persist | done fades after seconds; failed/cancelled stay | |
| Only failed persists | done+cancelled auto-clear; failed lingers (RESIL-01 minimum) | |

### Ordering / volume
| Option | Description | Selected |
|--------|-------------|----------|
| Newest on top, scroll | Fixed max-height scroll area (TranscriptCard pattern) | ✓ |
| Oldest on top, scroll | Chronological append order | |
| Newest on top, no scroll cap | Popover grows unbounded | |

**User's choice:** Show active + all terminal states; everything persists until dismissed; newest on top inside a fixed-height scroll area.
**Notes:** Consistent one-rule lifecycle preferred over auto-clear timers. Reuse existing TranscriptCard scroll pattern.

---

## Dismissal Affordance

### Controls
| Option | Description | Selected |
|--------|-------------|----------|
| Per-row ✕ + Clear all | Per-row remove + bulk clear of finished rows | ✓ |
| Per-row ✕ only | Strict RESIL-01 minimum; many clicks to clean up | |
| Clear all only | No granular per-row dismiss | |

### Clear scope / active-row controls
| Option | Description | Selected |
|--------|-------------|----------|
| Clears finished only; active = Stop | Clear-all leaves in-flight jobs; active rows have Stop only | ✓ |
| Clears everything (stops active) | Clear-all also cancelAll — destructive | |
| Active rows get ✕ too (= Stop) | Two near-identical controls on active rows | |

**User's choice:** Per-row ✕ on terminal rows + a bulk Clear-all that only removes terminal rows; active rows keep Stop only (Stop → cancelled → then dismissable).
**Notes:** Clean control separation is a stated preference — no ✕-that-also-cancels on active rows. Needs new `dismiss(jobID:)` + `clearFinished()` on AppState (pure array mutation, no cancellation).

---

## Failed Row Content + "Recoverable"

### Meaning of "recoverable"
| Option | Description | Selected |
|--------|-------------|----------|
| Dismiss-only (re-dictate) | Visible + transcript-preserving; no in-app Retry | ✓ |
| Add a Retry button | Re-file same transcript — scope expansion | |
| Copy-transcript button | Middle ground, no re-file logic | |

### Row content detail
| Option | Description | Selected |
|--------|-------------|----------|
| Message + transcript snippet | Mapped error + truncated 1–2 line snippet, full text reachable | ✓ |
| Message + full transcript | Entire transcript inline (tall rows) | |
| Message only | Transcript only via expand | |

### Done (success) row
| Option | Description | Selected |
|--------|-------------|----------|
| Clickable #N → opens URL | NSWorkspace.open(result.url) | ✓ |
| Show #N, not clickable | Plain text confirmation | |
| #N + copy-URL button | Copy result.url to clipboard | |

**User's choice:** Dismiss-only (no Retry); failed row shows mapped IssueFilingError message + truncated transcript snippet; done row shows clickable #N opening the issue URL.
**Notes:** In-app retries confirmed out of scope (PROJECT.md). Requires exposing the private `message(for: IssueFilingError)` mapper to the view.

---

## Popover Layout / Placement

### Placement
| Option | Description | Selected |
|--------|-------------|----------|
| New section below transcript | After TranscriptCard; least disruption | ✓ |
| Above transcript, below ActionCard | Jobs prioritized once filing starts | |
| Replace the TranscriptCard | Jobs list becomes the transcript surface | |

### Section header / empty state
| Option | Description | Selected |
|--------|-------------|----------|
| Hidden when empty, header w/ count | `FILING JOBS (N)` + Clear-all; hidden when jobs empty | ✓ |
| Hidden when empty, no header | Rows + inline Clear-all, no header | |
| Always visible with empty state | Permanent "No filing jobs yet" placeholder | |

**User's choice:** New "Filing Jobs" section at the bottom (after TranscriptCard); hidden entirely when empty; header shows `FILING JOBS (N)` with the Clear-all control.
**Notes:** Existing capture flow (repo → action → transcript) stays on top; TranscriptCard is not replaced.

---

## Claude's Discretion

- Exact JobRow visual design (spacing, per-state color/icon), activity-indicator choice for `.filing` (ActivitySpinner vs WaveformView), cancelled-row wording/styling.
- Physical location of `dismiss(jobID:)`/`clearFinished()` and the exposed message mapper; how the row view reads them.
- Transcript snippet truncation/expand mechanism (lineLimit + selection vs. disclosure).
- Whether failed rows reuse StatusBanner's amber treatment or get bespoke row styling.

## Deferred Ideas

- In-app Retry / re-file same transcript — out of scope (PROJECT.md; revisit as own phase if painful).
- Cross-launch job history persistence — out of scope (Phase 5 D-07; session memory only).
- Copy-transcript / copy-URL row buttons — considered, not chosen; trivial to add later.
- Richer in-flight per-stage progress (investigating vs. filing) — beyond this phase; Phase 6 UAT follow-up partially served by the `.filing` row + spinner.
