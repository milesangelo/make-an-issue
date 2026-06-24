# Phase 3: Local Transcription - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-24
**Phase:** 03-local-transcription
**Areas discussed:** ASR command config, WAV path passing, Transcript capture, Output & failure UX, CLIRunner timeout

---

## ASR Command Config

### Config store

| Option | Description | Selected |
|--------|-------------|----------|
| Text field in the menu | Add an ASR-command text field to MenuView, persisted via UserDefaults — mirrors the existing KeyboardShortcuts.Recorder field | ✓ |
| JSON config file | Read a config file at launch; user hand-edits | |
| Env var at launch | Launcher passes the command via an environment variable | |

**User's choice:** Text field in the menu

### PATH / exec

| Option | Description | Selected |
|--------|-------------|----------|
| Run via login shell | `/bin/zsh -lc "<command>"` — inherits the user's full PATH/env; paste what works in the terminal | ✓ |
| Absolute path only | Require an absolute path to the binary; run directly via Process, no shell | |
| Augment PATH | Run via Process but prepend common locations (/opt/homebrew/bin, etc.) | |

**User's choice:** Run via login shell
**Notes:** User paused to clarify why PATH was a concern. Explained the GUI-app stripped-PATH gotcha (Process inherits `/usr/bin:/bin:/usr/sbin:/sbin`, missing Homebrew/venv), which would make a bare `whisper` command fail on first use even though it works in the terminal. User then chose login shell: "paste what works in the terminal."

### First run

| Option | Description | Selected |
|--------|-------------|----------|
| Empty + clear prompt | No default command; empty field on finish → clear "set your ASR command" message, no run | ✓ |
| Ship a default command | Pre-fill a guessed default (e.g. 'whisper') | |
| Placeholder example only | Empty field with greyed-out example hint, never auto-run | |

**User's choice:** Empty + clear prompt

---

## WAV Path Passing

### WAV inject

| Option | Description | Selected |
|--------|-------------|----------|
| {wav} placeholder | User writes {wav} where the file goes; app substitutes the quoted absolute path | ✓ |
| Append as last arg | App always appends the quoted WAV path at the end | |
| Placeholder, fallback to append | Use {wav} if present, else append | |

**User's choice:** {wav} placeholder

### No token

| Option | Description | Selected |
|--------|-------------|----------|
| Clear error, don't run | Missing {wav} → "Add {wav} to your ASR command…" and don't spawn | ✓ |
| Append path anyway | Silently append the WAV path as a fallback | |
| Run as-is | Run verbatim with no file | |

**User's choice:** Clear error, don't run

---

## Transcript Capture

### Read from

| Option | Description | Selected |
|--------|-------------|----------|
| stdout | Whatever the command prints to stdout is the transcript | ✓ |
| Sidecar file | Command writes a file the app reads back | |
| stdout, with stderr fallback | Prefer stdout; if empty, read stderr | |

**User's choice:** stdout

### Cleanup

| Option | Description | Selected |
|--------|-------------|----------|
| Trim whitespace only | Strip leading/trailing whitespace, otherwise verbatim | ✓ |
| Strip timestamps too | Also regex out timestamp markers | |
| No processing | Pass stdout through exactly as captured | |

**User's choice:** Trim whitespace only

### stderr

| Option | Description | Selected |
|--------|-------------|----------|
| Diagnostics only | Capture stderr separately, use only for error messages/logging | ✓ |
| Ignore entirely | Discard stderr | |
| Merge into transcript | Combine stderr into the captured text | |

**User's choice:** Diagnostics only

---

## Output & Failure UX

### Show where

| Option | Description | Selected |
|--------|-------------|----------|
| Menu text + NSLog | Show transcript in MenuView (selectable) AND NSLog it | ✓ |
| Menu only | Display in MenuView only | |
| NSLog only | Log to Console/stderr only | |

**User's choice:** Menu text + NSLog

### Run state

| Option | Description | Selected |
|--------|-------------|----------|
| Add 'transcribing' state | Extend CaptureState with a .transcribing case, run async | ✓ |
| Reuse 'finished' | Stay on .finished/'Done' until transcript replaces it | |
| Just a status string | Flip statusText to 'Transcribing…', leave CaptureState alone | |

**User's choice:** Add 'transcribing' state

### Failure UX

| Option | Description | Selected |
|--------|-------------|----------|
| Clear message + stderr tail | Short reason (e.g. 'ASR failed (exit 1)') + last stderr line(s), reset state | ✓ |
| Generic message only | Fixed 'Transcription failed', no detail | |
| Reason + full stderr in menu | Dump the entire stderr into the menu | |

**User's choice:** Clear message + stderr tail

---

## CLIRunner Timeout

### More? (surfaced candidate)

| Option | Description | Selected |
|--------|-------------|----------|
| Add a CLIRunner timeout | Decide a timeout now to guard the shared runner against hangs | ✓ |
| Leave timeout to the planner | Note as a concern, let planner decide | |
| I'm ready for context | Nothing more to discuss | |

**User's choice:** Add a CLIRunner timeout
**Notes:** Raised as a candidate because a hung ASR command would leave the app stuck in "Transcribing…", the same stuck-state failure Phase 2 guarded against with a recording timeout.

### Timeout value

| Option | Description | Selected |
|--------|-------------|----------|
| 120s, kill + clear error | Match Phase 2's 120s ceiling; terminate, show timeout error, reset | ✓ |
| 60s, kill + clear error | Tighter 60s ceiling | |
| Configurable, default 120s | Expose timeout as a setting, default 120s | |

**User's choice:** 120s, kill + clear error

---

## Claude's Discretion

- Internal API shape of `CLIRunner` (stdout/stderr/exit-code return type, async mechanism).
- Placeholder-substitution and shell-quoting implementation details.
- Working directory for the ASR run (the `{wav}` path is absolute, so cwd is not significant for Phase 3; design `CLIRunner` so Phase 4 can run in the bound repo).
- Exact wording of user-facing status/error strings.

## Deferred Ideas

None — discussion stayed within phase scope. A user-configurable timeout was considered for the CLIRunner timeout and deliberately declined in favor of a fixed 120s to stay within happy-path scope.
