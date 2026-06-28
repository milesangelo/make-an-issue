# Pitfalls Research

**Domain:** Swift 6 macOS menu-bar app — adding concurrent subprocess jobs, cooperative cancellation, and an AppKit NSStatusItem/NSPopover settings UI to make-an-issue v1.1
**Researched:** 2026-06-28
**Confidence:** HIGH (pitfalls are grounded in the actual v1.0 source — `CLIRunner.RunState.claim()`, `AppState` single-enum state machine, `IssueFilingRunner`/`IssueResultParser` parse contract, `MenuView.onDisappear` KeyboardShortcuts workaround; the one version-sensitive API claim — Settings-window opening on macOS 13 vs 14 — is web-verified)

> Scope note: v1.0 already solved the *single-job* subprocess concurrency problems correctly (safe concurrent pipe drain, single-resume `claim()`, timeout→SIGTERM→SIGKILL escalation, per-invocation UUID MCP tempfile, `--allowedTools` scoping as a CLI flag). Every pitfall below is about what **breaks when you add a second concurrent job, a user-driven cancel, an AppKit UI, and an editable prompt** on top of that foundation. Do not re-derive the v1.0 invariants — *preserve* them.

## Critical Pitfalls

### Pitfall 1: `Process.terminate()` only signals the direct child — the `claude`/`docker` subtree survives cancel and quit

**What goes wrong:**
Cancelling a filing job (or quitting the app mid-flight) calls `process.terminate()` / `kill(pid, SIGKILL)` on the `/bin/zsh -lc` process that `CLIRunner` launched. But the real work is a process *tree*: `zsh → claude → docker run -i --rm ghcr.io/github/github-mcp-server`. SIGTERM/SIGKILL to the receiving process does **not** propagate to grandchildren. The `claude` process and especially the **Docker container** keep running after "Cancel" returns success. SIGKILL is the worst offender: killing the `docker run` client with SIGKILL leaves the daemon-owned container running and the `--rm` cleanup never happens → leaked containers accumulate.

**Why it happens:**
`Process.terminate()` is documented to send SIGTERM to *the receiver only*. The existing v1.0 timeout path (`CLIRunner` line 167/183) was written for the **bundled whisper-cli**, which is a single leaf process that respects SIGTERM — so terminate()+SIGKILL was sufficient there. The AI-CLI filing path is a multi-process tree the same code now drives, and the assumption silently breaks.

**How to avoid:**
- Launch each filing job's subprocess in its **own process group** so the whole tree can be signalled at once. Foundation `Process` does not expose this directly; either (a) prefix the command so the leader calls `setsid`/`exec` and signal the negative PGID via `kill(-pgid, SIGTERM)`, or (b) move to the newer `Subprocess` API / a small `posix_spawn` wrapper that sets `POSIX_SPAWN_SETPGROUP`. Do **not** `kill(-pgid)` without a fresh group — the app shares its group and you'll signal yourself.
- For cancel, **prefer SIGTERM and a grace period over SIGKILL** so `docker run --rm` and `claude` tear down cleanly (SIGKILL orphans the `--rm` container). Only escalate to SIGKILL on the *group* after the grace window, mirroring the existing 2s escalation but targeting `-pgid`.
- Verify cleanup with a leak check (see "Looks Done But Isn't").

**Warning signs:**
`docker ps` shows lingering `github-mcp-server` containers after cancels/quits; `pgrep -f claude` shows survivors; `/tmp/make-an-issue-mcp-*.json` files accumulate (the `defer` cleanup in `IssueFilingRunner.file` never runs when the Swift Task is torn down by a killed parent).

**Phase to address:** Cancellation / Stop-control phase (process-group plumbing in `CLIRunner`), reused by the Quit-cleanup work.

---

### Pitfall 2: The cancel path adds a 4th continuation-completion racer — get it wrong and you double-resume or leak the continuation

**What goes wrong:**
Cooperative cancellation must terminate the `Process` from *outside* the `withCheckedContinuation`. That introduces a fourth path that can resolve the run, racing the three v1.0 paths (`terminationHandler`, timeout `Task`, spawn-failure). Two failure modes:
1. **Double-resume** — the cancel handler resumes the continuation *and* the `terminate()` it issued makes `terminationHandler` fire and resume again → `SWIFT_ABORT` "continuation resumed twice".
2. **Leaked continuation** — the cancel handler terminates but resumes *nothing*, trusting `terminationHandler` to do it; if the process is already a zombie / terminate fails, `terminationHandler` never fires → `withCheckedContinuation` logs "leaked its continuation" and the awaiting job Task hangs forever (stuck "Filing…").

**Why it happens:**
`CLIRunner.run` today has **no `Task.isCancelled` awareness at all** — it only self-terminates on its own timeout. Bolting cancellation on naively (e.g. checking `Task.isCancelled` in a loop, or calling `continuation.resume` from a `withTaskCancellationHandler` handler) bypasses the `claim()` invariant that makes single-resume safe.

**How to avoid:**
- Wrap the continuation in `withTaskCancellationHandler`. In the cancellation handler, **reuse the existing `RunState.claim()` slot exactly like the timeout path does** (CLIRunner lines 166–170): `guard state.claim() != nil else { return }` → detach handlers → `terminate()` the group → `continuation.resume(returning: .cancelled)`. Because `claim()` is "first caller wins, all others get nil," the subsequent `terminationHandler` calls `claim()`, gets `nil`, and safely no-ops. This is the *same* proven mechanism — extend it, don't replace it.
- Add a new `CLIResult.cancelled` case (parallel to `.timeout`) so callers can distinguish user-cancel from timeout/failure for UI.
- The cancellation handler is `@Sendable` and runs on an arbitrary thread: it may touch **only** `RunState` (already `@unchecked Sendable` + `NSLock`) and the `Process`. It must not touch `@MainActor` state.

**Warning signs:**
Debug console prints "SWIFT TASK CONTINUATION MISUSE: … leaked its continuation" or a fatal "continuation resumed twice"; a cancelled job's spinner never clears.

**Phase to address:** Cancellation / Stop-control phase.

---

### Pitfall 3: `process.terminate()` on a not-yet-launched `Process` throws `NSInvalidArgumentException` ("task not launched") and crashes

**What goes wrong:**
Cancel-before-launch race: a job's Task is cancelled in the window between `Process()` construction and `try process.run()` (CLIRunner lines 82–147), or before `run()` is even reached (e.g. user hammers Stop the instant they fire a job). The cancellation handler calls `process.terminate()` on a process that was never launched → Foundation raises an Objective-C `NSInvalidArgumentException` that is **not** catchable as a Swift `throw` and hard-crashes the app.

**Why it happens:**
`Process.terminate()` (and `interrupt()`, `suspend()`) precondition that the task is running; v1.0 never terminated a process it hadn't already `run()`. The cancel feature is the first code path that can fire before launch.

**How to avoid:**
- Track launch state under the existing lock: add a `launched` bool to `RunState`, set it `true` under the lock immediately after a successful `process.run()`. The cancellation/terminate path must `claim()` and then only call `terminate()`/`kill` **if `launched` is true**; if it claims before launch, just resume `.cancelled` and ensure `run()` is skipped (or guard `run()` with `Task.isCancelled` / the claimed flag so it never launches a process for an already-cancelled job).
- Equivalently, guard every signal call with `process.isRunning` — but the lock-protected `launched` flag is race-free where `isRunning` alone is not.

**Warning signs:**
Crash log: `*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'task not launched'`. Reproduces only under fast cancel / CI stress, not in casual manual testing.

**Phase to address:** Cancellation / Stop-control phase.

---

### Pitfall 4: Concurrent filing breaks the single `CaptureState` enum — jobs collide on one shared state variable

**What goes wrong:**
v1.0 models the entire pipeline as one `AppState.captureState: CaptureState` (`.idle/.recording/.transcribing/.finished/.filing`). `startRecording()` (AppState line 179) guards `captureState == .idle`, and `.filing` deliberately blocks a new capture (the CR-01 comment). The whole point of v1.1 is "after transcription, return to idle immediately and file in the background; multiple filings run at once." If you keep filing inside `captureState`, you get one of two broken behaviors: either a second filing is blocked (no concurrency, milestone not met), or you flip `captureState` back to `.idle` while a job runs and the single enum can no longer represent "idle + 3 jobs filing," so the UI badge, the Stop button, and per-job confirmations all read the wrong state.

**Why it happens:**
The single-enum state machine was correct and even *load-bearing* for the v1.0 serial design (it's how re-entrancy is prevented). Concurrency is a structural change: filing is no longer a *state of the app*, it's a *set of independent jobs*.

**How to avoid:**
- Split the model: `captureState` keeps owning only **recording/transcribing** (the genuinely-serial mic stage, still single because there's one microphone), and introduce a separate **`jobs` collection** (e.g. `@Published var jobs: [FilingJob]` or `[UUID: FilingJob]`) where each `FilingJob` carries its own status (`.filing/.succeeded/.failed/.cancelled`), its own `Task` handle, and its own result/error.
- After a successful transcript, transition `captureState` back to `.idle` **and** append a new `FilingJob` — so the next push-to-talk works immediately (this is the milestone's core behavior).
- Each job speaks its own "created issue #N" on completion; drive the menu-bar/popover UI from `jobs`, not from a single badge.

**Warning signs:**
Second push-to-talk is silently ignored while a filing runs; the status badge flickers between FILING and IDLE; confirmations announce the wrong issue number; `beginFiling()`'s `guard captureState == .filing` logic stops making sense.

**Phase to address:** Concurrent/Background Filing phase (this is the foundational refactor that phase must do first).

---

### Pitfall 5: Storing per-job `Task` handles + `Process` cancel hooks across the `@MainActor`/`@Sendable` boundary trips Swift 6 strict concurrency

**What goes wrong:**
To cancel a specific in-flight job you must store its `Task<…>` (and reach its underlying `Process`) on the `@MainActor` `AppState`. Two Swift-6 traps: (a) storing/iterating non-`Sendable` types (a raw `Process`, or a class without `Sendable`) in MainActor state that a `@Sendable` cancellation closure also captures → "capture of non-Sendable type in @Sendable closure" errors or, worse, an actual data race; (b) the job's completion closure currently hops with `await MainActor.run { … }` (AppState lines 273–294) — if you cancel by mutating the `jobs` dictionary from a non-isolated context you violate actor isolation.

**Why it happens:**
v1.0 only ever stored `recordingTimeoutTask` (a `Task<Void, Never>`, which *is* Sendable) and never needed to reach into a running `Process` from elsewhere. The cancel feature is the first time MainActor UI state and an off-actor process-control handle must share a reference.

**How to avoid:**
- Keep the cancellable surface `Sendable` and lock-backed: the cancel hook a job exposes should be the existing `RunState`-style object (`@unchecked Sendable` + `NSLock`), **not** a bare `Process`. The MainActor stores the `Task` handle (Sendable) and a `Sendable` cancel token; `task.cancel()` flows through `withTaskCancellationHandler` into the lock-guarded terminate (Pitfalls 2/3). Cancellation never touches `@Published` state directly — it resolves the run, and the job's normal completion path hops back to MainActor to update `jobs`.
- Mutate the `jobs` collection only on the MainActor.
- Use `[weak self]` in every job Task closure exactly as v1.0 does for the recorder/KeyboardShortcuts closures (the WR-03 retain-cycle rationale), or the `jobs` dictionary will pin `AppState` and every `FilingJob` for the process lifetime.

**Warning signs:**
Swift 6 build errors mentioning `Sendable`/`@Sendable` capture; `-strict-concurrency=complete` warnings on the jobs store; TSan data-race reports on the jobs dictionary.

**Phase to address:** Concurrent/Background Filing phase (jobs model), tightened in the Cancellation phase.

---

### Pitfall 6: Quitting the app with jobs in flight orphans `claude`/`docker` and leaks MCP tempfiles — there's no `applicationShouldTerminate` cleanup

**What goes wrong:**
When the user quits (or the app is killed), in-flight filing subprocess trees are **reparented to launchd and keep running** (Pitfall 1's tree, including Docker containers). Because the Swift Task tearing down doesn't run synchronous cleanup, `IssueFilingRunner.file`'s `defer { removeItem(tempURL) }` (line 147) never executes → `/tmp/make-an-issue-mcp-*.json` files leak, each containing the MCP server config.

**Why it happens:**
v1.0 was serial and short; there was rarely an in-flight job at quit, and `AppDelegate` has no `applicationShouldTerminate`. Concurrent background filing makes "quit while N jobs run" the *normal* case.

**How to avoid:**
- Implement `applicationShouldTerminate(_:)` in `AppDelegate`: cancel all `jobs` (SIGTERM the process groups — Pitfall 1), return `.terminateLater`, and call `reply(toApplicationShouldTerminate: true)` after a short bounded grace period so Docker `--rm`/`claude` can tear down. Avoid an unbounded wait — cap it (e.g. 2–3s) then SIGKILL the groups and proceed.
- Sweep stale `make-an-issue-mcp-*.json` from the temp dir on launch as a backstop for files leaked by hard kills.

**Warning signs:**
After quitting with a job running: `docker ps` shows survivors, Activity Monitor shows orphaned `claude`, temp dir fills with MCP json. The MCP tempfile contains no secret (token is passed via env, not the file — good v1.0 decision), but it is still litter.

**Phase to address:** Cancellation / Stop-control phase, or a dedicated App-lifecycle/Quit-cleanup slice.

---

### Pitfall 7: `NSStatusItem.menu` vs button-action — setting `.menu` silently disables left-click→popover

**What goes wrong:**
The plan is left-click → `NSPopover` (status/jobs UI) and right-click → `NSMenu`. The naive approach sets `statusItem.menu = someMenu`. Setting `.menu` makes AppKit handle **all** clicks by opening that menu and **never fires `button.action`** — so the left-click popover never appears, and the existing `KeyboardShortcuts.Recorder` / SwiftUI content is unreachable.

**Why it happens:**
`NSStatusItem` has two mutually-exclusive interaction models: assign `.menu` (AppKit owns clicks) *or* assign `button.target/action` (you own clicks). They don't compose; `.menu` wins.

**How to avoid:**
- Do **not** set `statusItem.menu`. Set `statusItem.button.action`/`target` and `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`.
- In the action, branch on `NSApp.currentEvent`: right-click is `.rightMouseUp` **or** `.leftMouseUp` with `.control` modifier (Control-click must count as right-click). For right-click, build the menu on the fly and `statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil` (assign-popUp-clear), or use `button.menu` + `NSMenu.popUp(positioning:)`. For left-click, toggle the `NSPopover` anchored to `statusItem.button`.
- Store the `NSStatusItem` in a **strong** property on the AppDelegate/owner — a local var gets released and the icon never appears or vanishes mid-session.

**Warning signs:**
Left-click does nothing / always shows the menu; the status icon disappears seconds after launch (released status item); Control-click behaves like left-click.

**Phase to address:** AppKit status-item UI phase.

---

### Pitfall 8: `NSPopover` from an `LSUIElement` app doesn't get keyboard focus — the editable-prompt text editor is unresponsive; transient popovers eat in-progress edits

**What goes wrong:**
Two distinct failures: (a) An `NSPopover` shown from a background/accessory (`LSUIElement`) menu-bar app does **not** make the app active, so SwiftUI `TextField`/`TextEditor` and the `KeyboardShortcuts.Recorder` inside it **won't receive keystrokes** — the user clicks the prompt field and can't type. (b) A `.transient` popover auto-dismisses on any outside click; if the user is editing the multi-line system prompt and focus shifts (or they click another app to copy text), the popover closes and **in-progress edits are lost**.

**Why it happens:**
macOS won't let a window become key when the app has no Dock icon unless you explicitly activate it. And `NSPopover` `.transient`/`.semitransient` behaviors are designed for ephemeral glanceable content, not for hosting a text editor the user dwells in.

**How to avoid:**
- When showing any popover that contains editable fields or the shortcut recorder, call `NSApp.activate(ignoringOtherApps: true)` (and on macOS 14+ consider `NSApp.activate()` semantics) right before/after `popover.show(...)`.
- **Do not put the editable system prompt in a transient popover at all.** The prompt editor belongs in the real **Settings window** (a proper, focusable, persistent window) — keep the popover for status + jobs + Stop buttons only. This matches the milestone's "right-click Settings *window*" wording.
- Use `.applicationDefined`/programmatic dismissal (or an event monitor) rather than `.transient` if any popover must hold focus.

**Warning signs:**
Clicking the prompt field shows a caret but typing does nothing (or types into the previously-focused app); the shortcut Recorder won't capture; the popover vanishes the moment the user clicks to select text.

**Phase to address:** AppKit status-item UI phase (popover/activation) + Editable-system-prompt phase (put the editor in the Settings window).

---

### Pitfall 9: Opening the SwiftUI `Settings` window from a menu-bar app differs sharply between macOS 13 and 14 — the v1.0 floor is macOS 13

**What goes wrong:**
There is **no single API** that opens the SwiftUI `Settings` scene across this app's deployment range (macOS 13.0+). macOS 14 (Sonoma) **removed** the `NSApp.sendAction(Selector(("showSettingsWindow:")), …)` path that works on macOS 13; macOS 14 introduces `SettingsLink` and the `openSettings` environment action, **neither of which exists on macOS 13**. Pick one and it breaks on the other OS. On *both* OSes, opening Settings from an `LSUIElement`/accessory app is unreliable: the window appears behind other apps or never becomes key, and text fields don't get focus — unless you juggle activation policy and add timing delays.

**Why it happens:**
Apple changed the Settings-opening mechanism between Ventura and Sonoma and never provided a back-deployable replacement; the menu-bar/accessory case was not designed for. v1.0 used `MenuBarExtra` and never opened a separate Settings window, so this surface is brand-new in v1.1.

**How to avoid:**
- Branch by OS: on **macOS 14+** use `SettingsLink` / `@Environment(\.openSettings)`; on **macOS 13** fall back to the legacy `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`. (The community `SettingsAccess` package wraps exactly this split if you prefer a dependency over hand-rolling.)
- For the accessory-app focus problem, wrap the open in the documented dance: temporarily switch `NSApp.setActivationPolicy(.regular)`, `NSApp.activate(ignoringOtherApps: true)`, open Settings, then `makeKeyAndOrderFront`/`orderFrontRegardless` on the discovered settings window, and restore `.accessory` when it closes. Expect to need a ~100ms pre-delay and ~200ms post-delay for the window to initialize.
- Keep a `Settings { SettingsView() }` scene in `MakeAnIssueApp.body` so the scene exists at all once `MenuBarExtra` is removed — an AppKit-only `NSStatusItem` app still needs a Scene in `body`.

**Warning signs:**
Settings menu item does nothing on one OS but works on the other; the Settings window opens behind the frontmost app or without focus; "showSettingsWindow:" logs `unrecognized selector` on macOS 14.

**Phase to address:** AppKit status-item UI phase (Settings-window plumbing), validated on **both** macOS 13 and 14.

---

### Pitfall 10: Replacing `MenuBarExtra` rebalances the KeyboardShortcuts `.menuOpen` global-hotkey workaround — re-tune it, don't blindly carry it over

**What goes wrong:**
v1.0 has a load-bearing hack in `MenuView.onDisappear` (lines 104–113): it posts `NSMenu.didEndTrackingNotification` manually because `MenuBarExtra(.window)` fires `didBeginTracking` with **no balanced `didEndTracking`**, so KeyboardShortcuts believes a menu is still open, stays in focus-only local-monitor mode, and **push-to-talk stops firing while another app is focused**. When you delete `MenuBarExtra` and introduce a real `NSStatusItem` + `NSPopover` + `NSMenu`, the tracking-notification balance changes:
- A real **`NSMenu`** posts *genuine, balanced* `didBeginTracking`/`didEndTracking` — so KeyboardShortcuts correctly pauses during right-click menu tracking and resumes after. Carrying over the *manual* `didEndTracking` post can now fire it **spuriously** (un-pausing the hotkey *while the menu is still open*, or posting an unbalanced end), reintroducing the very flapping it was meant to fix.
- An **`NSPopover`** posts **no** `NSMenu` tracking notifications at all, so the old `onDisappear` hook won't fire from the popover — and you may not need it there, but you must re-verify the hotkey survives a popover open/close cycle.

**Why it happens:**
The workaround was reverse-engineered against `MenuBarExtra`'s specific (buggy) tracking behavior. The new AppKit components have *different* tracking semantics, so the same hack has a different — possibly harmful — effect.

**How to avoid:**
- Treat the workaround as **provisional** in the rewrite: remove the manual `didEndTracking` post first, then test global push-to-talk (a) while the popover is open, (b) while the right-click `NSMenu` is open, (c) after each closes, **with another app focused**. Only re-add a manual notification if a real imbalance is observed, and only on the exact component that causes it.
- Add a regression check to the UAT: "hold push-to-talk with Finder focused after opening then closing the menu/popover — recording must start."

**Warning signs:**
Push-to-talk works only when the app is focused after interacting with the menu/popover; or the hotkey fires *during* menu tracking when it shouldn't; intermittent "hotkey dead until I click the menu bar icon again."

**Phase to address:** AppKit status-item UI phase (must explicitly re-validate the global-hotkey interaction, not assume the hack ports).

---

### Pitfall 11: The editable system prompt silently breaks the issue-URL parse contract (and can make confirmations *lie*)

**What goes wrong:**
`IssueResultParser` depends on a precise contract that `IssueFilingRunner.buildPrompt` injects: file via the MCP tool with `method=create`, **don't ask for confirmation**, and **"On the LAST line output ONLY `Issue URL: https://github.com/<owner>/<repo>/issues/<NUMBER>`"**. If the Settings UI lets the user edit the *whole* prompt, they can delete the last-line directive or the "file it directly" instruction. Failure modes:
1. Model omits the URL line → structured tool_result parse may also miss → `IssueParseError.noIssueFound` → user hears nothing / sees "Couldn't confirm an issue was filed" on **every** job even though issues may actually be created.
2. Model asks for confirmation instead of filing → nothing is filed, but exit code 0 → `parseFailed`.
3. **Worse — false confirmation:** `IssueResultParser.extractFromProseText` (lines 139–148) regex-matches *any* `github.com/.../issues/N` URL anywhere in the result text. If an edited prompt encourages the model to "reference related issues," and the model mentions an **existing** issue URL while the new-issue tool_result parse fails, the prose fallback grabs the **wrong, pre-existing** number → the app speaks "created issue #5" for an issue it didn't create.

**Why it happens:**
v1.0's prompt was a fixed string co-designed with the parser. Making it user-editable severs that coupling unless the contract is structurally protected. The prose-regex fallback was a v1.0 safety net that becomes a liability when prompt content is user-controlled.

**How to avoid:**
- Make the editable field **instructions-only** (exactly as PROJECT.md states). Architecturally: `finalPrompt = userInstructions + appendedNonNegotiableContractBlock`. The user can never remove or precede the enforced suffix (the last-line `Issue URL:` directive + `method=create` + "file directly, don't ask").
- Keep the **tool grant out of the prompt entirely** — it's already a CLI flag (`--allowedTools mcp__github__issue_write Read Grep Glob`, `--strict-mcp-config`) in `assembleCommand`. Editing the prompt must not be able to widen tool scope. Preserve this; never move tool-scoping into editable text.
- Harden the parser against false positives now that prompt text is user-controlled: prefer the structured `tool_result` URL; for the prose fallback, match only the **last** URL / the URL on the **last line**, not the first occurrence anywhere.
- Consider a "Restore default prompt" affordance and a lightweight validation that warns if the user's instructions look like they'd conflict (optional).

**Warning signs:**
After a prompt edit, every filing reports `parseFailed`/`noIssueFound`; or spoken confirmations cite issue numbers that don't match what's actually on GitHub; duplicate issues appear (model filed but app reported failure, user retried).

**Phase to address:** Editable-system-prompt phase (contract-preservation architecture + parser hardening).

---

### Pitfall 12: Concurrent jobs are fine on the UUID MCP tempfile — but reverting to a fixed name, or sharing one `gh`/`AVSpeechSynthesizer`, reintroduces collisions

**What goes wrong:**
v1.0 already writes a **per-invocation** MCP tempfile with a `UUID()` suffix (`IssueFilingRunner` line 144) and deletes it via `defer` — so concurrent jobs do **not** collide there *today*. The pitfall is *regressing* this under concurrency pressure: e.g. "optimizing" to a single fixed `make-an-issue-mcp.json` (two jobs racing write/delete → one job reads a half-written or already-deleted config → `claude` MCP init fails), or caching one shared file. Secondary shared-singleton issues: the single stored `AVSpeechSynthesizer` will **serialize** overlapping "created issue #N" confirmations (acceptable, but two jobs finishing together queue/overlap audibly); and each job shelling out to `gh auth token` concurrently is correct but redundant latency.

**Why it happens:**
The instinct when adding concurrency is to share/reuse resources for "efficiency," which is exactly backwards for per-job isolation.

**How to avoid:**
- **Keep the per-invocation UUID tempfile** and per-job `defer` cleanup — it's already the correct concurrent design; document it as load-bearing so no one "simplifies" it.
- Keep token acquisition per-job (or cache the token in MainActor state with a short TTL if `gh` latency matters), but never share the MCP config file across jobs.
- Accept serialized TTS, or coalesce confirmations ("created issues #12, #15") if simultaneity is common.

**Warning signs:**
Intermittent `claude` MCP startup failures only when 2+ jobs overlap; tempfile "file not found" / JSON parse errors under concurrency; the failure never reproduces with a single job.

**Phase to address:** Concurrent/Background Filing phase (preserve isolation explicitly in the design + a concurrency test).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Keep filing inside the single `captureState` enum and just allow re-entry | No refactor; reuse v1.0 plumbing | Can't represent N concurrent jobs; UI badge/Stop/confirmations read wrong state; blocks the milestone's core feature | **Never** for v1.1 — the jobs model is the point |
| Cancel by `kill(pid, SIGKILL)` on the `zsh` pid (copy the v1.0 timeout escalation) | One-line, "works" in a demo | Orphans `claude`/Docker subtree; SIGKILL defeats `docker --rm` cleanup → leaked containers | Only as a *last-resort escalation after* a SIGTERM-to-the-group grace window |
| Put the editable prompt in the left-click transient popover | One UI surface, no Settings window | Text field has no focus; edits lost on outside click; worse UX than v1.0 disclosure group | Never — prompt editing needs the focusable Settings window |
| Let the user edit the *entire* prompt string | Maximum flexibility | Breaks the parse contract / tool scope; false "created issue #N" | Never — instructions-only + enforced contract suffix |
| Reuse one fixed MCP tempfile name "to avoid clutter" | Slightly fewer temp files | Concurrent write/delete race → MCP init failures | Never — UUID-per-job is already correct |
| Skip `applicationShouldTerminate` cleanup | Ship the UI sooner | Orphaned processes/containers + leaked tempfiles on every quit-with-jobs | Acceptable only if jobs are guaranteed short *and* you add the launch-time tempfile sweep — but quit-cleanup is cheap; just do it |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| KeyboardShortcuts global hotkey ↔ AppKit menu/popover | Carrying over the `MenuView.onDisappear` manual `didEndTracking` post unchanged | Remove it, re-test hotkey across NSMenu/NSPopover open+close with another app focused, re-add only the minimal balance the new components actually need (Pitfall 10) |
| `NSStatusItem` ↔ left/right click | Setting `statusItem.menu` and expecting `button.action` to still fire | Don't set `.menu`; own `button.action` + `sendAction(on:[.leftMouseUp,.rightMouseUp])`; Control-click = right-click; assign-popUp-clear the menu on demand (Pitfall 7) |
| SwiftUI `Settings` scene ↔ macOS 13/14 | One opening API for both OSes | OS-branch: `showSettingsWindow:` selector on 13, `SettingsLink`/`openSettings` on 14+; activation-policy dance for accessory app (Pitfall 9) |
| `Process` ↔ `docker run -i --rm` MCP server | SIGKILL the client to "cancel" | SIGTERM the process *group* with a grace period so the container `--rm`-cleans; SIGKILL only as group escalation (Pitfalls 1, 6) |
| `claude -p` prompt ↔ `IssueResultParser` | Exposing the whole prompt as editable | Instructions-only field + enforced contract suffix; keep `--allowedTools` in the CLI flag; harden prose fallback to last-URL (Pitfall 11) |
| Swift Task cancellation ↔ `withCheckedContinuation` | Resuming from the cancel handler outside `claim()`, or trusting `terminationHandler` to resume after cancel | Route cancel through the existing `RunState.claim()`; resume `.cancelled` directly; guard `launched` before `terminate()` (Pitfalls 2, 3) |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| N concurrent `docker run` MCP servers | Fans spin up; memory pressure; slow filing | Soft-cap concurrent jobs (e.g. 3–4) with a small queue; surface "queued" state | Firing many issues back-to-back (the milestone's headline use case) |
| Per-job `gh auth token` shell-out | Extra ~hundreds-of-ms per job | Optionally cache token in MainActor state with short TTL; still pass via env, never the command string | Rapid back-to-back filing |
| Unbounded `jobs` collection retained forever | Memory creep; cluttered job list | Prune succeeded/failed/cancelled jobs after they're surfaced (e.g. keep last N) | Long sessions with many filings |
| `AVSpeechSynthesizer` serializing many confirmations | Confirmations lag behind reality; audio backlog | Coalesce confirmations or cap the spoken queue | Several jobs completing within a few seconds |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Moving tool scope into the editable prompt | User (or a bad default) widens beyond `issue_write Read Grep Glob`, or drops `--strict-mcp-config` → MCP config leakage / broader writes | Keep scoping in the CLI flag in `assembleCommand`; prompt is instructions-only (Pitfall 11) |
| Putting the GitHub token in the editable prompt / command string | Token visible in `ps`, logs, or user-editable text | Preserve v1.0: token via `Process.environment` only, never logged, never in the prompt |
| Trusting prose-regex URL as proof of creation under user-controlled prompts | False "created #N" pointing at an arbitrary repo/issue the model mentioned | Prefer structured `tool_result`; constrain prose fallback to the last line/last URL |
| Leaving MCP tempfiles after hard kill | Litter (no secret — token is env-only), but reveals MCP config | Launch-time sweep of `make-an-issue-mcp-*.json` + `applicationShouldTerminate` cleanup (Pitfall 6) |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| No per-job visibility under concurrency | User can't tell which of 3 filings finished/failed, or which to cancel | Render `jobs` as a list in the popover with per-job status + Stop |
| Stop button cancels "the" job when several run | Wrong job cancelled | Per-job cancel tied to each `FilingJob`'s Task/cancel token |
| Editable prompt with no "restore default" | User breaks filing and can't recover | Provide "Restore default prompt"; validate/warn on contract-breaking edits |
| Settings window opens behind other apps (accessory app) | User thinks the click did nothing, clicks repeatedly | Activation-policy dance + `orderFrontRegardless` (Pitfall 9) |
| Silent cancel (no audible/visual confirmation) | User unsure if it stopped | Mark job `.cancelled` in the UI; optionally a brief status note |

## "Looks Done But Isn't" Checklist

- [ ] **Cancel a filing job:** Verify `docker ps` and `pgrep -f claude` show **no survivors** after cancel — not just that the UI cleared (Pitfall 1).
- [ ] **Cancel before launch:** Stress-fire-then-immediately-Stop in a loop; confirm **no `NSInvalidArgumentException` "task not launched"** crash (Pitfall 3).
- [ ] **Cancel race:** Confirm console shows **no** "continuation resumed twice" and **no** "leaked its continuation" under repeated cancel-at-the-finish-line (Pitfall 2).
- [ ] **Quit with jobs in flight:** After quit, verify no orphaned `claude`/Docker containers and no leftover `/tmp/make-an-issue-mcp-*.json` (Pitfall 6).
- [ ] **Concurrent filing:** Fire 3 issues back-to-back; all 3 file, each speaks its own correct number, and a 4th push-to-talk works while they run (Pitfalls 4, 12).
- [ ] **Global hotkey after UI interaction:** Open then close the menu and the popover, focus Finder, hold push-to-talk → recording starts (Pitfall 10).
- [ ] **Settings on both OSes:** Settings window opens, comes to front, and accepts keyboard input on **macOS 13 and macOS 14** (Pitfalls 8, 9).
- [ ] **Edited prompt still files & confirms truthfully:** After editing instructions, a real issue is filed and the spoken number matches GitHub (Pitfall 11).
- [ ] **Editable-prompt focus:** Click the prompt editor and actually type into it (not the previous app) (Pitfall 8).

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Orphaned `claude`/Docker after cancel/quit | LOW (cleanup) / MEDIUM (fix) | Manual `docker ps`/`docker rm`, `pkill claude`; fix = process-group SIGTERM + grace + launch-time sweep |
| Continuation double-resume / leak | MEDIUM | Route all completion paths through `RunState.claim()`; add `launched` flag; reproduce under cancel-stress test |
| Kept single `captureState` for jobs | HIGH | Refactor to `jobs` collection — better to do it first in the Concurrent-filing phase than retrofit after the UI is built on the wrong model |
| Editable prompt broke parsing | LOW | "Restore default prompt"; ensure enforced contract suffix is appended server-side; harden prose fallback |
| Settings won't open on one OS | MEDIUM | Add the OS branch (`showSettingsWindow:` vs `SettingsLink`/`openSettings`) + activation dance |
| `.menu` disabled the popover | LOW | Remove `statusItem.menu`; own `button.action` with click-type branching |

## Pitfall-to-Phase Mapping

> The v1.1 roadmap isn't created yet (0 phases). Phase names below are the milestone's feature slices; the roadmap step should map them to numbered phases. Recommended ordering: **Concurrent-filing model → Cancellation/Stop → AppKit status-item UI + Settings window → Editable prompt → Surfaced errors (RESIL-01)**, because the jobs model (Pitfall 4) underlies cancellation and the UI, and cancellation (Pitfalls 1–3,6) is independent of the UI rewrite.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 1. Process-tree survives signal | Cancellation/Stop | `docker ps`/`pgrep` clean after cancel |
| 2. Continuation double-resume/leak | Cancellation/Stop | No "resumed twice"/"leaked" under cancel-stress |
| 3. terminate() before launch crash | Cancellation/Stop | No `NSInvalidArgumentException` in fire-then-Stop loop |
| 4. Single `captureState` vs concurrency | Concurrent-filing model (first) | 3 concurrent jobs + new capture while filing |
| 5. Sendable/MainActor job-store violations | Concurrent-filing model | Clean `-strict-concurrency=complete` build; no TSan races |
| 6. Quit orphans processes/tempfiles | Cancellation/Stop (or Lifecycle slice) | No orphans/tempfiles after quit-with-jobs |
| 7. `NSStatusItem.menu` disables popover | AppKit status-item UI | Left-click popover + right-click menu both work; Control-click = right |
| 8. NSPopover focus / lost edits | AppKit UI + Editable-prompt | Type into fields; prompt editor in Settings window not transient popover |
| 9. Settings open macOS 13 vs 14 | AppKit status-item UI | Settings opens+focuses on 13 **and** 14 |
| 10. KeyboardShortcuts `.menuOpen` rebalance | AppKit status-item UI | Hotkey fires after menu/popover cycle with another app focused |
| 11. Editable prompt breaks parse/tool contract | Editable-system-prompt | Edited prompt still files; spoken number matches GitHub; tools stay scoped |
| 12. Temp-file/singleton collisions under concurrency | Concurrent-filing model | Concurrent jobs don't hit MCP init failures; UUID tempfile preserved |

## Sources

- v1.0 source (primary, HIGH): `CLIRunner.swift` (`RunState.claim()`, timeout→SIGTERM→SIGKILL escalation, safe pipe drain), `AppState.swift` (single `CaptureState` enum, `beginFiling`, `[weak self]`/WR-03 rationale, macOS 13/14 mic-permission branch), `IssueFilingRunner.swift` (UUID MCP tempfile + `defer` cleanup, env-var token, `--allowedTools`/`--strict-mcp-config`), `IssueResultParser.swift` (structured-then-prose URL parse), `IssueFilingConfig.swift` (Docker MCP server, `--rm`), `MenuView.swift` (`onDisappear` `didEndTracking` KeyboardShortcuts workaround), `MakeAnIssueApp.swift`/`AppDelegate.swift` (MenuBarExtra + NSApplicationDelegateAdaptor).
- Apple/Foundation behavior (HIGH, known): `Process.terminate()` signals the receiver only and preconditions a launched task (`NSInvalidArgumentException` otherwise); `withCheckedContinuation` single-resume / leak diagnostics; `NSStatusItem.menu` vs `button.action` exclusivity.
- macOS Settings-window opening, 13 vs 14 (web-verified, HIGH): Apple `openSettings` docs; "Showing Settings from macOS Menu Bar Items" (Steinberger, 2025) — macOS 14 removed `showSettingsWindow:`, `SettingsLink`/`openSettings` are 14+, accessory apps need activation-policy juggling + ~100/200ms delays + `orderFrontRegardless`; `orchetect/SettingsAccess` (legacy-vs-native split reference).

---
*Pitfalls research for: adding concurrent subprocess jobs + cancellation + AppKit status-item settings UI to a Swift 6 macOS menu-bar app (make-an-issue v1.1)*
*Researched: 2026-06-28*
