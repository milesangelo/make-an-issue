---
phase: 5
slug: concurrent-filing-jobs-model
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-28
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift Package Manager) |
| **Config file** | `Package.swift` (test target `MakeAnIssueTests`) |
| **Quick run command** | `swift test` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~{N} seconds (planner/executor to measure) |

---

## Sampling Rate

- **After every task commit:** Run `swift test`
- **After every plan wave:** Run `swift test`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** {N} seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| {N}-01-01 | 01 | 1 | CONCUR-{XX} | T-5-01 / — | {expected secure behavior or "N/A"} | unit | `swift test` | ✅ / ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*Populated by the planner/executor once plans exist. Note: the `onRunIssueFiling` / `onSpeak` /
`onRunTranscription` / `onCheckMicAuthorization` injection seams on `AppState` are the primary
automated-test surface for concurrency behavior (inject filing outcomes, capture spoken text).*

---

## Wave 0 Requirements

- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — rewrite `.filing`-asserting tests
      (`testFilingEntersFilingState`, `testPushToTalkDuringFilingIsIgnored`,
      `testStartRecordingAfterFilingReturnsToIdleStartsNewRecording`, `.filing` assertions in
      `testSuccessfulTranscriptionStoresText`) to the jobs-model contract

*Existing XCTest infrastructure covers all phase requirements — no framework install needed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| AVSpeechSynthesizer queues deferred announcements in order on macOS 13–15 | CONCUR-03 | OS-level TTS queue ordering cannot be asserted in a unit test; community reports flag possible regression | Trigger ≥3 concurrent filings, hold PTT through their completions, release; confirm announcements play back-to-back in order |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < {N}s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
