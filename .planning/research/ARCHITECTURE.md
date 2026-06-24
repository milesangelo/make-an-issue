# Architecture Research

**Domain:** Native macOS menu-bar app orchestrating local CLIs
**Researched:** 2026-06-23
**Confidence:** HIGH

## Standard Architecture

### System Overview (data flow)

```
[repo-local launch command]
   (passes cwd)            ──launch/activate──>  [App / single-instance]
                                                        │ binds session
                                                        ▼
                                                 [RepoBinding] (git root of cwd)
                                                        │
[global shortcut held] ──onKeyDown──> [HotkeyManager] ─┤
[global shortcut released] ──onKeyUp──────────────────┘
                                                        ▼
                                                 [AudioRecorder] ── 16kHz mono WAV ──┐
                                                                                     ▼
                                                                          [CLIRunner: ASR command]
                                                                                     │ transcript text
                                                                                     ▼
                                                                          [CLIRunner: model command]
                                                                             (transcript + repo ctx)
                                                                                     │ title + body
                                                                                     ▼
                                                                          [CLIRunner: gh issue create]
                                                                             (cwd = bound repo)
                                                                                     │ issue URL/number
                                                                                     ▼
                                                                          [SpeechOutput] "created issue #N"
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| Launcher command | Start app if needed, activate it, pass cwd | Shell script / small CLI in repo (`make-an-issue`) that `open`s the app with the path or writes it to a known location |
| App / single instance | Own lifecycle, ensure one running instance | SwiftUI `App` + `MenuBarExtra`, `LSUIElement` |
| RepoBinding | Resolve & hold the bound git repo | `git rev-parse --show-toplevel` on the passed cwd |
| HotkeyManager | Register global push-to-talk, emit start/stop | sindresorhus/KeyboardShortcuts `onKeyDown`/`onKeyUp` |
| AudioRecorder | Capture mic while held, write WAV | `AVAudioEngine`/`AVAudioRecorder` → 16 kHz mono WAV |
| CLIRunner | Run a configured command, capture stdout/exit | Foundation `Process` + `Pipe` |
| Config | Hold ASR/model command strings + shortcut | `UserDefaults`/`@AppStorage` or a small JSON config |
| SpeechOutput | Speak the result | `AVSpeechSynthesizer` or `/usr/bin/say` |
| MenuView | Show bound repo + current status | SwiftUI view inside `MenuBarExtra` |

## Recommended Project Structure

```
make-an-issue/
├── App/
│   ├── MakeAnIssueApp.swift     # @main, MenuBarExtra scene, LSUIElement
│   └── AppState.swift           # @Observable: bound repo, status, wiring
├── MenuBar/
│   └── MenuView.swift           # status + bound repo display
├── Capture/
│   ├── HotkeyManager.swift      # KeyboardShortcuts push-to-talk
│   └── AudioRecorder.swift      # mic → 16kHz mono WAV
├── Pipeline/
│   ├── CLIRunner.swift          # Process wrapper (stdout/exit/timeouts)
│   ├── Transcriber.swift        # configured ASR command
│   ├── Investigator.swift       # configured model command → title/body
│   └── IssueCreator.swift       # gh issue create + parse number
├── Feedback/
│   └── SpeechOutput.swift       # TTS confirmation
├── Config/
│   └── Settings.swift           # configured commands + shortcut
└── bin/
    └── make-an-issue            # repo-local launcher command/script
```

### Structure Rationale

- **Capture / Pipeline / Feedback** mirror the data-flow stages, so each roadmap phase maps to one folder.
- **CLIRunner is shared** so ASR, model, and `gh` invocations use one tested execution path.
- **bin/launcher** is the repo-binding entry point and is intentionally separate from the app target.

## Architectural Patterns

### Pattern 1: Single shared `Process` runner
**What:** One `CLIRunner` runs every external command and returns `(stdout, stderr, exitCode)`.
**When to use:** Any external invocation (ASR, model, `gh`).
**Trade-offs:** Centralizes timeout/working-directory/error handling; slight indirection.

### Pattern 2: Working-directory as repo binding
**What:** `gh` and git commands run with `currentDirectoryURL` set to the bound repo root.
**When to use:** All repo-scoped operations.
**Trade-offs:** Simple and matches how `gh` resolves repos; requires capturing cwd at launch.

### Pattern 3: Push-to-talk as explicit start/stop edges
**What:** `onKeyDown` starts recording; `onKeyUp` stops and triggers the pipeline.
**When to use:** The capture stage.
**Trade-offs:** No VAD/endpointing needed; user controls boundaries precisely.

## Key Technical Notes

- **`LSUIElement = YES`** makes it a pure menu-bar agent (no Dock icon); set before the App struct initializes.
- **Permissions:** Microphone (`NSMicrophoneUsageDescription`) and Input Monitoring/Accessibility for the global hotkey.
- **Non-sandboxed v1:** required to spawn `gh`/ASR/model via `Process`.
- **Single instance + activation:** the launcher must activate the existing instance and update the bound repo rather than spawning a second copy.

## Sources

- Apple Developer Docs — `MenuBarExtra`, `LSUIElement` (HIGH)
- techconcepts.org 2026 menu-bar guide — NSStatusItem/NSPopover/SMAppService split (MEDIUM)
- whisper.cpp README — WAV input contract for the ASR stage (HIGH)
- `gh` CLI behavior — repo resolution from working directory (HIGH)

---
*Architecture research for: native macOS voice-to-issue menu-bar app*
*Researched: 2026-06-23*
