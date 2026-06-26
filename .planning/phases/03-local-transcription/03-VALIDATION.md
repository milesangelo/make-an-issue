---
phase: 03
slug: local-transcription
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-25
---

# Phase 03 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Reset 2026-06-25 for the bundled-whisper rework. Derived from `03-RESEARCH.md` § Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest |
| **Config file** | `Package.swift` → `.testTarget("MakeAnIssueTests")` (no external config) |
| **Quick run command** | `swift test --filter MakeAnIssueTests.TranscriberTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~7 seconds (baseline: 112 tests, 0 failures, verified 2026-06-25) |

---

## Sampling Rate

- **After every task commit:** Run `swift test`
- **After every plan wave:** Run `swift test` (full suite)
- **Before `/gsd-verify-work`:** Full suite green (112 baseline − removed tests + new tests) **PLUS** manual smoke test via the assembled `.app`
- **Max feedback latency:** ~10 seconds (automated); manual smoke is a one-time phase-gate check

---

## Per-Task Verification Map

> Task IDs are bound by the planner/executor; requirement-level coverage below is the contract each task inherits.
> The real `whisper-cli` + ~466 MB model MUST NOT run in unit tests — the automatable boundary is `AppState.onRunTranscription` (tests inject a stub; only the production default closure calls `Transcriber.run`).

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | 03 | 1 | TRANSCRIBE-01 | T-Supply (V10) | `fetch-whisper.sh` verifies pinned SHA256 of binary + model (`shasum -a 256 -c`); aborts on mismatch | Manual (script run) | n/a — network fetch + ~466 MB | Manual only | ⬜ pending |
| TBD | 03 | 1 | TRANSCRIBE-01 | T-DoS | Bundled `whisper-cli` ad-hoc signed (`codesign -s -`); not Gatekeeper-blocked locally | Manual (assembled `.app` smoke) | n/a — real binary | Manual only | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-01 | — | `bundledResourcesMissing` error thrown when binary/model absent from bundle | unit | `swift test --filter TranscriberTests` | ❌ W0 | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-01 | T-Input (V5) | `run(wavURL:)` builds correct argv (`-m`, `-f <quoted wav>`, `-l en`, `-nt`); WAV path POSIX-quoted | unit (fake whisper-cli echo script) | `swift test --filter TranscriberTests` | ❌ W0 | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-01 | — | Old `emptyCommand` / `missingWavToken` error cases removed (compile guard) | compilation guard | `swift test` (fails if old cases remain) | ❌ W0 | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-01 | — | AppState enters `.transcribing` after `stopRecording` | unit (existing) | `swift test --filter AppStateTests/testStopRecordingTransitionsToTranscribing` | ✅ Exists | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-02 | — | Successful transcription stores trimmed transcript text | unit (existing, seam) | `swift test --filter AppStateTests/testSuccessfulTranscriptionStoresText` | ✅ Exists | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-02 | — | `bundledResourcesMissing` failure resets state to usable + surfaces status | unit (seam) | `swift test --filter AppStateTests` | ❌ W0 | ⬜ pending |
| TBD | 04 | 2 | TRANSCRIBE-02 | T-DoS | Timeout error resets state to usable | unit (existing, seam) | `swift test --filter AppStateTests/testTimeoutResetsState` | ✅ Exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/MakeAnIssueTests/TranscriberTests.swift` — **DELETE** all existing `prepare(command:wavURL:)` tests (method removed). **ADD**:
  - `testBundledBinaryURLThrowsWhenResourcesNil` — `Bundle.main.resourceURL` nil condition
  - `testBundledModelURLThrowsWhenModelAbsent`
  - `testRunConstructsCorrectCommand` — temp-dir fake `whisper-cli` echo script; assert argv contains `-l en -nt` and quoted WAV path
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — **DELETE** `testEmptyCommandShowsError` (tests removed `TranscriberError.emptyCommand`). **ADD**:
  - `testBundledResourcesMissingResetsStateAndSurfacesStatus` (mirrors `testTimeoutResetsState`)

*No new framework needed — XCTest already configured.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Bundled `whisper-cli` + `ggml-small.en.bin` transcribe a real recording end-to-end | TRANSCRIBE-01/02 | Requires the real ~466 MB model + hardware mic; cannot run in unit tests | Build `.app` via `scripts/build-app.sh`; hold shortcut, speak, release; confirm transcript appears in menu/log |
| Ad-hoc-signed bundled binary runs without Gatekeeper block (local machine) | TRANSCRIBE-01 | Gatekeeper/quarantine behavior only observable on a real launch of the assembled `.app` | Launch built `.app`; confirm transcription runs (no "cannot be opened" dialog) |
| `fetch-whisper.sh` builds `whisper-cli` from source + downloads model with checksum match | TRANSCRIBE-01 | Network fetch + cmake build; ~466 MB; not a unit test | Run `scripts/fetch-whisper.sh`; confirm `vendor/whisper-cli` + model present and `shasum -a 256 -c` passes; run `otool -L vendor/whisper-cli` (no `/opt/homebrew/` paths) |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies (or are documented Manual-Only)
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (TranscriberTests rework, AppStateTests additions)
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
