# Roadmap: make-an-issue

## Overview

A vertical-MVP "walking skeleton" that thickens one pipeline stage at a time. We first stand up
a repo-bound menu-bar agent, then add push-to-talk capture, local transcription, repo-aware
drafting, and finally automatic `gh` issue creation with a spoken confirmation. Each phase ends
in a hands-on, manually testable result, and together the five phases deliver the complete v1
happy path: speak a thought → a GitHub issue is filed in the right repo → the number is spoken back.

## Phases

- [ ] **Phase 1: Menu-Bar App + Repo-Bound Launch** - A no-Dock menu-bar agent a repo-local command launches/activates, bound to that repo
- [ ] **Phase 2: Push-to-Talk Voice Capture** - Global shortcut records mic audio to an ASR-ready WAV while held
- [ ] **Phase 3: Local Transcription** - Configured ASR CLI turns the recording into transcript text
- [ ] **Phase 4: Repo Investigation → Issue Draft** - Configured model CLI turns transcript + repo context into a title and body
- [ ] **Phase 5: Automatic Issue Creation + Spoken Confirmation** - `gh issue create` files the issue and the number is spoken aloud

## Phase Details

### Phase 1: Menu-Bar App + Repo-Bound Launch
**Goal**: A native macOS menu-bar utility that a repo-local command launches (or activates if already running) and binds to the git repo of that command's working directory.
**Depends on**: Nothing (first phase)
**Requirements**: LAUNCH-01, LAUNCH-02, LAUNCH-03
**Success Criteria** (what must be TRUE):
  1. Running the repo-local command from a git repo shows a menu-bar icon and no Dock icon.
  2. Running the command a second time activates the same instance rather than spawning a duplicate.
  3. The menu shows the bound repository (the git root of the launching directory).
**Plans**: TBD

Plans:
- [ ] 01-01: SwiftUI `MenuBarExtra` app shell (`LSUIElement`, `.window` style, non-sandboxed) showing status
- [ ] 01-02: Repo-local launcher command + single-instance activation + cwd hand-off
- [ ] 01-03: Resolve git root from cwd and display the bound repo in the menu

### Phase 2: Push-to-Talk Voice Capture
**Goal**: A user-configurable global shortcut records microphone audio while held and writes an ASR-ready WAV on release.
**Depends on**: Phase 1
**Requirements**: CAPTURE-01, CAPTURE-02, CAPTURE-03
**Success Criteria** (what must be TRUE):
  1. The global shortcut fires while another app is focused (background hotkey works).
  2. Holding the shortcut records and releasing it stops, with the menu reflecting the recording state.
  3. A 16 kHz mono WAV file is produced from the spoken audio.
**Plans**: TBD

Plans:
- [ ] 02-01: Integrate KeyboardShortcuts; configurable push-to-talk shortcut with `onKeyDown`/`onKeyUp`
- [ ] 02-02: AVFoundation mic capture to 16 kHz mono WAV + microphone permission handling

### Phase 3: Local Transcription
**Goal**: Invoke the user-configured local ASR CLI on the recorded WAV and capture the transcript text.
**Depends on**: Phase 2
**Requirements**: TRANSCRIBE-01, TRANSCRIBE-02
**Success Criteria** (what must be TRUE):
  1. Releasing the shortcut runs the configured ASR command on the recording.
  2. The transcript text is captured and shown (menu/log) for the request.
**Plans**: TBD

Plans:
- [ ] 03-01: Shared `CLIRunner` (`Process` wrapper: working dir, configurable PATH, stdout/exit capture)
- [ ] 03-02: Transcriber — run configured ASR command on the WAV and capture transcript text

### Phase 4: Repo Investigation → Issue Draft
**Goal**: Invoke the user-configured local model CLI with the transcript and bound-repo context, and parse the output into an issue title and body.
**Depends on**: Phase 3
**Requirements**: ANALYZE-01, ANALYZE-02
**Success Criteria** (what must be TRUE):
  1. The configured model command runs with the transcript and bound-repo context.
  2. The model output is parsed into a distinct issue title and body.
**Plans**: TBD

Plans:
- [ ] 04-01: Investigator — invoke configured model command with transcript + repo context
- [ ] 04-02: Parse model output into title + body

### Phase 5: Automatic Issue Creation + Spoken Confirmation
**Goal**: Create the issue automatically with `gh issue create` in the bound repo, parse the issue number, and speak "created issue #NUMBER".
**Depends on**: Phase 4
**Requirements**: ISSUE-01, ISSUE-02, FEEDBACK-01
**Success Criteria** (what must be TRUE):
  1. `gh issue create` runs in the bound repo with the generated title and body and a real issue is created.
  2. The issue number is parsed from the `gh` output after a success exit code.
  3. The app speaks "created issue #NUMBER" via native text-to-speech.
**Plans**: TBD

Plans:
- [ ] 05-01: IssueCreator — `gh issue create` in bound repo + parse issue number from output
- [ ] 05-02: SpeechOutput — speak "created issue #NUMBER" and wire the end-to-end happy path

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Menu-Bar App + Repo-Bound Launch | 0/3 | Not started | - |
| 2. Push-to-Talk Voice Capture | 0/2 | Not started | - |
| 3. Local Transcription | 0/2 | Not started | - |
| 4. Repo Investigation → Issue Draft | 0/2 | Not started | - |
| 5. Automatic Issue Creation + Spoken Confirmation | 0/2 | Not started | - |
