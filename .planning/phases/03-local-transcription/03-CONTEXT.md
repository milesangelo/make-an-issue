# Phase 3: Local Transcription - Context

**Gathered:** 2026-06-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 3 turns the recorded WAV (`Application Support/MakeAnIssue/latest.wav`, produced by Phase 2) into transcript text by invoking the user-configured local ASR CLI, capturing its stdout, and surfacing the transcript in the menu/log for the request. It delivers `TRANSCRIBE-01` (invoke the configured ASR CLI on the WAV) and `TRANSCRIBE-02` (capture the CLI output as transcript text).

This phase also introduces the shared `CLIRunner` (a `Process` wrapper) that Phases 4 (model CLI) and 5 (`gh`) will reuse.

This phase does NOT investigate the repo, draft an issue title/body, invoke a model CLI, create GitHub issues, add a review screen, or add retry/queue recovery. Those belong to later phases.

</domain>

<decisions>
## Implementation Decisions

### ASR Command Configuration
- **D-01:** The ASR command is configured via a **text field in the menu** (`MenuView`), persisted with `UserDefaults` — mirroring the existing `KeyboardShortcuts.Recorder` field already in the menu. No JSON config file, no launch-time env var.
- **D-02:** The configured command is executed through the user's **login shell**: `/bin/zsh -lc "<command>"`. The user pastes the exact command that already works in their terminal, so it inherits their real `PATH`/environment (Homebrew, venvs, etc.). This deliberately avoids the stripped-down `PATH` a GUI-launched app otherwise gets.
- **D-03:** Ship with **no default command**. When the field is empty and a recording finishes, show a clear "set your ASR command" message and do not spawn anything. (ASR tools vary too much for a universal default.)

### WAV Path Passing
- **D-04:** The user writes a **`{wav}` placeholder** in their command where the audio file goes (e.g. `whisper {wav} --model base -f txt`). The app substitutes the **quoted absolute path** to `latest.wav` before running.
- **D-05:** If the command is non-empty but contains **no `{wav}` token**, treat it as misconfiguration: show a clear error ("Add `{wav}` to your ASR command where the audio file goes") and do not run. No silent append fallback.

### Transcript Capture
- **D-06:** **stdout is the transcript.** Whatever the command prints to stdout is captured as the transcript text. The user controls their command, so they can make any ASR tool print to stdout.
- **D-07:** Post-process with **trim of leading/trailing whitespace only** — otherwise verbatim. No timestamp stripping or other parsing; formatting is the user's command's responsibility.
- **D-08:** **stderr is captured separately and used for diagnostics only** (error messages/logging on failure). It is never merged into the transcript.

### Output & Failure UX
- **D-09:** On success, show the transcript in **`MenuView` (a selectable text block under the recording status, like the repo path) AND `NSLog` it**. Satisfies the "shown (menu/log)" success criterion and keeps hands-on testing visible without opening the menu mid-flow.
- **D-10:** Add a **`.transcribing` state** to `CaptureState`, shown as "Transcribing…" between recording-finished and the transcript appearing. The ASR command runs **async off the main actor**.
- **D-11:** On failure (empty command, missing `{wav}`, non-zero exit, empty transcript), show a **clear short reason plus the tail of captured stderr** (e.g. "ASR failed (exit 1)" + last stderr line(s)) and **reset state** so a new push-to-talk works. Matches the project's "basic clear errors only" v1 boundary.

### CLIRunner Timeout
- **D-12:** `CLIRunner` enforces a **120-second timeout** (the same ceiling Phase 2 used for `maxRecordingDuration`). On timeout: **terminate the process, show a clear "ASR timed out after 120s" error, and reset to a usable state.** This guards the shared runner (and Phases 4/5) against the stuck-state failure Phase 2 explicitly defended against.

### Claude's Discretion
- Internal API shape of `CLIRunner` (return type for stdout/stderr/exit code, async mechanism), exact placeholder-substitution/quoting implementation, and the working directory used for the ASR run (the `{wav}` path is absolute, so cwd is not significant for Phase 3 — but design `CLIRunner` so Phase 4 can run in the bound repo).
- Exact wording of user-facing status/error strings, as long as they convey the decided meanings.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope and Requirements
- `.planning/ROADMAP.md` — Defines Phase 3 goal, requirements (`TRANSCRIBE-01/02`), success criteria, and the planned slices (shared `CLIRunner`; `Transcriber`).
- `.planning/REQUIREMENTS.md` — Defines `TRANSCRIBE-01` and `TRANSCRIBE-02`; confirms Phase 3 stops at capturing transcript text (no drafting/issue creation).
- `.planning/PROJECT.md` — v1 happy-path boundaries; "local models via configured CLIs," non-sandboxed build, "basic clear errors only."
- `.planning/STATE.md` — Current position; Phase 2 permission/stuck-state notes relevant to the CLIRunner timeout decision.

### Upstream Phase Context
- `.planning/phases/02-push-to-talk-voice-capture/02-CONTEXT.md` — Establishes the WAV handoff contract (`Application Support/MakeAnIssue/latest.wav`, 16 kHz mono) that Phase 3 consumes.

### Existing App Integration
- `Sources/MakeAnIssue/AudioRecorder.swift` — Source of the WAV; `latestWavURL` / `outputDirectory` give the absolute `latest.wav` path to feed `{wav}`.
- `Sources/MakeAnIssue/AppState.swift` — `@MainActor ObservableObject` holding `CaptureState`; integration point for the new `.transcribing` state, transcript text, and the closure-seam pattern (precedent for injecting a `CLIRunner`/transcriber for testing).
- `Sources/MakeAnIssue/MenuView.swift` — Menu UI; where the ASR-command text field, the transcript text block, and the "Transcribing…"/error status surface.
- `Package.swift` — SwiftPM manifest; Phase 3 needs no new dependency (uses Foundation `Process`).
- `Tests/MakeAnIssueTests/AppStateTests.swift` — Existing state tests to extend for the transcribe state/transcript handling.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AppState` closure-seam pattern: Phase 2 injects recorder `start`/`stop` as closures and routes errors back via `onRecordingError`. Reuse the same seam to inject the transcriber/`CLIRunner` for unit testing without spawning real processes.
- `AppState.scheduleRecordingTimeout` / `recordingDidTimeout`: existing `Task`-based 120s timeout pattern — a direct template for the `CLIRunner` timeout (D-12).
- `MenuView` `LabeledContent` + `.textSelection(.enabled)` repo-path block: pattern to copy for the selectable transcript display (D-09).
- `CaptureState` enum: extend with `.transcribing` (D-10).

### Established Patterns
- Shared state owned by `MakeAnIssueApp`, injected into `MenuView` via `.environmentObject`.
- `@MainActor`-isolated state; background callbacks hop to the main actor before mutating `@Published` (the AVAudioRecorder delegate does this — the async ASR run must do the same).
- Focused Swift unit tests around state and small utilities; v1 favors narrow happy-path behavior with clear boundaries over generalized recovery.
- `UserDefaults` is NOT yet used anywhere in the app — D-01 introduces the first persisted setting.

### Integration Points
- New `CLIRunner` component: `Process`-based wrapper that runs `/bin/zsh -lc "<command>"`, captures stdout + stderr separately and the exit code, and enforces a 120s timeout (D-02, D-08, D-12). Designed for reuse by Phases 4 and 5.
- New `Transcriber`: substitutes the quoted `latest.wav` path into the `{wav}` placeholder (D-04/D-05), runs the command via `CLIRunner`, trims stdout (D-06/D-07), returns transcript or a clear failure.
- `AppState`: read the configured command from `UserDefaults`, drive `.transcribing` on release of push-to-talk, store the transcript, surface success/failure (D-09/D-11).
- `MenuView`: add the ASR-command text field (bound to `UserDefaults`) and the transcript/status display.

</code_context>

<specifics>
## Specific Ideas

- Execution form is exactly `/bin/zsh -lc "<command>"`.
- The substitution token is exactly `{wav}`, replaced with the quoted absolute path to `Application Support/MakeAnIssue/latest.wav`.
- Timeout value is exactly 120s, matching Phase 2's `maxRecordingDuration`.
- The transcript contract for Phase 4 is: trimmed plain text from stdout.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope. (A user-configurable timeout was considered for D-12 and deliberately declined in favor of a fixed 120s to stay within happy-path scope.)

</deferred>

---

*Phase: 3-Local Transcription*
*Context gathered: 2026-06-24*
