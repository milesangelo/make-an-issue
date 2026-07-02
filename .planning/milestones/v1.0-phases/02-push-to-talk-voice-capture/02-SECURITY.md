---
phase: 02
slug: push-to-talk-voice-capture
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-24
---

# Phase 02 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| OS global hotkey monitor → app | OS delivers global key events via Carbon hotkey registration (KeyboardShortcuts). App does not read raw keystrokes from other apps. | Registered key-combo events only |
| SPM dependency supply chain | `KeyboardShortcuts` source fetched from GitHub at resolve time. | Third-party source code |
| Microphone → app (TCC) | OS gates microphone access behind a user-granted TCC permission; app declares usage string and requests access. | Audio (voice) |
| App → filesystem (Application Support) | App writes recording file to a user-domain directory it constructs itself. | WAV audio at rest |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-02-01 | Spoofing | Global shortcut registration | accept | First-registered-hotkey-wins is OS-level; not mitigable at app layer. Local single-user utility. | closed |
| T-02-02 | Elevation of Privilege | Global key monitoring | accept | Carbon `RegisterEventHotKey` requires no Accessibility/Input-Monitoring permission and cannot read arbitrary keystrokes — only the registered combo. | closed |
| T-02-SC | Tampering | SPM supply chain (KeyboardShortcuts) | accept | Package Legitimacy Audit (02-RESEARCH.md) verified package (verdict OK, author Sindre Sorhus); pinned `from: "3.0.1"`, revision committed in `Package.resolved`. | closed |
| T-02-03 | Information Disclosure | Microphone capture | accept | Recording only while shortcut physically held (push-to-talk, D-03); no always-listening path. `NSMicrophoneUsageDescription` + explicit permission request at startup. | closed |
| T-02-04 | Tampering | WAV output path | accept | Output path built from `FileManager.urls(for: .applicationSupportDirectory)` + hardcoded `MakeAnIssue`/`latest.wav` literals — no user-controlled path components, no traversal. | closed |
| T-02-05 | Information Disclosure | latest.wav at rest | accept | Single local recording overwritten in place (D-07) under user's own Application Support directory; standard macOS file permissions. No at-rest encryption for v1. | closed |
| T-02-EoP | Elevation of Privilege | Recording without consent | accept | `AVAudioRecorder.record()` never called before permission requested; on denial the recorder fails into a no-op rather than capturing. | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-02-01 | T-02-01 | Hotkey spoofing not mitigable at app layer; local single-user, low-value target. | user | 2026-06-24 |
| AR-02-02 | T-02-02 | Carbon hotkey API exposes no keystroke-logging surface; no permission escalation. | user | 2026-06-24 |
| AR-02-03 | T-02-SC | KeyboardShortcuts vetted in legitimacy audit and version-pinned; residual supply-chain risk accepted. | user | 2026-06-24 |
| AR-02-04 | T-02-03 | Push-to-talk-only capture + TCC permission prompt; residual mic-capture risk accepted for v1. | user | 2026-06-24 |
| AR-02-05 | T-02-04 | Output path uses only library-derived + hardcoded components; residual path risk accepted. | user | 2026-06-24 |
| AR-02-06 | T-02-05 | Local single-user WAV under standard file permissions; no at-rest encryption for v1. | user | 2026-06-24 |
| AR-02-07 | T-02-EoP | Permission gated before record; residual without-consent risk accepted. | user | 2026-06-24 |

*Accepted risks do not resurface in future audit runs.*

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-24 | 7 | 7 | 0 | user (accept-all, documented) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-24
