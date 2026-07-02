# Feature Research — v1.1 Concurrent Filing & Control

**Domain:** Concurrent background-job UX for a voice-driven macOS menu-bar utility (TTS-primary feedback)
**Researched:** 2026-06-28
**Confidence:** HIGH
**Scope:** ONLY the v1.1 features — (a) background/concurrent filing + jobs list with cancel, (b) editable-system-prompt Settings pane, (c) cancellation feedback, (d) recoverable error surfacing. Single-user, local app. v1.0 happy-path features are out of scope here.

---

## Central Design Implication (read first)

Today, filing is welded into a **single shared `CaptureState` enum** on `AppState` (`.idle → .recording → .transcribing → .finished → .filing → .idle`). `startRecording()` deliberately guards `captureState == .idle` to **block** a new capture during the up-to-300s `.filing` window (the comment cites CR-01). Every v1.1 feature in this document depends on **lifting filing out of that single state machine** into a **collection of independent job objects**, while `captureState` reverts to `.idle` the moment transcription finishes.

This is the load-bearing change. Once filing is per-job:
- Concurrent filing falls out naturally (N jobs, each its own `Task`).
- The jobs list, per-job cancel, per-job error, and per-job retry all attach to a job object.
- TTS confirmation moves from "speak on the one filing's success" to "each job speaks its own outcome."

The four feature areas below are really **one model change + four UI surfaces on top of it.**

---

## Feature Landscape

### Table Stakes (Users Expect These)

Missing any of these makes concurrent filing feel broken or untrustworthy.

| Feature | Why Expected | Complexity | Notes / Dependency |
|---------|--------------|------------|--------------------|
| Capture returns to idle immediately after transcription | The whole point of v1.1 — dictate back-to-back without waiting | HIGH | Decouple filing from `CaptureState`; relax the `startRecording()` `== .idle` re-entry guard so a new capture can begin while jobs file in background |
| A jobs list in the menu, one row per in-flight/recent filing | Concurrency is invisible without it; users must see "3 issues filing" | MEDIUM | New `FilingJob` model (id, transcript snippet, state, startedAt, result/error) held in an `@Published [FilingJob]` on `AppState`; rendered as a section in `MenuView` |
| Per-job status state | Standard job schema: `filing` (running) / `done` (succeeded) / `failed` / `cancelled` | MEDIUM | Mirrors the canonical queued/running/succeeded/failed/cancelled schema; "queued" not needed if all jobs run concurrently |
| Indeterminate per-job progress (spinner, not %) | Filing has no real denominator (model reasoning + repo read + MCP call) — a fake % erodes trust | LOW | Reuse existing `ActivitySpinner`; step-based hint text ("Investigating repo…") is enough |
| Per-job Stop/Cancel control | Abort a bad/runaway filing without quitting the app | MEDIUM-HIGH | Must terminate the underlying `claude` subprocess, not just cancel the Swift `Task` — see dependency note. Each job's `Task` + `Process` handle must be cancellable |
| Spoken confirmation per completed job | TTS is the primary feedback channel; each job must announce its own result | LOW-MEDIUM | Reuse `speak(_:)`; `AVSpeechSynthesizer` already serializes queued utterances, so overlapping completions queue rather than clobber. Must disambiguate ("created issue #N") |
| Spoken outcome for failures and cancels | A silent failure in a voice app = the user never learns it failed | MEDIUM | v1.0 only speaks success; failures went to `statusText`. With background filing the menu may be closed, so failures/cancels MUST also speak (e.g. "issue filing failed", "filing cancelled") |
| Visible, recoverable error per failed job (RESIL-01) | A failed job can't just vanish; user needs to know which dictation was lost | MEDIUM | Failed job row stays in the list with its error message + the transcript that produced it, until dismissed |
| Editable system-prompt field in Settings | The stated v1.1 goal — let users tune how the AI drafts issues | MEDIUM | Feeds `IssueFilingRunner.buildPrompt`; app still appends the enforced contract (scoped tool grant + "Issue URL on last line"). Persist via `@AppStorage`/`UserDefaults` like `cliCommandKey` |
| Reset-to-default for the system prompt | Users will break the prompt and need an escape hatch | LOW | Ship the default prompt as a constant; "Reset to Default" restores it |
| Right-click / proper Settings window | A multi-line prompt editor doesn't fit the 320pt popover; needs real window | MEDIUM | Standard macOS `Settings`/`SettingsLink` scene or AppKit window; resolves FINDING-06 by relocating the orphaned "CLI Command" field here |

### Differentiators (Worth Doing, Not Strictly Required)

| Feature | Value Proposition | Complexity | Notes / Dependency |
|---------|-------------------|------------|--------------------|
| Retry a failed job in place | Filing fails often for transient reasons (network, MCP, Docker not running); re-running the same transcript is far better than re-dictating | MEDIUM | The failed `FilingJob` already holds its transcript + repo; "Retry" spawns a fresh job from the same inputs. High value because re-dictation is the worst UX in a voice app |
| Menu-bar icon/badge reflects active job count | Glanceable "2 filing" without opening the popover | LOW-MEDIUM | `MenuBarExtra` label can show a count or a working glyph; pairs with the idle/recording state already implied by `StateBadge` |
| Placeholder tokens in the system prompt (e.g. `{{transcript}}`, `{{repo}}`) | Lets power users control *where* the transcript/repo context lands instead of a fixed template | MEDIUM | Industry convention is `{{double_brackets}}` with descriptive names + validation highlight. Risk: if the user deletes `{{transcript}}` the issue has no content — needs a guard (see anti-features) |
| Spoken confirmation includes a hint of which issue | With concurrency, "created issue #N" alone is ambiguous about *which* dictation; a short subject hint disambiguates | LOW-MEDIUM | e.g. "created issue #42, login bug" — needs a short label per job (first words of transcript) |
| Live preview of the effective prompt | Show the assembled prompt (user text + enforced contract) so users see what actually runs | MEDIUM | Reduces "why didn't my edit work" confusion; reads from the same `buildPrompt` seam |
| Cancel-all / clear-completed affordance | Quality-of-life once several jobs accumulate | LOW | Bulk action over the jobs array |

### Anti-Features (Tempting, Out of Scope for v1.1)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Persistent job history across launches | "See everything I ever filed" | This is a single-user capture tool, not an issue tracker; GitHub already *is* the durable record. Adds storage, schema, migration, and pruning complexity | In-memory list for the current session only; the filed issue lives on GitHub |
| Bounded queue / concurrency limit / scheduler | "Don't overload my machine" | Real usage is a handful of back-to-back dictations, not hundreds; a scheduler is speculative complexity (CLAUDE.md §2). Each `claude` subprocess is heavy but few | Run all jobs concurrently; revisit only if real use shows resource pain |
| Multi-microphone / simultaneous capture | "Record two things at once" | Capture is inherently push-to-talk and serial — one mouth, one hotkey. Concurrency is about *filing*, not *capture* | Keep capture serial; only filing is concurrent |
| Full prompt versioning / history / diff UI | Mirrors hosted prompt-studio tools | Enterprise-grade auditability for a personal menu-bar app; massive overbuild | Single editable prompt + "Reset to Default" constant |
| Editing the enforced contract (tool grant, URL-on-last-line) | "Total control of the prompt" | Breaks the parse contract (`IssueResultParser`) and the security scoping (`--allowedTools`, `--strict-mcp-config`); a broken contract silently breaks filing | Expose **instructions only**; app always appends the enforced suffix (already the stated v1.1 boundary) |
| Pause/resume a filing job | Parallel to download managers | A `claude -p` subprocess can't be paused/resumed; only run or kill | Cancel (terminate) + Retry (fresh run) |
| Automatic retry with backoff | "Just make it work" | PROJECT.md explicitly defers retries/queuing to beyond v1; auto-retry can spam GitHub with duplicate issues if a filing actually half-succeeded | Manual, user-initiated Retry on a visibly failed job |
| Rich per-job progress percentage | "Show me how far along" | No honest denominator exists; a fake bar that jumps to 90% and hangs is worse than a spinner | Indeterminate spinner + step text |
| Toast/notification-center alerts per job | "Native notifications" | Adds a notification-permission surface and competes with the TTS channel; the menu list + speech already cover it | Jobs list + spoken outcome; consider Notification Center only if TTS proves insufficient |

---

## Feature Dependencies

```
Decouple filing from CaptureState  ──(enables)──>  Concurrent background filing
        │                                                   │
        │                                                   ├──> Jobs list in MenuView
        │                                                   │         ├──> Per-job Stop/Cancel ──requires──> cancellable Task + subprocess termination (CLIRunner)
        │                                                   │         ├──> Per-job error row (RESIL-01)
        │                                                   │         │         └──enhanced by──> Retry-in-place (reuses job's transcript+repo)
        │                                                   │         └──> Clear-completed / cancel-all
        │                                                   └──> Per-job spoken outcome (success / failure / cancel) ──uses──> speak()/AVSpeechSynthesizer queue
        │
Relax startRecording() == .idle guard ──required by──> capture-during-filing

Settings window (right-click)  ──hosts──> editable system prompt ──feeds──> IssueFilingRunner.buildPrompt (app appends enforced contract)
        │                                         └──needs──> Reset-to-Default constant
        └──relocates──> orphaned "CLI Command" field (FINDING-06)

editable system prompt ──optionally enhanced by──> {{placeholder}} tokens ──needs──> validation guard (transcript token must survive)
```

### Dependency Notes

- **Concurrent filing requires decoupling from `CaptureState`:** `.filing` is currently one state in a single shared enum; N concurrent filings can't be represented by one enum value. Introduce a `FilingJob` model + `@Published [FilingJob]`; `captureState` keeps only `.idle/.recording/.transcribing` and returns to `.idle` after `beginTranscription` hands off to a new job.
- **Capture-during-filing requires relaxing the re-entry guard:** `startRecording()`'s `guard captureState == .idle` plus the CR-01 comment exists *specifically* to block this. That guard must be rewritten so a new capture can start while jobs are mid-flight (it still blocks double-recording).
- **Per-job cancel requires real subprocess termination:** cancelling the Swift `Task` is not enough — the heavy work is the `claude` subprocess spawned by `CLIRunner`. `CLIRunner`/`IssueFilingRunner` must expose a cancel that sends `SIGTERM`/`SIGKILL` to the `Process` and cleans up its MCP tempfile (the `defer` cleanup must still fire on cancel). **Open question for requirements: does the current `CLIRunner` observe `Task.isCancelled` / hold a killable `Process` handle?** If not, that plumbing is the bulk of the cancel work.
- **Spoken outcomes depend on the menu being closeable:** v1.0 surfaced failures only in `statusText` (visible only with the popover open). With background filing the popover is usually closed, so failure/cancel MUST also use the TTS channel, not just text.
- **Editable prompt feeds `buildPrompt` but must not replace the contract:** `IssueFilingRunner.buildPrompt` hard-codes the steps + "Issue URL on the LAST line" + tool name. The user's text replaces the *instructional* body; the app must still append the enforced steps/format so `IssueResultParser` keeps working.
- **Placeholder tokens conflict with prompt freedom:** if `{{transcript}}` is a token and the user deletes it, the model gets no transcript. A validation guard (or always-append-transcript fallback) is required before shipping tokens — which is why tokens are a differentiator, not table stakes.

---

## MVP Definition (for the v1.1 milestone)

### Must Ship (v1.1 core)

- [ ] **Decoupled `FilingJob` model + concurrent filing** — capture returns to idle immediately; multiple filings run at once. *The enabling change; everything else hangs off it.*
- [ ] **Jobs list in the menu** with per-job state (filing/done/failed/cancelled) and an indeterminate spinner.
- [ ] **Per-job Stop/Cancel** that terminates the `claude` subprocess and cleans up.
- [ ] **Per-job spoken outcome** for success, failure, AND cancel (TTS is primary feedback).
- [ ] **Visible recoverable error per failed job (RESIL-01)** — row persists with message + transcript until dismissed.
- [ ] **Settings window with editable system prompt + Reset-to-Default**, app still appends the enforced contract.
- [ ] **Relocate the orphaned "CLI Command" field into Settings (FINDING-06)** — wire it through or remove it.

### Add If Cheap (v1.1 stretch)

- [ ] **Retry a failed job in place** — high user value (avoids re-dictation), reuses stored transcript+repo. Strongly recommended; nearly table-stakes for a voice app.
- [ ] **Menu-bar badge with active job count** — glanceable concurrency.
- [ ] **Disambiguating hint in spoken confirmation** ("created issue #N, <subject>").
- [ ] **Clear-completed / cancel-all** bulk action.

### Defer (post-v1.1)

- [ ] **`{{placeholder}}` tokens in the prompt** — needs a validation guard; ship the plain editable prompt first.
- [ ] **Effective-prompt live preview** — nice transparency once the editor exists.
- [ ] **Persistent job history, scheduler/queue limits, notifications** — see anti-features.

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Decouple filing from CaptureState (concurrency) | HIGH | HIGH | P1 |
| Jobs list with per-job state + spinner | HIGH | MEDIUM | P1 |
| Per-job cancel (terminate subprocess) | HIGH | MEDIUM-HIGH | P1 |
| Per-job spoken outcome (success/fail/cancel) | HIGH | MEDIUM | P1 |
| Recoverable error per failed job (RESIL-01) | HIGH | MEDIUM | P1 |
| Settings window + editable prompt + reset | HIGH | MEDIUM | P1 |
| Relocate "CLI Command" field (FINDING-06) | MEDIUM | LOW | P1 |
| Retry failed job in place | HIGH | MEDIUM | P2 |
| Menu-bar active-job badge | MEDIUM | LOW-MEDIUM | P2 |
| Spoken confirmation subject hint | MEDIUM | LOW-MEDIUM | P2 |
| `{{placeholder}}` prompt tokens | MEDIUM | MEDIUM | P3 |
| Effective-prompt preview | LOW-MEDIUM | MEDIUM | P3 |

**Priority key:** P1 must have for v1.1; P2 should have, add when cheap; P3 future.

## Dependencies on Existing v1.0 Components

| Existing component | What v1.1 changes / depends on |
|--------------------|-------------------------------|
| `AppState.CaptureState` enum | `.filing` lifts out into a per-job model; enum keeps only `.idle/.recording/.transcribing` (`.finished` transient) |
| `AppState.startRecording()` `== .idle` guard | Must be relaxed so capture can start while jobs file in background (the CR-01 block is intentionally removed for filing) |
| `AppState.beginFiling()` | Becomes "spawn a `FilingJob`" instead of mutating shared state; no longer flips `captureState` to `.filing` |
| `AppState.speak(_:)` / `AVSpeechSynthesizer` | Reused for per-job outcomes; relies on the synthesizer's serial utterance queue for overlapping completions; now also speaks failures/cancels |
| `AppState.message(for: IssueFilingError)` | Reused to render per-job error rows + spoken failure text |
| `IssueFilingRunner.buildPrompt` | Takes the user's editable instruction text; app appends enforced steps + URL-on-last-line contract |
| `IssueFilingRunner.file` / `CLIRunner` | Needs a cancellation path that kills the `claude` `Process` and still runs the MCP-tempfile `defer` cleanup — **verify current cancel support in requirements** |
| `MenuView` (320pt popover, `DisclosureGroup` settings) | Gains a jobs-list section; the inline settings disclosure (incl. orphaned "CLI Command" `TextField`) moves to a dedicated Settings window |
| `@AppStorage(cliCommandKey)` pattern | Reused to persist the editable system prompt and relocate the CLI command |

## Sources

- [LogRocket — UI patterns for async workflows, background jobs, and data pipelines](https://blog.logrocket.com/ux-design/ui-patterns-for-async-workflows-background-jobs-and-data-pipelines/) — job state schema (queued/running/succeeded/failed/cancelled), unique job ID + immediate "task started" row, step-based vs percent progress
- [AppMaster — Background tasks with progress updates: UI patterns that work](https://appmaster.io/blog/background-tasks-progress-ui) — job-card UI with safe Cancel, keep-working-while-running pattern
- [Apple Developer — Managing ongoing background processes in your Mac](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac) — visible UI element signals continued background work
- [Requesty — Customize Your System Prompt in the UI](https://www.requesty.ai/blog/how-to-customize-your-system-prompt-in-the-requesty-ui) — editable prompt + reset/restore patterns
- [AnythingLLM — System Prompt Variables](https://docs.anythingllm.com/features/system-prompt-variables) and [Anthropic — Prompt templates and variables](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/prompt-templates-and-variables) — `{{double_bracket}}` placeholders, descriptive names, default values, validation highlight
- Existing v1.0 source read directly: `AppState.swift`, `MenuView.swift`, `IssueFilingRunner.swift`, `PROJECT.md` — for dependency mapping

---
*Feature research for: make-an-issue v1.1 Concurrent Filing & Control*
*Researched: 2026-06-28*
