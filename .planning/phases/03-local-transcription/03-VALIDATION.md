---
phase: 03
slug: local-transcription
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-24
---

# Phase 03 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from `03-RESEARCH.md` § Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift 6.3.2 / Xcode 26.5) |
| **Config file** | `Package.swift` → `.testTarget("MakeAnIssueTests")` |
| **Quick run command** | `swift test` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~few seconds (baseline: 38 tests, 0 failures) |

---

## Sampling Rate

- **After every task commit:** Run `swift test`
- **After every plan wave:** Run `swift test` (full suite)
- **Before `/gsd-verify-work`:** Full suite green (38 baseline + new tests)
- **Max feedback latency:** ~10 seconds

---

## Per-Task Verification Map

> Task IDs are bound by the planner/executor; requirement-level coverage below is the contract each task inherits.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | 01 | 1 | TRANSCRIBE-02 | — | CLIRunner captures stdout separately | unit (real `/bin/echo`) | `swift test --filter CLIRunnerTests` | ❌ W0 | ⬜ pending |
| TBD | 01 | 1 | TRANSCRIBE-02 | T-DoS | CLIRunner 120s timeout terminates process, resolves once | unit | `swift test --filter CLIRunnerTests/testTimeout` | ❌ W0 | ⬜ pending |
| TBD | 02 | 2 | TRANSCRIBE-01 | T-Tampering | Empty command → no spawn, clear error | unit | `swift test --filter AppStateTests/testEmptyCommandShowsError` | ❌ W0 | ⬜ pending |
| TBD | 02 | 2 | TRANSCRIBE-01 | T-Input | Missing `{wav}` → no spawn, clear error | unit | `swift test --filter TranscriberTests/testMissingWavTokenError` | ❌ W0 | ⬜ pending |
| TBD | 02 | 2 | TRANSCRIBE-01 | T-Tampering | `{wav}` substituted as shell-safe quoted path | unit | `swift test --filter TranscriberTests/testWavSubstitutionQuoting` | ❌ W0 | ⬜ pending |
| TBD | 02 | 2 | TRANSCRIBE-01 | — | `.transcribing` state shown after key-up | unit (seam) | `swift test --filter AppStateTests/testStopRecordingTransitionsToTranscribing` | ❌ W0 | ⬜ pending |
| TBD | 02 | 2 | TRANSCRIBE-02 | — | stdout trimmed, stored in `transcript`, state → `.finished` | unit (seam) | `swift test --filter AppStateTests/testSuccessfulTranscriptionStoresText` | ❌ W0 | ⬜ pending |
| TBD | 02 | 2 | TRANSCRIBE-02 | — | Failure/timeout → clear error + state reset to usable | unit (seam) | `swift test --filter AppStateTests/testTimeoutResetsState` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/MakeAnIssueTests/CLIRunnerTests.swift` — CLIRunner stdout/stderr/exit/timeout/cwd with real `/bin/echo` (no ASR binary)
- [ ] `Tests/MakeAnIssueTests/TranscriberTests.swift` — `prepare()` substitution, single-quote/space quoting, trim, validation errors
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` additions — transcription state machine via the existing closure-seam (stub `onRunTranscription`)

*No new framework needed — XCTest already configured.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real speech → WAV → real ASR CLI → transcript text | TRANSCRIBE-01/02 | Requires hardware mic + an installed ASR binary | Hold shortcut, speak, release; confirm transcript appears |
| Login-shell PATH finds Homebrew ASR tool from GUI app | TRANSCRIBE-01 | GUI-launched PATH differs from terminal; only real launch proves `/bin/zsh -lc` inherits it | Configure `whisper {wav} ...`, run from built `.app` |
| "Transcribing…" status visible in menu during slow run | TRANSCRIBE-01 | Timing/visual; needs a real slow model run | Observe menu between release and transcript |
| Transcript selectable in menu + `NSLog` in Console.app | TRANSCRIBE-02 | Visual/UI + system log inspection | Open menu; check Console.app for NSLog line |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (CLIRunnerTests, TranscriberTests, AppStateTests additions)
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
