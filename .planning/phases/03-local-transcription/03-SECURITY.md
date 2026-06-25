---
phase: 03
slug: local-transcription
status: secured
threats_open: 0
asvs_level: 1
created: 2026-06-25
---

# SECURITY.md — Phase 03: local-transcription

**Audit Date:** 2026-06-25
**ASVS Level:** 1
**Auditor:** gsd-security-auditor (automated)
**Phase Plans:** 03-01 (CLIRunner), 03-02 (Transcriber / AppState / MenuView)

---

## Threat Verification Summary

**Threats Closed:** 10/10
**Threats Open:** 0/10

---

## Threat Register

| Threat ID | Category | Component | Disposition | Status | Evidence |
|-----------|----------|-----------|-------------|--------|----------|
| T-03-01 | Tampering | CLIRunner.run command string | accept | CLOSED | Design boundary holds: command flows exclusively from UserDefaults (user-typed) via AppState.onRunTranscription default closure. No third-party input path to command. See accepted risks below. |
| T-03-02 | Information Disclosure | stdout/stderr capture | mitigate | CLOSED | CLIRunner.swift:82-98 — two distinct Pipe() instances; stdoutPipe/stderrPipe attached to separate readabilityHandlers. CLIResult.success carries stdout and stderr as distinct fields. Transcriber.swift:70 — `.success(let stdout, _, _)` discards stderr field; D-08 comment at line 72. |
| T-03-03 | Denial of Service | hung subprocess | mitigate | CLOSED | CLIRunner.swift:137-149 — timeout Task calls `try? await Task.sleep(for: timeout)` then `process.terminate()`. Single-resume via `RunState.claim()` NSLock (lines 51-58). CLIRunner.swift:72 — default `.seconds(120)`. |
| T-03-04 | Denial of Service | pipe-buffer deadlock | mitigate | CLOSED | CLIRunner.swift:90-98 — `readabilityHandler` attached to both stdoutPipe and stderrPipe BEFORE `process.run()`. 10 occurrences of `readabilityHandler` confirm concurrent drain; `readDataToEndOfFile()` absent from file. |
| T-03-05 | Tampering | {wav} path substitution in Transcriber.prepare() | mitigate | CLOSED | Transcriber.swift:43-45 — `replacingOccurrences(of: "'", with: "'\\''")` implements POSIX close/literal/reopen sequence; path wrapped in outer single quotes. TranscriberTests.swift:83-100 — `testPathWithSingleQuoteIsEscaped` asserts `'\''` sequence present. TranscriberTests.swift:43-60 — `testWavSubstitutionQuoting` asserts single-quoted wrapping for space-containing path. |
| T-03-06 | Tampering | empty / malformed ASR command | mitigate | CLOSED | Transcriber.swift:35-39 — `prepare()` throws `.emptyCommand` on whitespace-only command before any spawn; throws `.missingWavToken` when `{wav}` literal absent. AppStateTests.swift:336-354 — `testEmptyCommandShowsError` (captureState reset to .idle). TranscriberTests.swift:10-39 — `testEmptyCommandThrowsEmptyCommandError`, `testMissingWavTokenError`. |
| T-03-07 | Tampering | user-controlled command string contents | accept | CLOSED | Design boundary holds: command body is entirely user-typed; no third-party data reaches command body. Only {wav} substitution applies escaping. See accepted risks below. |
| T-03-08 | Spoofing/Tampering | transcript rendered in UI | mitigate | CLOSED | MenuView.swift:42-47 — transcript rendered exclusively via SwiftUI `Text(transcript)` with `.textSelection(.enabled)`; no eval, no parser, no further execution. Transcriber.swift:70-78 — only `stdout` field extracted from CLIResult.success; stderr never merged into transcript. |
| T-03-09 | Denial of Service | hung / runaway ASR process | mitigate | CLOSED | Transcriber.swift:64-65 — `.timeout` case throws `TranscriberError.asrTimedOut`. AppState.swift:196 — catch block for `TranscriberError` resets `captureState = .idle` (D-11). AppStateTests.swift:316-334 — `testTimeoutResetsState` asserts `.idle` state and timeout message. |
| T-03-SC | Tampering | npm/pip/cargo installs | mitigate | CLOSED | Package.swift contains exactly one external dependency (KeyboardShortcuts, pre-existing). No package.json, requirements.txt, Cargo.toml, Pipfile, or go.mod found at any level. Phase 03 sources use Foundation + SwiftUI exclusively. |

---

## Accepted Risks

### T-03-01 — Trusted user input to CLIRunner command string

**Category:** Tampering
**Accepted by:** Design decision D-02 (PROJECT.md)
**Rationale:** The command string executed via `/bin/zsh -lc` is typed directly by the user into the MenuView ASR command TextField. This is equivalent to the user running a command in their own terminal with their own privileges. The app is non-sandboxed by design (required for Homebrew tool access). No third-party or remote input reaches the command body; the only injected value is the WAV file path, which is escaped (T-03-05). SIGKILL escalation after SIGTERM ignore is accepted as a v2 item.
**Residual risk:** A malicious pre-filled UserDefaults value could execute arbitrary commands — acceptable because the attack requires prior write access to the user's UserDefaults, which is equivalent to full user-level compromise.

### T-03-07 — User-controlled command string body not sanitized

**Category:** Tampering
**Accepted by:** Design decision D-02 (PROJECT.md)
**Rationale:** Same trust boundary as T-03-01. The entire command body reflects user intent; sanitizing it would prevent legitimate use (e.g. flags, pipes, env vars). Only the `{wav}` path substitution is escaped because that value is app-controlled (the WAV file path), not user-controlled.

---

## Unregistered Threat Flags

**None.** SUMMARY.md (03-02) `## Threat Flags` section explicitly states: "None — no new network endpoints, auth paths, or schema changes beyond those already covered in the threat model."

---

## Dependency Audit

| Manifest | Status |
|----------|--------|
| Package.swift | KeyboardShortcuts only (pre-existing, Phase 02). No new dependencies added in Phase 03. |
| package.json | Not present |
| requirements.txt | Not present |
| Cargo.toml | Not present |

---

## Verification Evidence Index

| Threat | File | Lines |
|--------|------|-------|
| T-03-02 (pipe separation) | Sources/MakeAnIssue/CLIRunner.swift | 82-98 |
| T-03-02 (stdout-only on success) | Sources/MakeAnIssue/Transcriber.swift | 70, 72 |
| T-03-03 (timeout + terminate) | Sources/MakeAnIssue/CLIRunner.swift | 137-149 |
| T-03-03 (single-resume guard) | Sources/MakeAnIssue/CLIRunner.swift | 32-58 (RunState.claim via NSLock) |
| T-03-04 (readabilityHandler drain) | Sources/MakeAnIssue/CLIRunner.swift | 90-98 |
| T-03-05 (POSIX quoting) | Sources/MakeAnIssue/Transcriber.swift | 43-45 |
| T-03-05 (quoting test) | Tests/MakeAnIssueTests/TranscriberTests.swift | 43-60, 83-100 |
| T-03-06 (emptyCommand guard) | Sources/MakeAnIssue/Transcriber.swift | 35-37 |
| T-03-06 (missingWavToken guard) | Sources/MakeAnIssue/Transcriber.swift | 38-39 |
| T-03-06 (error test) | Tests/MakeAnIssueTests/AppStateTests.swift | 336-354 |
| T-03-08 (SwiftUI Text only) | Sources/MakeAnIssue/MenuView.swift | 42-47 |
| T-03-09 (asrTimedOut throw) | Sources/MakeAnIssue/Transcriber.swift | 64-65 |
| T-03-09 (reset to idle) | Sources/MakeAnIssue/AppState.swift | 196 |
| T-03-09 (timeout test) | Tests/MakeAnIssueTests/AppStateTests.swift | 316-334 |
| T-03-SC (no new deps) | Package.swift | entire file |
