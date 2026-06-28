# Project Research Summary

**Project:** make-an-issue
**Domain:** Native macOS menu-bar utility (Swift 6 / SwiftUI + AppKit) — adding concurrent subprocess jobs, cooperative cancellation, and an AppKit settings UI
**Researched:** 2026-06-28
**Confidence:** HIGH

## Executive Summary

v1.1 ("Concurrent Filing & Control") is structurally **one foundational refactor plus four UI surfaces grafted onto a solved v1.0 architecture**. All four research streams converge on the same load-bearing change: filing must be lifted out of the single shared `CaptureState` enum (where `.filing` blocks new captures for up to 300s) into a collection of independent value-typed `FilingJob`s in a `@Published [FilingJob]`, with cancel handles held separately in a private `[UUID: Task<Void, Never>]`. Once filing is per-job, concurrency, the jobs list, per-job cancel, per-job error rows, and per-job spoken outcomes all fall out naturally. No new third-party dependencies are required — every API needed (`withTaskCancellationHandler`, `NSStatusItem`, `NSPopover`, `NSWindow`/`NSHostingController`, `@AppStorage`) is first-party and already in the macOS 13 SDK / Swift 6 toolchain.

The recommended approach **preserves the spike-locked v1.0 invariants rather than rewriting them**: the NSLock-guarded `RunState.claim()` single-resume guarantee is *extended* with a `.cancelled` case + `cancelRequested` flag + `launched` flag, so cooperative cancellation never adds a second continuation-resume site. The editable system prompt is **instructions-only** with the enforced contract (scoped `--allowedTools`, `method=create`, "Issue URL on last line") concatenated by `buildPrompt` outside the editable field and the CLI flags living entirely in `assembleCommand` — making the parse contract structurally impossible to break by editing instructions. Settings should be a **self-owned `NSWindow`/`NSWindowController` hosting SwiftUI**, NOT the SwiftUI `Settings` scene, because `showSettingsWindow:` was removed in macOS 14 and `SettingsLink`/`openSettings` are 14+ only — the self-owned window works identically across the macOS 13/14/15 range.

The dominant risk is **cancellation correctness across a multi-process tree**. `Process.terminate()` only signals the direct `/bin/zsh -lc` child; the real work is `zsh → claude → docker run --rm github-mcp-server`, so a naive terminate orphans `claude` and leaks Docker containers (defeating `--rm`). The milestone MUST terminate the whole process group (process-group kill, SIGTERM + grace before SIGKILL) and add `applicationShouldTerminate` cleanup for quit-with-jobs-in-flight. Secondary risks: `terminate()` on a not-yet-launched process throws an uncatchable `NSInvalidArgumentException` (guard with a lock-protected `launched` flag), and the existing `IssueResultParser` prose fallback grabs the first issue URL *anywhere* in output → false "created #N" once prompts are user-editable (harden to match the last URL / last line).

## Key Findings

### Recommended Stack

Additions only — the v1.0 stack (Swift 6, AVFoundation, KeyboardShortcuts, bundled whisper, `CLIRunner` over `Process`) is validated and unchanged. **No new third-party dependencies.** See STACK.md.

**Core technologies:**
- `withTaskCancellationHandler(operation:onCancel:)` — bridge cooperative Task cancellation to imperative `Process.terminate()`; the only correct way to react while suspended on a `withCheckedContinuation`.
- `NSStatusItem` + `NSPopover` + `NSMenu` (replacing `MenuBarExtra`) — gives left/right-click discrimination via `sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent`, which `MenuBarExtra` does not expose.
- Self-owned `NSWindow` + `NSWindowController` + `NSHostingController<SettingsView>` — programmatic Settings window that works on macOS 13/14/15 (avoids the removed `showSettingsWindow:` / 14-only `SettingsLink`).
- `@AppStorage` / `UserDefaults.standard` + `TextEditor` — persist + two-way bind the editable prompt, mirroring the existing `cliCommandKey` shared-constant pattern.
- `[UUID: Task<Void, Never>]` cancel-handle dictionary on `@MainActor` AppState — `Task` is Sendable; one unstructured tracked Task per concurrent filing (NOT a TaskGroup, which would block until all finish).

### Expected Features

The four feature areas are really **one model change + four UI surfaces**. See FEATURES.md.

**Must have (table stakes):**
- Decoupled `FilingJob` model + concurrent filing — capture returns to idle immediately; multiple filings run at once.
- Jobs list in the menu with per-job state (filing/done/failed/cancelled) + indeterminate spinner.
- Per-job Stop/Cancel that terminates the `claude` subprocess (and its tree) and cleans up.
- Per-job spoken outcome for success, failure, AND cancel (TTS is the primary feedback channel; the popover is usually closed).
- Visible recoverable error per failed job (RESIL-01) — row persists with message + transcript until dismissed.
- Settings window with editable system-prompt + Reset-to-Default; app still appends the enforced contract.
- Relocate the orphaned "CLI Command" field into Settings (FINDING-06).

**Should have (competitive):**
- Retry a failed job in place — reuses stored transcript+repo; avoids the worst voice-app UX (re-dictation). Nearly table-stakes.
- Menu-bar badge with active-job count; disambiguating subject hint in spoken confirmation; clear-completed/cancel-all.

**Defer (v2+):**
- `{{placeholder}}` prompt tokens (needs a validation guard); effective-prompt live preview.
- Persistent job history, concurrency-limit scheduler, Notification Center alerts (anti-features — overbuild for a single-user tool).
- Editing the enforced contract itself (would break the parse + security scoping).

### Architecture Approach

An **integration architecture**, not an ecosystem survey: graft v1.1 onto v1.0 while preserving the `RunState` single-resume invariant, the `onRunTranscription`/`onRunIssueFiling`/`onSpeak` test seams (signatures unchanged — the editable prompt is threaded via a *defaulted* `instructions:` param, not a new seam arg), and Swift 6 actor isolation (everything stays `@MainActor`; only off-actor surface is the lock-guarded `RunState`). See ARCHITECTURE.md.

**Major components:**
1. `FilingJob` (NEW value struct) + `@Published [FilingJob]` — the source of truth the popover renders; value semantics avoid the "array of ObservableObject doesn't republish" trap.
2. `CLIRunner` (MODIFIED) — adds `.cancelled` result, `withTaskCancellationHandler`, `RunState.requestCancel`/`cancelRequested`/`launched`/`attach(process)`; `claim()` untouched.
3. `IssueFilingRunner` (MODIFIED) — maps `.cancelled → CancellationError`; defaulted `instructions:` split from the enforced protocol trailer; `PromptTemplate` (NEW).
4. `AppDelegate` (MODIFIED) — owns `NSStatusItem`/`NSPopover`/`NSMenu`; one Combine `$filingJobs` sink → status badge (the only Combine→AppKit bridge); adds `applicationShouldTerminate` cleanup.

### Critical Pitfalls

Top risks from PITFALLS.md (12 total; all about what breaks when adding a 2nd concurrent job, user-cancel, AppKit UI, and editable prompt — preserve v1.0 invariants, don't re-derive them):

1. **`Process.terminate()` signals only the direct child** — `claude`/Docker subtree survives cancel/quit, leaking `--rm` containers. Kill the whole **process group** (SIGTERM + grace, SIGKILL only on the group after); add launch-time `make-an-issue-mcp-*.json` sweep. *Highest risk.*
2. **Cancel adds a 4th continuation-completion racer** — double-resume crash or leaked continuation (hung "Filing…"). Route cancel through the existing `RunState.claim()` slot; `onCancel` only flags + terminates, never resumes.
3. **`terminate()` before launch throws uncatchable `NSInvalidArgumentException`** — guard with a lock-protected `launched` bool (race-free where `isRunning` alone is not).
4. **Single `captureState` enum can't represent "idle + 3 jobs filing"** — the foundational refactor; do it first.
5. **Editable prompt silently breaks the parse contract / false confirmations** — instructions-only + enforced suffix; keep tool scope in CLI flags; harden the prose fallback to the **last** URL, not the first occurrence anywhere.

## Implications for Roadmap

All four research streams independently recommend the **same phase order**. The critical chain is `CLIRunner cancellation → IssueFilingRunner mapping → AppState cancelFiling → UI Stop`; the editable-prompt track runs parallel and merges at Settings. Because the jobs model underlies both cancellation and the UI, it comes first; cancellation is independent of the UI rewrite.

### Phase 1: Concurrent Filing Jobs Model (foundational refactor)
**Rationale:** Everything hangs off lifting filing out of the single `CaptureState` enum. Cannot be retrofitted after the UI is built on the wrong model (HIGH recovery cost).
**Delivers:** `FilingJob` value struct, `@Published [FilingJob]`, private `[UUID: Task]` handles, `enqueueFiling`/`cancelFiling`; `captureState` keeps only `idle/recording/transcribing` and returns to idle immediately after transcription. Preserves all three test seams.
**Addresses:** Background/concurrent filing; capture-during-filing; jobs-list data model.
**Avoids:** Pitfalls 4 (single-enum collision), 5 (Sendable/MainActor job-store), 12 (preserve UUID MCP tempfile isolation).
**Migration cost (flag):** intentionally rewrites serial-filing AppStateTests — `testFilingEntersFilingState`, `testPushToTalkDuringFilingIsIgnored` (CR-01 re-press is now *allowed* — the feature), `testStartRecordingAfterFilingReturnsToIdle`, and `.filing` assertions in `testSuccessfulTranscriptionStoresText`.

### Phase 2: Cancellation / Stop Control
**Rationale:** Per-job Stop requires real subprocess-tree termination, not just `Task.cancel()`. Independent of the UI rewrite; depends on the jobs model so handles exist to cancel.
**Delivers:** `CLIRunner` `.cancelled` case + `withTaskCancellationHandler` + `RunState` `cancelRequested`/`launched`/`attach(process)`; process-**group** kill (SIGTERM + grace → SIGKILL on group); `IssueFilingRunner` maps `.cancelled → CancellationError`; `applicationShouldTerminate` cleanup + launch-time tempfile sweep.
**Uses:** `withTaskCancellationHandler`, `Process.terminate()`, process-group signalling (STACK.md).
**Avoids:** Pitfalls 1 (process tree survives), 2 (double-resume/leak), 3 (terminate-before-launch crash), 6 (quit orphans).

### Phase 3: AppKit Status-Item UI + Settings Window Shell
**Rationale:** Structurally independent of 1–2 but sequenced after the jobs model so the popover has something to bind. The shell must exist before Settings content lands.
**Delivers:** Replace `MenuBarExtra` with `NSStatusItem` + left-click `NSPopover(MenuView)` + right-click `NSMenu`; self-owned `NSWindow`/`NSHostingController` Settings window; `$filingJobs` badge Combine sink; remove the `MenuBarExtra` `.onDisappear` hotkey workaround.
**Implements:** AppDelegate-owned status item; Combine→AppKit badge bridge.
**Avoids:** Pitfalls 7 (`.menu` disables popover), 8 (popover focus / lost edits — keep editor in the window, not the transient popover), 9 (macOS 13/14 Settings divergence — self-owned window sidesteps it), 10 (KeyboardShortcuts `.menuOpen` rebalance — re-tune, don't blindly carry over).

### Phase 4: Editable System Prompt + FINDING-06
**Rationale:** Depends on the Settings window (Phase 3) and the `instructions:` plumbing (Phase 2's IssueFilingRunner changes).
**Delivers:** `SettingsView` `TextEditor` bound to `@AppStorage(promptInstructionsKey)`; `PromptTemplate.current` (reads UserDefaults at invocation, falls back to default when blank); Reset-to-Default; relocate the orphaned "CLI Command" field (FINDING-06).
**Avoids:** Pitfall 11 (editable prompt breaks parse/tool contract) — instructions-only + enforced contract suffix appended by `buildPrompt`; flags stay in `assembleCommand`; harden `IssueResultParser` prose fallback to the last URL.

### Phase 5: Jobs List UI + Per-Job Stop + Surfaced Errors (RESIL-01)
**Rationale:** Depends on the model (Phase 1), cancellation (Phase 2), and the shell (Phase 3). Surfaces the work in the popover.
**Delivers:** `MenuView` renders `appState.filingJobs` with per-row Stop (`cancelFiling`), per-job spinner, and persistent `failed`-status error rows with message + transcript (RESIL-01). Stretch: retry-in-place, active-job badge, subject hint in confirmation.

### Phase Ordering Rationale
- **Model first** because the single-`captureState`→jobs refactor is load-bearing for every other feature and is the most expensive to retrofit.
- **Cancellation before UI** because it's the highest-risk, most-independent work and the UI Stop button needs a working cancel path underneath it.
- **Shell before Settings content** because the editable prompt needs a focusable window (a transient popover loses edits and can't take keyboard focus in an `LSUIElement` app).
- **Errors/jobs-list last** because they are pure presentation over models and seams the earlier phases already built.

### Research Flags

Phases likely needing deeper research during planning (`/gsd-plan-phase --research-phase`):
- **Phase 2 (Cancellation):** process-group plumbing is the one genuinely novel surface — Foundation `Process` doesn't expose `POSIX_SPAWN_SETPGROUP` directly; needs a `setsid`/`exec` prefix vs `posix_spawn` decision plus a leak-verification harness (`docker ps` / `pgrep -f claude`).
- **Phase 3 (AppKit shell):** verify the KeyboardShortcuts global hotkey survives popover/NSMenu open-close cycles with another app focused; confirm self-owned-window activation (`NSApp.activate` before `makeKeyAndOrderFront`) on the macOS 13 floor.

Phases with standard patterns (skip research-phase):
- **Phase 1 (jobs model):** value-model + handle-dict is a well-understood SwiftUI pattern, fully grounded in direct v1.0 source reads.
- **Phase 4 (editable prompt):** mirrors the existing `@AppStorage(cliCommandKey)` pattern exactly.
- **Phase 5 (jobs list UI):** straight SwiftUI list rendering over an existing `@Published` model.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All first-party APIs verified against Apple docs; self-owned-window recommendation cross-checked across 3 independent sources (steipete, rampatra, Apple Dev Forums). |
| Features | HIGH | Grounded in direct v1.0 source reads + established async-job UX patterns (LogRocket, AppMaster); single-user scope keeps the feature set tight. |
| Architecture | HIGH | Grounded in direct reads of v1.0 source + tests; concurrency APIs match patterns already in the codebase (timeout-arm `Process.terminate()` discipline). |
| Pitfalls | HIGH | Grounded in the actual v1.0 source (`RunState.claim()`, single-enum machine, parser contract); the one version-sensitive claim (macOS 13/14 Settings) is web-verified. |

**Overall confidence:** HIGH

### Gaps to Address
- **Process-group termination mechanism** — `setsid`/`exec`-prefix vs `posix_spawn` wrapper is an open implementation choice; resolve in Phase 2 planning with a leak-check spike (spawn, cancel, confirm no stray `claude`/Docker).
- **SIGTERM vs SIGINT for `claude`** — unverified which one cleanly stops an in-flight `claude -p`; test both during Phase 2.
- **KeyboardShortcuts hotkey behavior under NSPopover/NSMenu** — the `MenuBarExtra` workaround may fire spuriously or be unneeded; must be re-validated empirically in Phase 3, not assumed.
- **`applicationShouldTerminate` grace window** — pick a bounded cap (2–3s) then SIGKILL the groups; tune during Phase 2.

## Sources

### Primary (HIGH confidence)
- Direct v1.0 source + test reads: `AppState.swift`, `CLIRunner.swift` (`RunState.claim()`, timeout escalation), `IssueFilingRunner.swift` (UUID MCP tempfile, env-only token, `--allowedTools`), `IssueResultParser.swift`, `MenuView.swift`, `AppDelegate.swift`, `MakeAnIssueApp.swift`; `AppStateTests`, `CLIRunnerTests`, `IssueFilingRunnerTests`.
- Apple Developer Documentation — `NSStatusItem`, `withTaskCancellationHandler`, `Process` (terminate semantics + launched precondition), `withCheckedContinuation` single-resume diagnostics.

### Secondary (MEDIUM confidence)
- steipete.me "Showing Settings from macOS Menu Bar Items" (2025) — `showSettingsWindow:` removed in macOS 14; accessory-app activation dance. Cross-checked with rampatra blog + Apple Dev Forums 739831.
- LogRocket / AppMaster — async-job UX patterns (queued/running/succeeded/failed/cancelled schema, indeterminate progress, keep-working-while-running).
- Medium (clyapp) + isapozhnik.com — `NSStatusItem` left/right-click discrimination + transient-`.menu` caveat (corroborated across two posts).

### Tertiary (LOW confidence)
- `orchetect/SettingsAccess` — referenced only as the legacy-vs-native split reference; not adopted (no new dependencies).

---
*Research completed: 2026-06-28*
*Ready for roadmap: yes*
