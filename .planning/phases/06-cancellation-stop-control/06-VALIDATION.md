---
phase: 6
slug: cancellation-stop-control
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-29
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (already configured) |
| **Config file** | Package.swift (existing target `MakeAnIssueTests`) |
| **Quick run command** | `swift test --filter CLIRunnerTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~{N} seconds |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter CLIRunnerTests` (or `--filter AppStateTests` for AppState work)
- **After every plan wave:** Run `swift test`
- **Before `/gsd-verify-work`:** Full suite must be green + manual `pgrep -f claude` / `docker ps` showing zero orphans
- **Max feedback latency:** {N} seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| {N}-01-01 | 01 | 1 | REQ-{XX} | T-{N}-01 / — | {expected secure behavior or "N/A"} | unit | `{command}` | ✅ / ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*Derive the full map from RESEARCH.md `## Validation Architecture` → Phase Requirements → Test Map (CANCEL-01/02/03).*

---

## Wave 0 Requirements

- [ ] `Tests/MakeAnIssueTests/CLIRunnerTests.swift` — stubs for `testCancelKillsProcessGroup`, `testCancelAndExitBoundaryResolvesExactlyOnce`
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — stubs for `testCancelJobId*`, `testCancelAll*`, `testCancelledJobStateAndAnnouncement`

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Zero orphaned `claude` process / leaked `--rm` container after cancel | CANCEL-01 | Requires a real `claude`/`docker` process; not feasible in CI (use `sleep 60` subprocess + `kill(pid,0)`==ESRCH for the automated proxy) | After a live cancel, run `pgrep -f claude` and `docker ps` — both must show no make-an-issue artifacts |

*If none: "All phase behaviors have automated verification."*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < {N}s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** {pending / approved YYYY-MM-DD}
