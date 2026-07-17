---
phase: 08
slug: editable-system-prompt-finding-06-cleanup
status: verified
threats_open: 0
asvs_level: unspecified
created: 2026-07-01
---

# Phase 08 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

Register authored at plan time (all three 08-0x-PLAN.md files carried a `<threat_model>` block). Verified in **verify-mitigations** mode — the gsd-security-auditor confirmed each disposition against the implemented code, re-running 94 targeted tests independently. No new attack surface appeared beyond the register. ASVS level was not asserted in any PLAN `<config>` block, so it is recorded as unspecified.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| user input in TextEditor → `@AppStorage(instructionsKey)` | Untrusted free-text guidance persisted to UserDefaults; consumed only as prompt guidance | Free-text drafting instructions |
| user-editable instructions → prompt assembly (`buildPrompt`) | Guidance is interpolated into the `-p` prompt body, framed by app-owned text before and after | Free-text (untrusted) |
| prompt assembly → AI CLI subprocess flags (`assembleCommand`) | The scoped `--allowedTools` grant is a command-line flag, structurally separate from the prompt body | App-owned tool-scope grant |
| persisted `UserDefaults(instructionsKey)` → per-filing read | Guidance is read fresh at each filing spawn and captured by value (no cross-job staleness) | Free-text (untrusted) |
| enforced-contract display → user | Read-only surface that must truthfully reflect what the app actually appends | App-owned trailer + tool grant (read-only) |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-08-01 | Tampering | Prompt-injection guidance suppressing the URL trailer / redefining the file-it directive | mitigate | `enforcedTrailer` + file-it directive appended by the app AFTER editable guidance in `buildPrompt` (`IssueFilingRunner.swift:43-48`, `:86-96`); test `testBuildPromptWithArbitraryInstructionsEndsWithEnforcedTrailer` (PASS) | closed |
| T-08-02 | Elevation of Privilege | Guidance attempting to escalate tool scope | mitigate | `--allowedTools` built by `assembleCommand` from `config.allowedToolsArgument`, independent of `instructions` (`IssueFilingRunner.swift:105-116`); test `testAssembleCommandStillContainsScopedAllowedToolsWithArbitraryInstructions` (PASS) | closed |
| T-08-03 | Denial of Service | Blank/whitespace guidance → degraded/empty prompt | mitigate | D-08 trim-and-fallback to `IssueFilingConfig.defaultInstructions` (`IssueFilingRunner.swift:81-84`); blank + whitespace-only tests (PASS) | closed |
| T-08-04 | Information Disclosure | Stale `"cliCommand"` value left in UserDefaults on upgrade | accept | `cliCommandKey` symbol fully removed; only a doc-comment prose mention remains (`AppState.swift:22`); never read back — harmless orphan, no migration needed | closed |
| T-08-05 | Tampering | Persisted instructions consumed downstream by the runner | mitigate | View's only write path is `@AppStorage(AppState.instructionsKey)` (`SettingsView.swift:7`); no path to `--allowedTools`/trailer — enforcement owned by `buildPrompt`/`assembleCommand` | closed |
| T-08-06 | Information Disclosure (misleading UI) | Read-only enforced-contract display drifting from the real appended contract | mitigate | Display renders `IssueFilingRunner.enforcedTrailer` + `IssueFilingConfig.claudeGitHub.allowedToolsArgument` directly, no hardcoded copy (`SettingsView.swift:44-45`) | closed |
| T-08-07 | Tampering | Accidental removal of unrelated popover state during cleanup | mitigate | Deletion scoped to the `DisclosureGroup`/`cliCommand`; `shortcutText`/`ActionCard`/`ShortcutPillView` intact (`MenuView.swift`); `swift build` + `AppStateTests` green | closed |
| T-08-08 | Information Disclosure | Parser mis-picks a spurious GitHub URL from model output | accept | `IssueResultParser` unchanged this phase (last touched phase-04); `enforcedTrailer` puts canonical `Issue URL:` on the last line; editable field is guidance-only, never parsed | closed |
| T-08-09 | Tampering | Concurrent filings reading stale/shared instructions state | mitigate | `AppState.currentPersistedInstructions()` (`nonisolated static`, fresh UserDefaults read, no caching — `AppState.swift:29-33`), called at invocation time by the default closure (`:118-124`); test `testCurrentPersistedInstructionsReadsFreshPerInvocation` (PASS) | closed |
| T-08-10 | Denial of Service | User clears the field entirely | mitigate | Same D-08 blank-fallback as T-08-03 (`IssueFilingRunner.swift:81-84`) — a cleared field is indistinguishable from blank at build time | closed |
| T-08-SC | Tampering | npm/pip/cargo installs (supply chain) | accept | No package installs this phase — `Package.swift` unchanged (last touched phase-01/02); no new dependency, no `[ASSUMED]`/`[SUS]` packages | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*
*T-08-03 and T-08-10 share one physical mitigation (the D-08 blank-fallback).*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-08-01 | T-08-04 | Stale `cliCommand` UserDefaults value is never read back (dead on removal); a silent orphan is harmless and a drop is acceptable (CONTEXT "Claude's Discretion"); no migration code added | milesangelo | 2026-07-01 |
| AR-08-02 | T-08-08 | `IssueResultParser` is explicitly out of scope this phase; residual model-output URL ambiguity is pre-existing accepted parser behavior; the editable field is guidance-only and never parsed | milesangelo | 2026-07-01 |
| AR-08-03 | T-08-SC | No dependencies added or changed this phase (`Package.swift` unchanged); no supply-chain surface introduced | milesangelo | 2026-07-01 |

*Accepted risks do not resurface in future audit runs.*

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-07-01 | 11 | 11 | 0 | gsd-security-auditor (verify-mitigations mode) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-07-01
