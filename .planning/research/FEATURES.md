# Feature Research

**Domain:** Voice-driven GitHub issue creation from a macOS menu bar
**Researched:** 2026-06-23
**Confidence:** HIGH

## Feature Landscape

### Table Stakes (Users Expect These)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Repo-bound launch from a command | Issues must go to the right repo | MEDIUM | Bind to git root of the launching cwd |
| Global push-to-talk shortcut | Hands-on-keyboard capture from any app | MEDIUM | KeyboardShortcuts `onKeyDown`/`onKeyUp` |
| Reliable microphone capture | Garbage audio = garbage issue | MEDIUM | 16 kHz mono WAV for ASR; Mic permission |
| Accurate local transcription | The transcript drives everything downstream | LOW (delegated) | Delegated to configured ASR CLI |
| Repo-aware issue draft | Title/body should reflect the actual repo | MEDIUM | Delegated to configured model CLI |
| Automatic `gh issue create` | The whole point is "say it, file it" | LOW | `gh issue create --title --body` |
| Spoken confirmation with number | Confirms success without looking at screen | LOW | TTS "created issue #NUMBER" |

### Differentiators (Competitive Advantage)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Fully local ASR + analysis | Private; no transcript leaves the machine | LOW (delegated) | Core positioning vs cloud dictation tools |
| Zero-UI capture (voice in, voice out) | Never break flow to file an issue | MEDIUM | Push-to-talk + spoken confirmation |
| Repo context injected into the draft | Better issues than raw dictation | MEDIUM | Model CLI sees repo, not just words |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Always-on wake phrase | "Hands-free everything" | Battery/privacy, false triggers, mic always hot | Push-to-talk shortcut |
| In-app model hosting | "One app does it all" | Huge binary, GPU/mem management, slow | Configured external CLIs |
| Multi-repo switcher UI | "Manage all my repos" | UI/state complexity, ambiguous binding | Bind to launching command's cwd |
| Pre-submit review/edit screen | "Let me fix the text" | Breaks the fast voice-only flow | Automatic create in v1, review in v2 |

## Feature Dependencies

```
Repo-bound launch
    └──required by──> Issue creation (gh runs in the bound repo)

Push-to-talk capture
    └──produces──> WAV file
                       └──required by──> Transcription (ASR CLI)
                                              └──produces──> Transcript
                                                                 └──required by──> Repo investigation (model CLI)
                                                                                        └──produces──> Title + Body
                                                                                                           └──required by──> gh issue create
                                                                                                                                  └──produces──> Issue number
                                                                                                                                                     └──required by──> Spoken confirmation
```

### Dependency Notes

- **gh issue create requires repo-bound launch:** `gh` resolves the repo from the working directory; binding must happen first.
- **Transcription requires capture:** the ASR CLI needs the recorded WAV as input.
- **Investigation requires transcription:** the model CLI needs the transcript text plus repo context.
- **Confirmation requires creation:** the spoken number is parsed from `gh` output.

## MVP Definition

### Launch With (v1)

- [ ] Repo-bound launch/activation from a command — routes issues to the correct repo
- [ ] Global push-to-talk capture to WAV — the input mechanism
- [ ] Transcription via configured ASR CLI — turns audio into text
- [ ] Repo investigation via configured model CLI — turns text + repo into title/body
- [ ] Automatic `gh issue create` + spoken confirmation — the payoff

### Add After Validation (v1.x)

- [ ] Pre-submit review/edit of title/body — once the happy path is trusted
- [ ] Basic error surfacing for missing repo/CLI/`gh` failure — harden after happy path works
- [ ] Configurable issue labels/assignees — once core flow is stable

### Future Consideration (v2+)

- [ ] Multi-repo selection UI — when single-repo binding proves limiting
- [ ] Wake-phrase / always-on mode — only if push-to-talk proves insufficient
- [ ] Retry/queue for offline or failed creation — advanced recovery

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Repo-bound launch | HIGH | MEDIUM | P1 |
| Push-to-talk capture | HIGH | MEDIUM | P1 |
| Transcription (ASR CLI) | HIGH | LOW | P1 |
| Repo investigation (model CLI) | HIGH | MEDIUM | P1 |
| Auto issue create + spoken confirm | HIGH | LOW | P1 |
| Review/edit screen | MEDIUM | MEDIUM | P3 |
| Multi-repo UI | MEDIUM | HIGH | P3 |

**Priority key:** P1 must have for launch; P2 should have; P3 future.

## Sources

- Product positioning inferred from menu-bar utility patterns (iStat Menus, Itsycal, dictation tools)
- whisper.cpp + `gh` capabilities define the delegated feature set

---
*Feature research for: voice-to-issue menu-bar app*
*Researched: 2026-06-23*
