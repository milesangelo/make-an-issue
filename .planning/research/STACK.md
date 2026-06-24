# Stack Research

**Domain:** Native macOS menu-bar utility (voice → local CLIs → GitHub issue)
**Researched:** 2026-06-23
**Confidence:** HIGH

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Swift | 5.10+ | App language | Native macOS, first-class access to all required system APIs |
| SwiftUI `MenuBarExtra` | macOS 13+ | Menu-bar UI/scene | Native, reactive menu-bar app with minimal code; icon reflects state |
| AppKit (`NSStatusItem`/`NSPopover`) | macOS 13+ | Advanced menu-bar control | Fallback when `MenuBarExtra` window sizing/positioning is too limited |
| AVFoundation (`AVAudioEngine`/`AVAudioRecorder`) | macOS 13+ | Microphone capture | Records push-to-talk audio; can produce 16 kHz mono PCM for ASR |
| AVFoundation (`AVSpeechSynthesizer`) | macOS 13+ | Spoken confirmation | Native TTS for "created issue #NUMBER" (or `/usr/bin/say` as a simpler alt) |
| Foundation `Process` | — | Invoke external CLIs | Runs configured ASR/model CLIs and `gh` and captures stdout |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| sindresorhus/KeyboardShortcuts | latest (SPM) | Global push-to-talk hotkey | Registering a background, user-customizable shortcut with `onKeyDown`/`onKeyUp` |
| ServiceManagement (`SMAppService`) | macOS 13+ | Launch-at-login (optional) | Only if persistence across reboots is wanted; not required for v1 |

### External CLI Dependencies (user-provided, not bundled)

| Tool | Purpose | Notes |
|------|---------|-------|
| `gh` | Create the GitHub issue | `gh issue create --title --body`; must be authenticated |
| ASR CLI (e.g. `whisper-cli`/`whisper-cpp`) | Transcribe recorded WAV | Configurable command; whisper.cpp needs 16-bit 16 kHz mono WAV |
| Local model CLI (e.g. `ollama`, `llm`, a wrapper script) | Investigate repo, draft title/body | Configurable command; receives transcript + repo context |
| `ffmpeg` (optional) | Audio format conversion | Only if recording isn't already 16 kHz mono WAV |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode 15+ | Build/sign the app | Set `INFOPLIST_KEY_LSUIElement = YES`; disable App Sandbox for v1 |
| Swift Package Manager | Dependency management | Add KeyboardShortcuts via SPM |

## Installation

```bash
# App dependency (in Xcode: File > Add Package Dependencies)
https://github.com/sindresorhus/KeyboardShortcuts

# Example user-side CLIs (provided by the user, not the app)
brew install gh
brew install whisper-cpp ffmpeg
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `MenuBarExtra` (SwiftUI) | `NSStatusItem` + `NSPopover` (AppKit) | Need precise popover size/position or pre-macOS-13 support |
| sindresorhus/KeyboardShortcuts | Raw Carbon `RegisterEventHotKey` / `CGEventTap` | Want zero dependencies (much more archaic code, not worth it) |
| `AVSpeechSynthesizer` | `/usr/bin/say` via `Process` | Want the simplest possible TTS with no audio-session setup |
| `gh issue create` | GitHub REST API + token | Need to avoid the `gh` dependency (adds auth/token handling) |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `NSEvent.addGlobalMonitorForEvents` for the hotkey | Only copies events, can't consume; key still hits the foreground app | KeyboardShortcuts (real global hotkey) |
| App Sandbox (v1) | Blocks spawning arbitrary external CLIs (`gh`, ASR, model) | Ship non-sandboxed for v1 |
| Bundling a model runtime | Large, slow, contradicts the "configured CLI" decision | Configured external CLIs |

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| `MenuBarExtra` | macOS 13.0+ | Minimum deployment target for the app |
| KeyboardShortcuts | macOS 13+ / Swift 5.10+ | Works while an `NSMenu`/menu-bar app is active |

## Sources

- Apple Developer Docs — `MenuBarExtra`, `LSUIElement` (HIGH)
- github.com/sindresorhus/KeyboardShortcuts — README, push-to-talk `onKeyDown`/`onKeyUp` (HIGH)
- github.com/ggml-org/whisper.cpp — `whisper-cli` usage, 16 kHz mono WAV requirement (HIGH)
- techconcepts.org "macOS Menu Bar App ... 2026 Complete Guide" — NSStatusItem/NSPopover/SMAppService (MEDIUM)

---
*Stack research for: native macOS voice-to-issue menu-bar app*
*Researched: 2026-06-23*
