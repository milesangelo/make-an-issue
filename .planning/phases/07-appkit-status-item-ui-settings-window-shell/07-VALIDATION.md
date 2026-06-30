---
phase: 7
slug: appkit-status-item-ui-settings-window-shell
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-30
---

# Phase 7 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `07-RESEARCH.md` § Validation Architecture. Phase 7 is an AppKit-shell phase —
> nearly all behaviors require a running macOS app on real hardware across macOS 13/14/15,
> so automated coverage is limited to a model-layer regression guard.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (existing — `Tests/MakeAnIssueTests/`) |
| **Config file** | `Package.swift` (existing test target) |
| **Quick run command** | `swift test --filter AppStateTests 2>&1` |
| **Full suite command** | `swift test 2>&1` |
| **Estimated runtime** | ~2s quick / full suite per local machine |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter AppStateTests 2>&1` (model regression guard, ~2s)
- **After every plan wave:** Run `swift test 2>&1` (full suite)
- **Before `/gsd-verify-work`:** Full suite green AND every Manual-Only item below verified
- **Max feedback latency:** ~2 seconds (automated guard)

---

## Per-Task Verification Map

> Task IDs are assigned by the planner. Phase 7's AppKit-shell behaviors cannot be unit-tested
> without a running app, so the per-task automated column is the regression guard; behavioral
> proof lives in **Manual-Only Verifications** below.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (assigned at planning) | — | — | SETTINGS-01 / FEEDBACK-02 | T-7 quit teardown | Quit routes through `applicationShouldTerminate` | regression | `swift test 2>&1` | ✅ existing | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- Existing infrastructure (AppStateTests, CLIRunnerTests, IssueFilingRunnerTests) covers the model
  layer. Phase 7 changes are confined to the AppKit shell, which is not practically unit-testable in
  XCTest without significant AppKit-event mocking.
- [ ] No new test files required. The automated obligation for Phase 7 is: `swift test 2>&1` stays
      green after `MenuBarExtra` removal and `MenuView` edits (model-layer regression guard).

*All net-new Phase 7 behaviors are manual-only — see below.*

---

## Manual-Only Verifications

> Full per-OS checklist (run on **macOS 13 Ventura, 14 Sonoma, 15 Sequoia**) lives in
> `07-RESEARCH.md` § "macOS Version UAT Checklist". Summary mapping:

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Right-click opens NSMenu with exactly "Settings…" and "Quit" (Control-click counts as right-click) | SETTINGS-01 | NSStatusItem interaction needs a running app | Right-click / Control-click the menu-bar icon; confirm the two-item menu |
| Left-click opens the status popover (MenuView content) | SETTINGS-01 | Requires running app | Left-click the icon; confirm popover with existing MenuView |
| "Settings…" opens a focusable self-owned window that takes keyboard focus | SETTINGS-01 | LSUIElement focus behavior needs real hardware | Choose Settings…; click the Recorder, press a key — it captures |
| Recorder moved to Settings window; popover Settings disclosure shows only the CLI Command field; `ShortcutPillView` still shows the shortcut read-only in ActionCard | SETTINGS-01 | Requires running app | Inspect popover + Settings window placement |
| Re-opening "Settings…" focuses the existing window (single-window) | SETTINGS-01 | Requires running app | Open Settings… twice; confirm no second window |
| Red recording indicator appears while `captureState == .recording`, absent during `.transcribing`/filing, reverts the instant recording stops | FEEDBACK-02 | NSStatusBarButton rendering needs a running app; layer approach unverified on 13/14/15 (A1) | Hold push-to-talk; watch the icon background; release |
| Quit menu item exits cleanly (Phase 6 `applicationShouldTerminate` teardown runs) | SETTINGS-01 | Requires running app | Choose Quit; confirm clean teardown |
| Global push-to-talk fires after popover open/close AND after menu open/close, with another app focused | SETTINGS-01 (hotkey survival) | Cross-app empirical behavior; `.menuOpen` rebalance change (A4) | Focus Finder; cycle popover/menu; press the shortcut each time |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify (regression guard) or are mapped to a Manual-Only row
- [ ] Sampling continuity: model-layer guard runs every commit; no silent gaps
- [ ] Wave 0 covers all MISSING references (none — existing infra + manual UAT)
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s (automated guard ~2s)
- [ ] Assumptions A1–A4 (07-RESEARCH.md) closed via macOS 13/14/15 UAT before phase verification
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
