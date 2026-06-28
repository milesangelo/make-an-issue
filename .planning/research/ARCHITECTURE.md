# Architecture Research

**Domain:** Native macOS menu-bar utility (Swift 6 / SwiftUI + AppKit) — v1.1 "Concurrent Filing & Control"
**Researched:** 2026-06-28
**Confidence:** HIGH (grounded in direct reads of the v1.0 source + tests; Swift concurrency APIs verified against patterns already in the codebase)

> This is an **integration architecture** for a subsequent milestone, not an ecosystem survey. It answers: how do the four v1.1 features graft onto the shipped v1.0 architecture while preserving the spike-locked CLI contract, the `RunState` single-resume invariant, the test seams (`onRunTranscription` / `onRunIssueFiling` / `onSpeak`), and Swift 6 actor isolation.

---

## Standard Architecture

### System Overview (target v1.1)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Presentation (AppKit shell + SwiftUI content) — @MainActor           │
│  ┌────────────────┐   left-click   ┌───────────────────────────────┐  │
│  │  AppDelegate   │───────────────▶│ NSPopover → NSHostingController│  │
│  │  • NSStatusItem│                │   → MenuView (jobs list + Stop)│  │
│  │  • NSPopover   │   right-click  └───────────────────────────────┘  │
│  │  • NSMenu      │───────────────▶  NSMenu (Settings…, Quit)          │
│  │  • Combine sink│                                                    │
│  └───────┬────────┘   App.body Scene: Settings { SettingsView }       │
│          │ injects appState (environmentObject) into BOTH surfaces     │
├──────────┼─────────────────────────────────────────────────────────────┤
│  State / Orchestration — @MainActor ObservableObject                   │
│  ┌───────▼──────────────────────────────────────────────────────────┐ │
│  │ AppState                                                          │ │
│  │  capture machine: idle→recording→transcribing  (NO LONGER .filing)│ │
│  │  @Published filingJobs: [FilingJob]   ← value models, observable  │ │
│  │  filingTasks: [UUID: Task<Void,Never>] ← cancel handles (private) │ │
│  │  enqueueFiling()  cancelFiling(id)     seams: onRun*/onSpeak kept  │ │
│  └───────┬───────────────────────────────┬──────────────────────────┘ │
├──────────┼───────────────────────────────┼─────────────────────────────┤
│  Filing pipeline (per-job, concurrent)    │  Capture pipeline (serial)  │
│  ┌───────▼───────────────────┐            │  ┌──────────────────────┐   │
│  │ IssueFilingRunner.file()  │            │  │ Transcriber.run()    │   │
│  │  buildPrompt(+instructions)│           │  │ AudioRecorder        │   │
│  │  enforced flags+trailer    │           │  └──────────────────────┘   │
│  └───────┬───────────────────┘            │                             │
│  ┌───────▼───────────────────┐                                          │
│  │ CLIRunner.run()           │  + withTaskCancellationHandler           │
│  │  RunState.claim() (1-resume)  + .cancelled  + cancelRequested        │
│  └───────┬───────────────────┘                                          │
└──────────┼──────────────────────────────────────────────────────────────┘
           ▼  Process(/bin/zsh -lc "claude -p …")  → MCP → GitHub
```

### Component Responsibilities (new vs modified)

| Component | Status | Responsibility in v1.1 |
|-----------|--------|------------------------|
| `FilingJob` (value struct) | **NEW** | Identifiable/Equatable snapshot of one in-flight or finished filing (`id`, `transcript`, `repo`, `status`, `startedAt`). The source of truth the popover renders. |
| `PromptTemplate` (value type + UserDefaults) | **NEW** | Owns the default editable *instructions* text, resolves a persisted override, falls back to default when blank. |
| `AppState` | **MODIFIED** | Filing decoupled from the capture state machine into a tracked concurrent job set; gains `enqueueFiling`/`cancelFiling`; keeps all three seams + signatures. |
| `CLIRunner` | **MODIFIED** | Adds cooperative cancellation via `withTaskCancellationHandler` + a `.cancelled` `CLIResult` case; `RunState` gains a cancel flag + process handle. Single-resume `claim()` untouched. |
| `IssueFilingRunner` | **MODIFIED** | `file()`/`buildPrompt` gain a **defaulted** `instructions` param (seam signature unchanged); maps `.cancelled`; splits editable instructions from the enforced protocol trailer + flags. |
| `AppDelegate` | **MODIFIED** | Owns `NSStatusItem` + `NSPopover` + right-click `NSMenu`; bridges `appState.$filingJobs` → status-item badge via a Combine sink. Keeps `LaunchRequestStore` flow verbatim. |
| `MakeAnIssueApp` | **MODIFIED** | Scene swaps `MenuBarExtra` → `Settings { SettingsView().environmentObject(appState) }`. |
| `MenuView` | **MODIFIED** | Adds a `filingJobs` list with per-row Stop + error rows (RESIL-01). Drops the MenuBarExtra `.onDisappear` hotkey workaround (no longer in menu mode). |
| `SettingsView` | **NEW** | Editable system-prompt (instructions) tab + relocated "CLI Command" field (FINDING-06). |
| `IssueFilingConfig`, `IssueResultParser`, `Transcriber`, `AudioRecorder`, `LaunchRequestStore`, `RepoBinding` | **UNCHANGED** | Provider seam, parser, capture, launch flow, binding all stay as-is. `RepoBinding` is already `Equatable` + Sendable-clean, so it drops straight into `FilingJob`. |

---

## (a) Modeling concurrent filing jobs

**Recommendation: a `FilingJob` value struct in a `@Published [FilingJob]`, plus a *separate, non-published* `[UUID: Task<Void, Never>]` for cancel handles — NOT a per-job ObservableObject.**

```swift
struct FilingJob: Identifiable, Equatable {
    let id: UUID
    let transcript: String
    let repo: RepoBinding            // already Equatable + Sendable
    var status: Status
    let startedAt: Date

    enum Status: Equatable {
        case running
        case succeeded(number: Int, url: String)
        case failed(message: String)
        case cancelled
    }
}
```

```swift
@MainActor final class AppState: ObservableObject {
    @Published private(set) var filingJobs: [FilingJob] = []
    private var filingTasks: [UUID: Task<Void, Never>] = [:]   // not @Published
    // ... existing seams unchanged ...
}
```

**Why value model + handle dict, not per-job ObservableObject:**

- **SwiftUI observation correctness.** A `@Published [SomeObservableObject]` does *not* republish when an inner object mutates — the classic "array of ObservableObject" trap. You would have to manually forward each job's `objectWillChange` into the parent via Combine sinks, which adds retain-cycle surface and lifecycle bookkeeping. A `@Published [FilingJob]` of value structs republishes correctly on any element mutation because mutating an array element mutates the array. Simpler and right by default.
- **Sendable / value cleanliness.** `Task` is a reference handle, not Equatable, and should never participate in view diffing. Keeping handles in a private non-published dict separates "what the UI renders" (value snapshots) from "how we cancel" (live handles). The published array stays pure-value and trivially testable.
- **Test-seam preservation.** The job Task body calls the *existing* `onRunIssueFiling(transcript, repo)` and the *existing* `onSpeak ?? speak` — both seam signatures untouched. Tests that inject these seams keep working without knowing `FilingJob` exists.

**Enqueue / cancel flow (replaces the serial `beginFiling`):**

```swift
private func enqueueFiling(transcript: String, repo: RepoBinding) {
    let id = UUID()
    filingJobs.append(FilingJob(id: id, transcript: transcript, repo: repo,
                                status: .running, startedAt: .now))
    let task = Task { [weak self] in
        guard let self else { return }
        do {
            let result = try await self.onRunIssueFiling(transcript, repo)
            await MainActor.run {
                self.complete(id, .succeeded(number: result.number, url: result.url))
                (self.onSpeak ?? self.speak)("created issue #\(result.number)")
            }
        } catch is CancellationError {
            await MainActor.run { self.complete(id, .cancelled) }
        } catch {
            await MainActor.run { self.complete(id, .failed(message: Self.message(forFiling: error))) }
        }
        await MainActor.run { self.filingTasks[id] = nil }
    }
    filingTasks[id] = task
}

func cancelFiling(id: UUID) { filingTasks[id]?.cancel() }   // cooperative → kills subprocess (see b)
```

**The core decoupling.** Today `beginTranscription` success does `captureState = .finished; beginFiling()` and `beginFiling` locks `.filing` until the subprocess returns; `startRecording()` guards `== .idle`, so filing blocks capture for up to 300 s. In v1.1, transcription success instead calls `enqueueFiling(...)` and immediately sets `captureState = .idle`. `.filing` is removed from `CaptureState` (or kept only as a transient cosmetic). The capture machine now only ever holds `idle / recording / transcribing`, so back-to-back PTT presses each spawn an independent concurrent job.

**Migration cost to flag for the roadmap:** several existing AppStateTests encode the *old* serial semantics and will be intentionally rewritten (not because the seams changed, but because the behavioral contract did): `testFilingEntersFilingState`, `testPushToTalkDuringFilingIsIgnored` (CR-01 — a re-press during filing is now *allowed*, which is the feature), `testStartRecordingAfterFilingReturnsToIdle`, and the `.filing`-state assertions in `testSuccessfulTranscriptionStoresText`. New tests assert: two enqueues yield two `running` jobs; `cancelFiling` marks `.cancelled`; capture is usable while a job runs.

---

## (b) Cooperative cancellation without breaking single-resume

**Recommendation: wrap the existing `withCheckedContinuation` in `withTaskCancellationHandler`, where `onCancel` only *requests termination* (sets a flag + terminates the process) and never resumes the continuation itself. All resumes still funnel through the one `RunState.claim()` site.**

This is the critical invariant-preserving move: **do not add a second resume site.** The single-resume guarantee holds precisely because exactly one of {terminationHandler, timeout Task, spawn-failure} ever wins `claim()`. Cancellation must *not* become a fourth resumer. Instead it joins the termination path the handler already owns.

```swift
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data(), stderrData = Data()
    private var resumed = false
    private var cancelRequested = false      // NEW
    private var process: Process?            // NEW (lock-guarded so onCancel can reach it)

    func attach(_ p: Process) { lock.lock(); process = p; lock.unlock() }

    // NEW: cancel does NOT claim the resume slot — it only flags + terminates.
    // The terminationHandler that terminate() triggers will claim() and resume.
    func requestCancel() {
        lock.lock(); let p = process; cancelRequested = true; lock.unlock()
        p?.terminate()                       // no-op if already exited
    }
    func wasCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    func claim() -> (stdout: String, stderr: String)? { /* UNCHANGED */ }
}
```

```swift
func run(...) async -> CLIResult {
    let state = RunState()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            // ... attach pipe handlers (unchanged) ...
            process.terminationHandler = { p in
                // ... drain + detach (unchanged) ...
                guard let (out, err) = state.claim() else { return }
                if state.wasCancelled() {
                    continuation.resume(returning: .cancelled)          // NEW mapping
                } else if p.terminationStatus == 0 {
                    continuation.resume(returning: .success(stdout: out, stderr: err, exitCode: 0))
                } else {
                    continuation.resume(returning: .failed(exitCode: p.terminationStatus, stderr: err))
                }
            }
            do { try process.run(); state.attach(process) }
            catch { /* spawn-failure path UNCHANGED — still claim()s once */ }
            // If cancel arrived during spawn, terminate now that we have a handle:
            if Task.isCancelled { state.requestCancel() }
            // timeout Task UNCHANGED (still claims before terminate)
        }
    } onCancel: {
        state.requestCancel()    // @Sendable, off-actor; reaches Process only via Sendable RunState
    }
}
```

Add the case:

```swift
enum CLIResult { case success(...); case failed(...); case timeout; case cancelled }   // NEW: .cancelled
```

**Why the invariant survives:**
- `onCancel` calls `requestCancel()` → `process.terminate()`. It performs **zero** `claim()` and **zero** `continuation.resume`. The termination it triggers fires `terminationHandler`, which performs the single `claim()` and the single resume, mapping `cancelRequested → .cancelled`. One winner, as before.
- Race vs natural exit: if the process already exited, `terminate()` is a harmless no-op and `cancelRequested` is simply ignored by the already-completed handler. Safe.
- Race vs timeout: the timeout Task still `claim()`s *before* terminating and resumes `.timeout`; a late cancel's `terminate()` is a no-op. Safe.
- Cancel-before-spawn: `withTaskCancellationHandler` runs `onCancel` immediately if the task is already cancelled; `process` is still `nil`, so `terminate()` no-ops, but the post-`run()` `if Task.isCancelled { requestCancel() }` guard terminates the freshly-spawned process. Safe.
- **Sendable:** `onCancel` is `@Sendable` and touches the process *only* through the lock-guarded `@unchecked Sendable RunState` — the same discipline the timeout Task already uses when it calls `process.terminate()` from a detached Task. No new isolation hazard.

**Reuse the SIGTERM→SIGKILL escalation.** The timeout arm already schedules a `kill(pid, SIGKILL)` grace escalation. Mirror it inside `requestCancel()` (spawn a detached `Task { try? await Task.sleep(for: .seconds(2)); if process.isRunning { kill(pid, SIGKILL) } }`) so a `claude` child that ignores SIGTERM is still reaped. Secondary robustness, not correctness-critical.

**Upstream mapping:** `IssueFilingRunner.file()` adds `case .cancelled: throw CancellationError()` to its `switch result`. AppState's job Task already catches `is CancellationError` → marks the job `.cancelled`. Because the user triggered it via `cancelFiling(id)` (which cancelled the owning Task, which `withTaskCancellationHandler` observed), the chain is: **UI Stop → `Task.cancel()` → `onCancel` → `process.terminate()` → `.cancelled` → `CancellationError` → job `.cancelled`.**

---

## (c) Threading an editable prompt template without changing the seam signature

**Recommendation: keep the seam `(String, RepoBinding) async throws -> IssueFilingResult` exactly. Add a *defaulted* `instructions` parameter to `IssueFilingRunner.file()` and `buildPrompt()`, and have the seam's default closure read the persisted template at invocation time. Split the prompt into editable *instructions* vs an enforced *protocol trailer*; keep the *flags* enforced in `assembleCommand` (already independent of prompt text).**

Three layers, three different owners of "enforced":

| Layer | Editable? | Enforced where | Tests that lock it |
|-------|-----------|----------------|--------------------|
| Persona + investigation guidance ("You are make-an-issue… investigate the repo…") | **YES** (user-editable) | `PromptTemplate.defaultInstructions`, overridable | none — free text |
| Protocol trailer (`issue_write` + `method=create`, `Issue URL:` last-line marker, "Do not ask for confirmation; file it directly") | **NO** | `buildPrompt` always appends it around the instructions | `testBuildPromptContains{IssueWriteToolName,MethodCreate,IssueURLMarker}`, `testBuildPromptInstructsFileDirectly` |
| CLI flags (`--mcp-config`, `--strict-mcp-config`, `--allowedTools …`, `--output-format stream-json --verbose`, no `bypassPermissions`) | **NO** | `assembleCommand` — *independent of prompt text* | `testCommandAssembly*` |

**Seam stays byte-for-byte; plumbing is additive (mirrors how `environment:` was slotted into `CLIRunner.run`):**

```swift
static func buildPrompt(
    transcript: String,
    ownerRepo: String?,
    config: IssueFilingConfig,
    instructions: String = PromptTemplate.defaultInstructions   // NEW, defaulted → all callers/tests compile
) -> String {
    let repoRef = ownerRepo.map { "the repository \($0) (current working directory)" }
        ?? "the repository in the current working directory"
    return """
    \(instructions)

    Target: \(repoRef)
    Spoken transcript: "\(transcript)"

    Steps:
    1. Briefly investigate the repo to write a specific, accurate issue.
    2. File the issue using the \(config.mcpToolName) tool with method=create.   ← ENFORCED trailer
    3. On the LAST line, output ONLY: Issue URL: https://github.com/<owner>/<repo>/issues/<NUMBER>
    Do not ask for confirmation; file it directly.
    """
}

static func file(
    transcript: String, repo: RepoBinding,
    config: IssueFilingConfig = .claudeGitHub,
    ownerRepo: String? = nil,
    instructions: String = PromptTemplate.defaultInstructions   // NEW, defaulted
) async throws -> IssueFilingResult { /* passes instructions into buildPrompt */ }
```

**Where the live edit enters** — the AppState default seam closure reads the persisted template at call time (not at init), so runtime edits take effect without re-instantiating AppState:

```swift
onRunIssueFiling: @escaping (String, RepoBinding) async throws -> IssueFilingResult = { transcript, repo in
    try await IssueFilingRunner.file(
        transcript: transcript, repo: repo, config: .claudeGitHub, ownerRepo: nil,
        instructions: PromptTemplate.current)     // reads UserDefaults, falls back to default
}
```

`PromptTemplate.current` reads `UserDefaults.standard.string(forKey: AppState.promptInstructionsKey)` and returns `defaultInstructions` when nil/blank (defensive: a user who clears the field still gets a working prompt, and the enforced trailer/flags are unaffected). Add `static let promptInstructionsKey = "promptInstructions"` to AppState, mirroring the existing `cliCommandKey` convention. `SettingsView` binds a `TextEditor` to `@AppStorage(AppState.promptInstructionsKey)` — same pattern as the current CLI Command `@AppStorage(AppState.cliCommandKey)`.

**Why this satisfies the quality gate:** the enforced contract is *structurally* impossible to break by editing instructions — the protocol trailer is concatenated by `buildPrompt` after the user text, and the flags live entirely in `assembleCommand`, which never sees the prompt body. Every existing `testBuildPrompt*`/`testCommandAssembly*` assertion passes unchanged because the default `instructions` preserves prior behavior and the enforced substrings are always present. Tests that inject `onRunIssueFiling` never touch UserDefaults, so the editable plumbing is invisible to them.

---

## (d) Owning NSStatusItem/NSPopover in AppDelegate while keeping AppState injection + LaunchRequestStore

**Recommendation: AppDelegate owns the status item, popover, and right-click menu; the SwiftUI `App.body` swaps `MenuBarExtra` for a `Settings { SettingsView }` scene. The single `appState` is injected into both surfaces via `.environmentObject`. The `LaunchRequestStore` flow is untouched — status-item setup is appended to `applicationDidFinishLaunching` after the existing launch-request consumption.**

```swift
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()                       // UNCHANGED — single source of truth
    private let launchRequestStore = LaunchRequestStore()   // UNCHANGED
    private var statusItem: NSStatusItem!           // NEW
    private let popover = NSPopover()               // NEW
    private var cancellables = Set<AnyCancellable>()// NEW (Combine bridge)

    func applicationDidFinishLaunching(_ n: Notification) {
        consumeLatestLaunchRequest()                // UNCHANGED flow
        setUpStatusItem()                           // NEW
        observeJobsForBadge()                       // NEW
    }
    // applicationShouldHandleReopen + consumeLatestLaunchRequest: UNCHANGED

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])   // dual handling
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuView().environmentObject(appState))              // SAME MenuView + injection
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showRightClickMenu() }
        else { togglePopover(sender) }
    }
}
```

- **Left-click → NSPopover** hosting the *existing* `MenuView().environmentObject(appState)` via `NSHostingController`. UI churn is minimal: MenuView keeps observing `appState` reactively, so the popover updates live (including the new `filingJobs` list). Drop MenuView's `.onDisappear` `NSMenu.didEndTracking` workaround — it existed only to fight `MenuBarExtra`'s menu-mode hotkey suppression, which no longer applies once we own a plain `NSStatusItem`. **Flag for verification:** confirm the global KeyboardShortcuts hotkey stays in `.normal` mode with a popover (it should, since we're not in NSMenu tracking).
- **Right-click → NSMenu** built programmatically (Settings…, Quit). Open it with the dual-`sendAction` pattern above (left vs right discriminated by `NSApp.currentEvent`).
- **Settings window → SwiftUI `Settings` scene.** With `MenuBarExtra` removed, `App.body` needs a scene; `Settings { SettingsView().environmentObject(appDelegate.appState) }` is the system-standard Preferences window, free window management, and the same `environmentObject` injection. Open it from the right-click menu via the standard show-settings action. **Flag for verification:** the programmatic selector to open Settings differs by OS (`showSettingsWindow:` on macOS 14+, `showPreferencesWindow:` on 13); pin the correct path for the macOS 13+ floor, or fall back to an AppDelegate-owned `NSWindow + NSHostingController` if the selector proves brittle.
- **Status-item badge ↔ jobs.** AppKit does not auto-observe ObservableObject. Bridge with one Combine sink: `appState.$filingJobs.receive(on: RunLoop.main).sink { [weak self] jobs in self?.updateBadge(running: jobs.filter { $0.status == .running }.count) }`. This is the single Combine→AppKit seam; everything else stays declarative SwiftUI.

**Isolation:** `AppDelegate`, `AppState`, `NSStatusItem`/`NSPopover`/`NSMenu`/`NSHostingController` are all `@MainActor` — uniformly main-actor, no new hops. The Combine sink delivers on main. `LaunchRequestStore`'s file flow is synchronous and unchanged.

---

## Data Flow

### v1.0 (serial) vs v1.1 (concurrent)

```
v1.0:  PTT → record → transcribe → .finished → beginFiling (.filing locks ≤300s) → speak → .idle
                                                  ▲ PTT blocked here
v1.1:  PTT → record → transcribe → enqueueFiling → .idle  (capture free immediately)
                                        │
                                        ├── FilingJob#A (running) ──→ onRunIssueFiling ─→ speak ─→ succeeded
                                        ├── FilingJob#B (running) ──→ … (concurrent)
                                        └── cancelFiling(B) → Task.cancel → CLIRunner onCancel
                                                             → process.terminate → .cancelled
```

### Cancellation chain (the dependency spine)

```
UI Stop button (MenuView row)
   → AppState.cancelFiling(id)
      → filingTasks[id].cancel()                 (cooperative)
         → withTaskCancellationHandler.onCancel
            → RunState.requestCancel()            (flag + Process.terminate, off-actor, lock-guarded)
               → terminationHandler claim() (single resume) → .cancelled
                  → IssueFilingRunner maps → CancellationError
                     → job Task catches → FilingJob.status = .cancelled  (@Published → popover updates)
```

### State management

```
AppState (@MainActor ObservableObject)
   @Published filingJobs ──(objectWillChange)──▶ MenuView popover (SwiftUI auto)
                          └──($filingJobs sink)──▶ AppDelegate status-item badge (Combine→AppKit)
   filingTasks[UUID:Task] ──(private)──▶ cancelFiling handles only; never rendered
```

---

## Suggested Build Order (dependency-respecting)

The critical chain is **CLIRunner cancellation → IssueFilingRunner mapping → AppState `cancelFiling` → UI Stop button**; the editable-prompt track runs parallel and merges at Settings.

1. **CLIRunner cooperative cancellation (b).** Add `.cancelled`, `withTaskCancellationHandler`, `RunState.requestCancel`/`cancelRequested`/`attach(process)`. Self-contained, additive (defaulted), unit-testable with `/bin/sleep` + `Task.cancel()` (mirror `CLIRunnerTests`). **No dependents broken** — `.cancelled` is a new case existing callers don't yet produce. *Verify: single-resume holds under the cancel/exit/timeout three-way race (extend the existing 40-iteration stress test).*

2. **IssueFilingRunner: map `.cancelled` + editable instructions (b+c).** (2a) `switch result { case .cancelled: throw CancellationError() }`. (2b) Add defaulted `instructions:` to `file()`/`buildPrompt`; refactor the enforced protocol trailer; introduce `PromptTemplate`. Seam signature unchanged. *Verify: all `testBuildPrompt*`/`testCommandAssembly*` pass with custom instructions; cancelled maps through.* Depends on 1.

3. **AppState concurrent filing jobs + cancel (a).** Introduce `FilingJob`, `@Published filingJobs`, `filingTasks`, `enqueueFiling`, `cancelFiling`; decouple from `CaptureState` (transcription success → `enqueueFiling` + `.idle`; remove blocking `.filing`). Preserve `onRunTranscription`/`onRunIssueFiling`/`onSpeak`. Rewrite the obsolete serial-filing tests; add concurrent + cancel tests. Depends on 2 (so `cancelFiling` actually kills the subprocess).

4. **UI shell swap: NSStatusItem + NSPopover + right-click NSMenu + Settings scene (d).** Replace `MenuBarExtra`; wire popover→`MenuView(appState)`, right-click→NSMenu, `Settings { SettingsView(appState) }`; add the `$filingJobs` badge sink. Structurally independent of 1–3, but sequenced after 3 so the popover has the jobs model to bind to. *Verify: global hotkey stays in `.normal` mode; Settings opens on the macOS 13+ floor.*

5. **Settings content: editable prompt field + relocate "CLI Command" (c + FINDING-06).** `SettingsView` gets the instructions `TextEditor` bound to `@AppStorage(promptInstructionsKey)` and the relocated CLI Command field (resolves FINDING-06). Depends on 4 (window) + 2b (template plumbing).

6. **Jobs list UI + per-job Stop + surfaced errors (a + d, RESIL-01).** MenuView renders `appState.filingJobs` with Stop buttons (`cancelFiling`) and `failed`-status error rows. Depends on 3 (model) + 4 (shell).

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Array of per-job `ObservableObject`
**What people do:** `@Published var jobs: [FilingJobVM]` where `FilingJobVM: ObservableObject`.
**Why it's wrong:** Inner `@Published` mutations don't republish the parent; the popover row won't update on status change without manual `objectWillChange` forwarding (retain-cycle + lifecycle surface).
**Do this instead:** value `FilingJob` in `@Published [FilingJob]`; cancel handles in a separate private `[UUID: Task]`.

### Anti-Pattern 2: Adding a second continuation resume site for cancel
**What people do:** Have `onCancel` call `continuation.resume(returning: .cancelled)` directly.
**Why it's wrong:** It races the terminationHandler/timeout resumers and breaks the single-resume invariant → `SWIFT TASK CONTINUATION MISUSE` crash.
**Do this instead:** `onCancel` only sets a flag + `terminate()`; the existing `claim()`-guarded terminationHandler performs the one resume and maps the flag to `.cancelled`.

### Anti-Pattern 3: Making the editable prompt a new seam parameter
**What people do:** Change `onRunIssueFiling` to `(String, RepoBinding, String) -> …`.
**Why it's wrong:** Breaks every AppState test that injects the seam and couples the test surface to a UI concern.
**Do this instead:** Keep the seam signature; read the persisted template inside the *default* closure; pass it via a *defaulted* `instructions:` arg on `file()`.

### Anti-Pattern 4: Letting the editable text reach the enforced contract
**What people do:** Store the entire prompt (flags-adjacent instructions + protocol) as one editable blob.
**Why it's wrong:** A user edit can delete `method=create` / the `Issue URL:` marker / "do not ask for confirmation," silently breaking parsing or the scoped grant.
**Do this instead:** Edit only the persona/guidance; `buildPrompt` always re-appends the protocol trailer; flags live solely in `assembleCommand`.

### Anti-Pattern 5: Reusing `MenuBarExtra`'s `.onDisappear` hotkey workaround under NSStatusItem
**What people do:** Carry the `NSMenu.didEndTracking` post into the new popover.
**Why it's wrong:** It compensated for `MenuBarExtra` menu-mode suppression that no longer exists; carrying it can spuriously toggle hotkey modes.
**Do this instead:** Remove it; verify the hotkey stays in `.normal` mode with a transient popover.

---

## Integration Points Summary

| Boundary | Communication | Notes |
|----------|---------------|-------|
| AppState ↔ MenuView (popover) | `@EnvironmentObject` + `@Published filingJobs` | SwiftUI auto-observation; same injection as v1.0 |
| AppState ↔ AppDelegate status badge | Combine `$filingJobs` sink on main | Only Combine→AppKit bridge in the app |
| AppState ↔ IssueFilingRunner | `onRunIssueFiling` seam (unchanged signature) | Called per-job from a tracked Task |
| IssueFilingRunner ↔ CLIRunner | `await run(...)` returning `CLIResult` (+`.cancelled`) | `.cancelled` → `CancellationError` |
| CLIRunner ↔ Process | `withTaskCancellationHandler` + lock-guarded `RunState` | Single-resume preserved; off-actor terminate via Sendable RunState |
| Settings ↔ filing | `@AppStorage(promptInstructionsKey)` → `PromptTemplate.current` | Read at invocation; enforced trailer/flags independent |
| AppDelegate ↔ LaunchRequestStore | unchanged file consume in didFinishLaunching/reopen | Status-item setup appended after consume |

---

## Sources

- Direct source reads (v1.0, HIGH confidence): `AppState.swift`, `CLIRunner.swift`, `IssueFilingRunner.swift`, `IssueFilingConfig.swift`, `IssueResultParser.swift`, `RepoBinding.swift`, `MakeAnIssueApp.swift`, `AppDelegate.swift`, `MenuView.swift`, `LaunchRequestStore.swift`.
- Test contracts that constrain the design: `AppStateTests.swift` (seam + state-machine assertions), `CLIRunnerTests.swift` (single-resume / timeout race), `IssueFilingRunnerTests.swift` (prompt + flag contract).
- Project context: `.planning/PROJECT.md` (v1.1 milestone goals, spike-locked decisions), `.planning/STATE.md` (accumulated decisions, FINDING-06, RESIL-01).
- Swift concurrency: `withTaskCancellationHandler` cooperative-cancel pattern, consistent with the codebase's existing detached-Task `Process.terminate()` discipline (CLIRunner timeout arm).

---
*Architecture research for: make-an-issue v1.1 (Concurrent Filing & Control)*
*Researched: 2026-06-28*
