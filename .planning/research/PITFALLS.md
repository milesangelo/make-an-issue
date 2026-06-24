# Pitfalls Research

**Domain:** Native macOS menu-bar app orchestrating local CLIs
**Researched:** 2026-06-23
**Confidence:** HIGH

## Critical Pitfalls

### Pitfall 1: App Sandbox blocks external CLI execution
**What goes wrong:** `gh`, the ASR CLI, and the model CLI fail to launch or can't read files.
**Why it happens:** App Sandbox forbids spawning arbitrary executables and restricts filesystem access.
**How to avoid:** Ship v1 non-sandboxed; run CLIs with explicit absolute paths / a known shell environment.
**Warning signs:** `Process` launch errors, "operation not permitted", empty output despite a working CLI in Terminal.
**Phase to address:** Phase 1 (project setup) and every phase that shells out (3, 4, 5).

### Pitfall 2: Global hotkey done with `NSEvent` global monitor
**What goes wrong:** Hotkey "works" but the keystroke also reaches the foreground app; push-to-talk is unreliable.
**Why it happens:** `addGlobalMonitorForEvents` only copies events and cannot consume them; needs Carbon/`CGEventTap`.
**How to avoid:** Use sindresorhus/KeyboardShortcuts (`onKeyDown`/`onKeyUp`); request Input Monitoring/Accessibility.
**Warning signs:** Other apps react to the shortcut; key-up missed; recording never stops.
**Phase to address:** Phase 2 (voice capture).

### Pitfall 3: Wrong audio format for the ASR CLI
**What goes wrong:** Transcription returns empty/garbage or the CLI errors on the input file.
**Why it happens:** whisper.cpp (and similar) require 16-bit **16 kHz mono** WAV; default capture is often 44.1/48 kHz stereo.
**How to avoid:** Record/convert to 16 kHz mono PCM WAV (configure `AVAudioEngine` or run `ffmpeg -ar 16000 -ac 1 -c:a pcm_s16le`).
**Warning signs:** ASR works on test files but not on app recordings; nonsense transcripts.
**Phase to address:** Phase 2 (capture) → consumed in Phase 3 (transcription).

### Pitfall 4: PATH/environment differs from Terminal
**What goes wrong:** `gh`/ASR/model "not found" or behave differently when spawned by the app.
**Why it happens:** GUI apps don't inherit the user's shell `PATH`; Homebrew paths (`/opt/homebrew/bin`) are missing.
**How to avoid:** Let the user configure absolute command paths; or set a known `PATH` in the `Process` environment.
**Warning signs:** "command not found" only inside the app; `gh` unauthenticated despite Terminal auth.
**Phase to address:** Phase 3 first (transcription), reused in 4 and 5.

### Pitfall 5: Parsing the issue number from `gh` output
**What goes wrong:** Spoken confirmation says the wrong number or nothing.
**Why it happens:** `gh issue create` prints the issue **URL** (e.g. `.../issues/42`), not a bare number.
**How to avoid:** Capture stdout and extract the trailing number from the URL; verify exit code 0 first.
**Warning signs:** Empty/zero issue number, confirmation spoken even when creation failed.
**Phase to address:** Phase 5 (issue creation + confirmation).

### Pitfall 6: Second launch spawns a duplicate instead of activating
**What goes wrong:** Running the command again opens another app/menu-bar icon and loses repo binding.
**Why it happens:** No single-instance handling; launcher always starts a new process.
**How to avoid:** Enforce single instance; on re-launch, activate the running app and update the bound repo from the new cwd.
**Warning signs:** Multiple menu-bar icons; issues filed against a stale repo.
**Phase to address:** Phase 1 (repo-bound launch).

### Pitfall 7: `MenuBarExtra` default `.menu` style breaks custom layout
**What goes wrong:** Status UI renders as flat menu items; HStacks/sizes ignored.
**Why it happens:** Default style hosts content in an `NSMenu`; normal SwiftUI layout doesn't apply.
**How to avoid:** Use `.menuBarExtraStyle(.window)` (or `NSStatusItem` + `NSPopover`).
**Warning signs:** Layout looks wrong only in the menu-bar popover.
**Phase to address:** Phase 1 (menu-bar app).

## Anti-Pattern Summary

- Don't hand-roll global hotkeys with Carbon from scratch — use KeyboardShortcuts.
- Don't assume default mic format is ASR-ready — enforce 16 kHz mono.
- Don't trust GUI `PATH` — configure absolute command paths.
- Don't speak success before checking the `gh` exit code and parsed number.

## Sources

- github.com/sindresorhus/KeyboardShortcuts — why `NSEvent` monitor is insufficient (HIGH)
- github.com/ggml-org/whisper.cpp — 16 kHz mono WAV requirement (HIGH)
- Apple Developer Docs + 2026 menu-bar guides — `MenuBarExtra` styles, `LSUIElement` (HIGH/MEDIUM)
- `gh` CLI — issue-create output is a URL (HIGH)

---
*Pitfalls research for: native macOS voice-to-issue menu-bar app*
*Researched: 2026-06-23*
