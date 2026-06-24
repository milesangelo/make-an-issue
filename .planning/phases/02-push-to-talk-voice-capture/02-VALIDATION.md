---
phase: 2
slug: push-to-talk-voice-capture
status: validated
nyquist_compliant: false
wave_0_complete: true
created: 2026-06-24
validated: 2026-06-24
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift Package Manager) |
| **Config file** | `Package.swift` (`MakeAnIssueTests` test target) |
| **Quick run command** | `swift test --filter AppStateTests` / `swift test --filter AudioRecorderTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~0.3 seconds (38 tests) |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter <SuiteUnderEdit>`
- **After every plan wave:** Run `swift test`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** ~1 second

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 2-01-01 | 01 | 1 | CAPTURE-01 | T-02-SC | Pinned, audited SPM dependency (KeyboardShortcuts 3.0.1) resolves and builds | build | `swift package resolve && swift build` | ✅ | ✅ green |
| 2-01-02 | 01 | 1 | CAPTURE-01, CAPTURE-02 | T-02-02 | State machine driven only by held shortcut; no always-listening path; D-04 repeat-ignore | unit | `swift test --filter AppStateTests` | ✅ | ✅ green |
| 2-02-01 | 02 | 2 | CAPTURE-02, CAPTURE-03 | T-02-03 | `NSMicrophoneUsageDescription` present so TCC gate can appear | lint | `plutil -lint Resources/Info.plist` | ✅ | ✅ green |
| 2-02-02 | 02 | 2 | CAPTURE-03 | T-02-04 | WAV path built only from `applicationSupportDirectory` + literals (no traversal); 16 kHz mono PCM settings | unit | `swift test --filter AudioRecorderTests` | ✅ | ✅ green |
| 2-02-03 | 02 | 2 | CAPTURE-02, CAPTURE-03 | T-02-EoP | Recorder driven through seam; mic-permission gate blocks recording when denied; full suite green | unit/build | `swift build && swift test` | ✅ | ✅ green |
| 2-02-04 | 02 | 2 | CAPTURE-01, CAPTURE-02, CAPTURE-03 | T-02-03 / T-02-05 | Background hotkey, TCC dialog, real WAV on disk, in-place overwrite — hardware behaviors | manual | — (see Manual-Only) | n/a | ✅ verified (UAT) |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

**Automated coverage detail:**
- `AppStateTests` (24 methods): initial idle state, start→recording, D-04 second-start-ignored, stop→finished, stop-while-idle no-op, re-record after finished (+ seam re-invocation), start/stop seam invocation, mic-permission-denied stays idle + status, recording timeout (manual + auto via `maxRecordingDuration`), timeout-while-idle no-op, recording-error reset, failed-start stays idle. (Also covers the Phase 1 repo-binding behaviors.)
- `AudioRecorderTests` (9 methods): `.wav` extension, `latest.wav` last component, path under `Application Support/MakeAnIssue`, `AVSampleRateKey == 16_000.0`, mono channel, `kAudioFormatLinearPCM`, 16-bit depth, stop-without-start safe, URL read has no filesystem side-effect (WR-03 purity).

---

## Wave 0 Requirements

Existing XCTest infrastructure (from Phase 1) covers all automatable phase requirements. No Wave 0 framework install or stub scaffolding was required — both plans added tests directly to the existing `MakeAnIssueTests` target via TDD.

---

## Manual-Only Verifications

These behaviors require real microphone hardware, the macOS TCC permission dialog, global keyboard input while another app is focused, and WAV-header inspection — none are reproducible in the headless `swift test` runner (per 02-RESEARCH.md "Requires Manual Hands-On Verification"). All were verified at the blocking human-verify checkpoint (Plan 02-02 Task 4) and re-confirmed in 02-UAT.md (7/7 pass, 0 issues).

| Behavior | Requirement | Why Manual | Test Instructions | UAT Result |
|----------|-------------|------------|-------------------|------------|
| Global hotkey fires while another app is focused (incl. after menu open/close) | CAPTURE-01 | Needs real OS-level global key events delivered to a backgrounded app | Focus Terminal/Safari, press Control-Option-I, confirm recording starts | ✅ pass (UAT 4) |
| Microphone TCC permission dialog appears with the usage string | CAPTURE-02 | Requires the live macOS TCC subsystem and user grant | Fresh launch → first record → "Allow" on the system dialog | ✅ pass (UAT 1) |
| Hold→Recording…, release→Done in the live menu indicator | CAPTURE-02 | Requires real key hold/release + SwiftUI MenuBarExtra rendering | Hold shortcut, open menu (Recording…), release, reopen (Done) | ✅ pass (UAT 2,3) |
| Real 16 kHz mono PCM WAV written to disk | CAPTURE-03 | Requires real audio capture; only the settings dict is unit-tested | `file`/`afinfo ~/Library/Application Support/MakeAnIssue/latest.wav` → RIFF/WAVE, 16000 Hz, 1 ch, 16-bit | ✅ pass (UAT 6) |
| In-place overwrite, no timestamped history (D-07) | CAPTURE-03 | Requires two real recordings on disk to compare | Record twice; confirm same path, updated mtime, no sibling files | ✅ pass (UAT 6) |
| Shortcut reconfiguration via menu Recorder (D-01) | CAPTURE-01 | Requires live `KeyboardShortcuts.Recorder` UI interaction | Change combo in menu; new combo triggers, old one does not | ✅ pass (UAT 7) |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or are documented Manual-Only with UAT evidence
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (none — existing infra sufficient)
- [x] No watch-mode flags
- [x] Feedback latency < 1s
- [ ] `nyquist_compliant: true` — **not set**: each of CAPTURE-01/02/03 has an irreducibly-manual hardware half (verified via human checkpoint + UAT, not the automated runner)

**Approval:** validated PARTIAL 2026-06-24 — automatable surface fully covered (38 tests green); hardware behaviors manual-only and UAT-verified.

---

## Validation Audit 2026-06-24

| Metric | Count |
|--------|-------|
| Gaps found | 0 (automatable) |
| Resolved | 0 |
| Escalated to manual-only | 6 |

The VALIDATION.md was an unfilled template stub; this audit reconstructed it from 02-01/02-02 PLAN + SUMMARY, the live `AppStateTests`/`AudioRecorderTests` suites, and 02-UAT.md. No automatable coverage gaps were found, so no `gsd-nyquist-auditor` run or new test generation was required. The six hardware behaviors are classified Manual-Only and were verified at the Plan 02-02 blocking checkpoint and UAT.
