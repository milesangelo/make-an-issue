# Project Research Summary

**Project:** make-an-issue
**Domain:** Native macOS menu-bar utility (voice → local CLIs → GitHub issue)
**Researched:** 2026-06-23
**Confidence:** HIGH

## Executive Summary

make-an-issue is a native macOS menu-bar agent that captures a spoken thought via a global
push-to-talk shortcut and turns it into a GitHub issue for the repo you launched it from.
The established way to build this in 2026 is a Swift/SwiftUI `MenuBarExtra` app with
`LSUIElement = YES` (no Dock icon), a global hotkey via the sindresorhus/KeyboardShortcuts
package, microphone capture through AVFoundation, and a single shared `Process` runner that
shells out to the user's configured ASR CLI, model CLI, and `gh`. Confirmation is spoken with
native TTS.

The dominant technical risk is execution environment, not algorithms: App Sandbox blocks
spawning external CLIs (so v1 ships non-sandboxed), GUI apps don't inherit the shell `PATH`
(so command paths must be configurable), and the global hotkey must use a real Carbon-based
hotkey rather than an `NSEvent` monitor. Audio must be 16 kHz mono WAV to satisfy whisper.cpp.
None of these are research-blocking; each maps to a specific phase.

The work decomposes cleanly into a sequential pipeline, so the roadmap is a vertical-MVP
walking skeleton: stand up the repo-bound menu-bar app first, then add capture, transcription,
investigation, and finally automatic creation + spoken confirmation — each phase independently
testable by hand.

## Key Findings

### Recommended Stack

Native Swift app on macOS 13+. SwiftUI `MenuBarExtra` (`.window` style) for the menu-bar UI,
AppKit `NSStatusItem`/`NSPopover` as a fallback. KeyboardShortcuts (SPM) for the global
push-to-talk hotkey. AVFoundation for mic capture and TTS. Foundation `Process` to invoke
external CLIs.

**Core technologies:**
- Swift + SwiftUI `MenuBarExtra` — native menu-bar app, minimal code
- sindresorhus/KeyboardShortcuts — reliable global push-to-talk hotkey
- AVFoundation — microphone capture (16 kHz mono WAV) and `AVSpeechSynthesizer`
- Foundation `Process` — run configured ASR/model CLIs and `gh`

### Expected Features

**Must have (table stakes):** repo-bound launch, push-to-talk capture, local transcription,
repo-aware draft, automatic `gh issue create`, spoken confirmation.
**Should have (competitive):** fully local/private pipeline, zero-UI voice-in/voice-out.
**Defer (v2+):** review/edit screen, multi-repo UI, wake-phrase, retry/queue recovery.

### Architecture Approach

A single instance binds to the git root of the launching command's working directory. A
hotkey manager drives an audio recorder; a shared CLI runner chains transcription →
investigation → issue creation; a speech component announces the result.

**Major components:**
1. RepoBinding — resolves and holds the bound git repo from the launch cwd
2. HotkeyManager + AudioRecorder — push-to-talk capture to WAV
3. CLIRunner (Transcriber / Investigator / IssueCreator) — the external-tool pipeline
4. SpeechOutput + MenuView — confirmation and status

### Critical Pitfalls

1. **App Sandbox blocks CLIs** — ship non-sandboxed for v1.
2. **Hotkey via `NSEvent` monitor leaks keys** — use KeyboardShortcuts.
3. **Wrong audio format** — record/convert to 16 kHz mono WAV.
4. **GUI `PATH` differs from Terminal** — configurable absolute command paths.
5. **Issue number parsing** — `gh` prints a URL; extract the trailing number after exit 0.

## Implications for Roadmap

Vertical-MVP slices, each independently testable by hand:

### Phase 1: Menu-Bar App + Repo-Bound Launch
**Rationale:** Nothing works without the right repo binding and a running agent.
**Delivers:** A no-Dock menu-bar app that a repo-local command launches/activates, bound to that repo.
**Addresses:** repo-bound launch table stake. **Avoids:** sandbox setup, duplicate-instance, `.menu` style pitfalls.

### Phase 2: Push-to-Talk Voice Capture
**Rationale:** Capture is the input to everything downstream.
**Delivers:** Global hotkey records mic audio to a 16 kHz mono WAV while held.
**Uses:** KeyboardShortcuts + AVFoundation. **Avoids:** `NSEvent`-monitor and audio-format pitfalls.

### Phase 3: Local Transcription
**Rationale:** Turns audio into the text the model needs.
**Delivers:** Configured ASR CLI runs on the WAV and yields transcript text.
**Uses:** shared CLIRunner. **Avoids:** `PATH`/environment pitfall (first external-CLI phase).

### Phase 4: Repo Investigation → Issue Draft
**Rationale:** Repo-aware drafting is the differentiator.
**Delivers:** Configured model CLI turns transcript + repo context into title + body.
**Implements:** Investigator component.

### Phase 5: Automatic Issue Creation + Spoken Confirmation
**Rationale:** The payoff — say it, file it, hear the number.
**Delivers:** `gh issue create` in the bound repo, number parsed, "created issue #NUMBER" spoken.
**Avoids:** issue-number-parsing pitfall.

### Phase Ordering Rationale

- Strict data-flow dependency: bind → capture → transcribe → investigate → create.
- Phase 3 is the first to shell out, so PATH/sandbox issues surface early and are reused in 4–5.
- Each phase ends in a hands-on test, satisfying the vertical-MVP intent.

### Research Flags

Phases likely needing light planning-time checks:
- **Phase 2:** confirm AVFoundation capture settings produce exactly 16 kHz mono WAV.
- **Phase 1:** confirm single-instance activation + cwd passing approach for the launcher.

Phases with standard patterns (skip deep research):
- **Phases 3, 4, 5:** straightforward `Process` invocation + output parsing.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified against Apple docs and the KeyboardShortcuts/whisper.cpp repos |
| Features | HIGH | Flow is well-defined and bounded by explicit decisions |
| Architecture | HIGH | Standard menu-bar + Process-orchestration pattern |
| Pitfalls | HIGH | Sandbox/PATH/audio/hotkey issues are well documented |

**Overall confidence:** HIGH

### Gaps to Address

- Exact `AVAudioEngine` configuration for 16 kHz mono output — validate during Phase 2.
- Launcher mechanism for single-instance activation + cwd hand-off — validate during Phase 1.

## Sources

### Primary (HIGH confidence)
- Apple Developer Docs — `MenuBarExtra`, `LSUIElement`
- github.com/sindresorhus/KeyboardShortcuts — push-to-talk hotkey
- github.com/ggml-org/whisper.cpp — `whisper-cli`, 16 kHz mono WAV contract

### Secondary (MEDIUM confidence)
- techconcepts.org "macOS Menu Bar App ... 2026 Complete Guide" — NSStatusItem/NSPopover/SMAppService

---
*Research completed: 2026-06-23*
*Ready for roadmap: yes*
