---
phase: 7
slug: appkit-status-item-ui-settings-window-shell
status: verified
threats_open: 0
asvs_level: 1
created: 2026-07-01
---

# Phase 7 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| user ↔ menu-bar UI | Local single-user interaction (click/keyboard). No network, IPC, or untrusted input crosses here. | None (local UI events) |
| Quit menu item → process teardown | Right-click "Quit" routes into the existing app-termination path that tears down in-flight subprocess trees. | Process signals (SIGTERM/SIGKILL) |

Phase 7 adds NO new input surfaces, data stores, network, or subprocess calls, and no external packages (07-RESEARCH.md § Security Domain). No supply-chain install vector.

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-07-01 | Tampering | Quit item → `NSApplication.terminate(_:)` → `applicationShouldTerminate` | accept | Quit routes through the preserved Phase 6 teardown (`cancelAll()` SIGTERM → 2s grace → `forceKillAllProcessTrees()` SIGKILL → `sweepMCPTempFiles()`); `applicationShouldTerminate` preserved verbatim. Accepted without a dedicated audit pass this run — see Accepted Risks Log R-07-01. | closed |
| T-07-02 | Spoofing | `showSettingsWindow` / `togglePopover` → `NSApp.activate(ignoringOtherApps: true)` | accept | Intentional and required for an LSUIElement app to give the Settings window / popover real keyboard focus (Pitfall 8/9). No user data exposed in the empty Settings shell; single-user local app. | closed |
| T-07-03 | (none introduced) | `MenuView` popover content (removals only) | accept | No STRIDE-applicable threat added: the change deletes a shortcut editor and a notification post. Push-to-talk availability is a functional property proven by manual UAT, not a security control. | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| R-07-01 | T-07-01 | Quit-teardown mitigation is planned/implemented in AppDelegate (Phase 6 path preserved verbatim per 07-01-PLAN Task 2) and behaviorally verified by UAT Test 5 (clean exit, no orphaned processes/containers). Accepted for this security run without a separate auditor pass. | milesangelo | 2026-07-01 |
| R-07-02 | T-07-02 | Foreground activation for an LSUIElement app is an intentional, required focus behavior; single-user local app with no data exposure. | milesangelo | 2026-07-01 |
| R-07-03 | T-07-03 | UI/code removals only; introduces no new STRIDE-applicable surface. | milesangelo | 2026-07-01 |

*Accepted risks do not resurface in future audit runs.*

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-01 | 3 | 3 | 0 | milesangelo (/gsd-secure-phase — accept-all) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-07-01
