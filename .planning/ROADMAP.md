# Roadmap: make-an-issue

## Milestones

- ✅ **v1.0 MVP** — Phases 1-4 (shipped 2026-06-28) — see [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)
- 🚧 **v1.1 Concurrent Filing & Control** — Phases 5-9 (planning) — remove the serial-filing bottleneck and give the user control over filing and the LLM prompt

## Phases

<details>
<summary>✅ v1.0 MVP (Phases 1-4) — SHIPPED 2026-06-28</summary>

Vertical-MVP walking skeleton delivering the v1 happy path: speak a thought → an issue is
filed in the bound GitHub repo via the user's AI CLI + MCP → the issue number is spoken back.
Full phase details archived in [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md).

- [x] Phase 1: Menu-Bar App + Repo-Bound Launch (3/3 plans) — completed 2026-06-24
- [x] Phase 2: Push-to-Talk Voice Capture (2/2 plans) — completed 2026-06-24
- [x] Phase 3: Local Transcription — bundled-whisper rework (5/5 plans) — completed 2026-06-26
- [x] Phase 4: Voice → AI CLI Drafts & Files Issue via MCP + Spoken Confirmation (5/5 plans) — completed 2026-06-26

</details>

### v1.1 Concurrent Filing & Control (Phases 5-9)

One foundational `FilingJob` model refactor plus four UI/control surfaces grafted onto the
solved v1.0 architecture. The critical chain is `jobs model → cancellation → status-item shell →
editable prompt / jobs list`. No new third-party dependencies.

- [x] **Phase 5: Concurrent Filing Jobs Model** - Lift filing out of the single `captureState` enum so capture returns to idle immediately and filings run concurrently (completed 2026-06-29)
- [x] **Phase 6: Cancellation / Stop Control** - Abort an in-flight filing by terminating its full `claude → docker` process tree; clean up on quit (completed 2026-06-30)
- [x] **Phase 7: AppKit Status-Item UI + Settings Window Shell** - Replace `MenuBarExtra` with `NSStatusItem` (left-click popover / right-click menu), self-owned Settings window, and a live recording indicator on the icon (completed 2026-06-30)
- [ ] **Phase 8: Editable System Prompt + FINDING-06 Cleanup** - Editable, persisted drafting instructions in Settings with an unbreakable enforced contract; resolve the orphaned "CLI Command" field
- [ ] **Phase 9: Jobs List UI + Per-Job Stop + Surfaced Errors** - Render active jobs in the menu with per-row Stop and persistent, recoverable error rows (RESIL-01)

## Phase Details

### Phase 5: Concurrent Filing Jobs Model

**Goal**: A developer can fire off issue filings back-to-back — capture returns to idle the moment transcription completes, and multiple filings run concurrently in the background, each announcing its own result.
**Depends on**: Phase 4 (v1.0 filing pipeline)
**Requirements**: CONCUR-01, CONCUR-02, CONCUR-03
**Success Criteria** (what must be TRUE):

  1. After transcription completes, the app returns to idle immediately — the user can hold the shortcut and start a new recording without waiting for the prior filing to finish.
  2. Two or more filings can be in flight at the same time (a second and third dictation begin filing while the first is still running).
  3. Each filing independently speaks its own "created issue #N" confirmation when it completes, regardless of what the user is doing.
  4. Per-invocation MCP tempfile isolation is preserved across concurrent jobs — no shared-state collision between simultaneous filings.

**Plans**: 2/2 plans complete

- [x] 05-01-PLAN.md
- [x] 05-02-PLAN.md

### Phase 6: Cancellation / Stop Control

**Goal**: A developer can abort a bad in-flight filing cleanly, and quitting the app never leaves orphaned processes or leaked Docker containers behind.
**Depends on**: Phase 5 (per-job model + cancel handles)
**Requirements**: CANCEL-01, CANCEL-02, CANCEL-03
**Success Criteria** (what must be TRUE):

  1. Stopping an in-flight filing terminates the full `claude → docker` process tree — no orphaned `claude` process and no leaked `--rm` container remain (verifiable via `pgrep -f claude` / `docker ps`).
  2. A cancelled filing surfaces a "filing cancelled" outcome (spoken + status), removes the job, and files no issue.
  3. Quitting the app while filings are in flight terminates their subprocesses and removes their per-invocation MCP tempfiles, leaving no orphans.
  4. Cancelling or quitting never triggers a double-resume crash or a hung "Filing…" job — the single-resume continuation invariant holds.

**Plans**: 4/4 plans complete
**Wave 1**

- [x] 06-01-PLAN.md — Wave 0: empirical process-group gate (validate A1/A2) + cancel test scaffolds
- [x] 06-02-PLAN.md — Wave 1: CLIRunner process-group kill + withTaskCancellationHandler bridge + onSpawn pgid; IssueFilingRunner checkCancellation seam; FilingJob.processGroupID

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 06-03-PLAN.md — Wave 2: AppState cancel surface (cancel/cancelAll/forceKillAllProcessTrees + CancellationError catch) + AppStateTests

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 06-04-PLAN.md — Wave 3: AppDelegate quit teardown (applicationShouldTerminate + MCP tempfile sweep)

### Phase 7: AppKit Status-Item UI + Settings Window Shell

**Goal**: Right-clicking the menu-bar icon opens a Settings/Quit menu while left-click keeps the status popover, and the icon itself shows a live recording indicator — all on a self-owned AppKit shell that works across macOS 13–15.
**Depends on**: Phase 5 (popover binds the jobs model)
**Requirements**: SETTINGS-01, FEEDBACK-02
**Success Criteria** (what must be TRUE):

  1. Right-clicking the menu-bar icon opens a menu with "Settings…" and "Quit"; left-clicking still opens the status popover.
  2. Choosing "Settings…" opens a focusable Settings window (an empty shell is acceptable this phase) that can take keyboard focus in the accessory (LSUIElement) app.
  3. While push-to-talk is held and recording is live, the menu-bar icon shows an active-recording indicator (tinted/highlighted button or recording symbol) visible with the popover closed, and reverts when recording stops.
  4. The global push-to-talk shortcut continues to fire reliably across popover/menu open-close cycles with another app focused.

**Plans**: 2/2 plans complete
**Wave 1**

  - [x] 07-01-PLAN.md — AppKit status-item shell (left-click popover / right-click Settings…/Quit), self-owned Settings window + relocated Recorder, recording indicator, MenuBarExtra→Settings{} scene swap (Wave 1)

**Wave 2** *(blocked on Wave 1 completion)*

  - [x] 07-02-PLAN.md — Popover cleanup: remove the relocated shortcut editor + the menu end-tracking workaround from MenuView; preserve CLI field + ShortcutPillView (Wave 2, depends on 07-01)

**UI hint**: yes

### Phase 8: Editable System Prompt + FINDING-06 Cleanup

**Goal**: A developer can tune how the AI drafts issues through an editable instructions field in Settings — without ever being able to break the enforced tool-scope + issue-URL contract — and the orphaned "CLI Command" field is resolved.
**Depends on**: Phase 7 (Settings window shell), Phase 5/6 (`instructions:` plumbing through IssueFilingRunner)
**Requirements**: SETTINGS-02, SETTINGS-03, SETTINGS-04, SETTINGS-05
**Success Criteria** (what must be TRUE):

  1. The Settings window exposes an editable field for the LLM investigation/drafting instructions, and its contents persist across app launches.
  2. A "Reset to Default" control restores the shipped default prompt instructions.
  3. No matter what the user types, the app still appends the scoped `--allowedTools` grant and the "Issue URL on the last line" instruction — so issue-number parsing and tool scoping cannot be broken by edits (the editable field is instructions-only; flags and the enforced trailer live outside it).
  4. The orphaned "CLI Command" field (FINDING-06) is relocated into Settings (wired or removed), with no false affordance left in the menu.

**Plans**: 3 plans

**Wave 1**

  - [ ] 08-01-PLAN.md — FINDING-06 cleanup: remove the orphaned "CLI Command" field + `cliCommandKey` from MenuView/AppState (D-01/D-01a); add `instructionsKey` (SETTINGS-05)

**Wave 2** *(depends on 08-01)*

  - [ ] 08-02-PLAN.md — Enforced-contract core: `defaultInstructions` + `enforcedTrailer`, restructure `buildPrompt(instructions:)` with D-08 blank-fallback, thread instructions through `file()` read fresh per invocation (SETTINGS-04, SETTINGS-02)

**Wave 3** *(depends on 08-02)*

  - [ ] 08-03-PLAN.md — Settings Instructions UI: TabView (Shortcut/Instructions), `@AppStorage(instructionsKey)` editor, Reset-to-Default, read-only enforced-contract display (SETTINGS-02, SETTINGS-03)

**UI hint**: yes

### Phase 9: Jobs List UI + Per-Job Stop + Surfaced Errors

**Goal**: The menu surfaces every active filing as a live job row with its state and a Stop button, and a failed filing persists as a visible, recoverable error instead of silently disappearing.
**Depends on**: Phase 5 (jobs model), Phase 6 (cancel path), Phase 7 (popover shell)
**Requirements**: JOBS-01, JOBS-02, RESIL-01
**Success Criteria** (what must be TRUE):

  1. The menu shows a list of active filing jobs, each with its state (filing / done / failed / cancelled) and an activity indicator.
  2. Each active job row has a Stop control that cancels that specific job (the UI surface for CANCEL-01).
  3. A failed filing surfaces a recoverable error — spoken (the popover is usually closed) and shown as a persistent job row with the message and originating transcript — that remains until the user dismisses it.

**Plans**: TBD
**UI hint**: yes

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Menu-Bar App + Repo-Bound Launch | v1.0 | 3/3 | Complete | 2026-06-24 |
| 2. Push-to-Talk Voice Capture | v1.0 | 2/2 | Complete | 2026-06-24 |
| 3. Local Transcription | v1.0 | 5/5 | Complete | 2026-06-26 |
| 4. Voice → AI CLI Files Issue via MCP + Spoken Confirmation | v1.0 | 5/5 | Complete | 2026-06-26 |
| 5. Concurrent Filing Jobs Model | v1.1 | 2/2 | Complete    | 2026-06-29 |
| 6. Cancellation / Stop Control | v1.1 | 4/4 | Complete    | 2026-06-30 |
| 7. AppKit Status-Item UI + Settings Window Shell | v1.1 | 2/2 | Complete    | 2026-06-30 |
| 8. Editable System Prompt + FINDING-06 Cleanup | v1.1 | 0/3 | Planned | - |
| 9. Jobs List UI + Per-Job Stop + Surfaced Errors | v1.1 | 0/? | Not started | - |
