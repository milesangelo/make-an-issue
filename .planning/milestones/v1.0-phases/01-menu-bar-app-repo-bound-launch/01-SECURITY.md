---
phase: 1
slug: 01-menu-bar-app-repo-bound-launch
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-24
updated: 2026-06-24
---

# Phase 1 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| Build script -> app bundle | Local script copies the Swift executable and plist into an openable app bundle. | Executable and bundle metadata |
| App bundle metadata -> macOS LaunchServices | `Info.plist` controls how macOS launches and displays the app. | Bundle identifier, app type, no-Dock flag |
| Launcher shell -> Application Support request file | Repo-local command writes the invocation cwd for the GUI app to consume. | Local filesystem path and timestamp |
| Launch request file -> app state | GUI app decodes the latest handoff request and deletes it. | JSON cwd handoff |
| Launch cwd -> repo resolver | A shell cwd becomes input to filesystem-only git-root binding. | Local path |
| App state -> menu UI | Internal binding state becomes visible menu content. | Status text and repo path |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-01-01-S | Spoofing | `Resources/Info.plist` bundle identifier | mitigate | Explicit bundle identifier `com.milesangelo.make-an-issue`; app bundle created from repo-local script. | closed |
| T-01-01-T | Tampering | `scripts/build-app.sh` app bundle assembly | mitigate | Script derives paths from repo root, quotes paths, and writes only `.build/MakeAnIssue.app`. | closed |
| T-01-01-I | Information Disclosure | `MenuView` initial state | mitigate | Menu renders only app status and repo display fields from `AppState`. | closed |
| T-01-01-D | Denial of Service | SwiftUI app startup | mitigate | Startup is limited to state creation, menu rendering, and later handoff consumption. | closed |
| T-01-01-E | Elevation of Privilege | Non-sandboxed app setup | mitigate | Phase 1 app startup performs no privileged operations or arbitrary external command execution. | closed |
| T-01-02-S | Spoofing | `bin/make-an-issue` app target | mitigate | Launcher resolves `.build/MakeAnIssue.app` relative to its install root and exits if missing. | closed |
| T-01-02-T | Tampering | `launch-request.json` | mitigate | Request JSON contains only `cwd` and `createdAtUnixSeconds`; Swift decodes the exact schema, clears malformed requests, and never executes decoded values. | closed |
| T-01-02-R | Repudiation | Launch handoff | accept | Phase 1 has no remote or privileged side effect; latest local handoff timestamp is sufficient. | closed |
| T-01-02-I | Information Disclosure | Application Support request file | mitigate | Request file stores only cwd and timestamp; no environment, shell args, speech text, or repo contents. | closed |
| T-01-02-D | Denial of Service | Malformed request file | mitigate | `consumeLatest()` removes malformed JSON and returns nil. | closed |
| T-01-02-E | Elevation of Privilege | Launcher shell script | mitigate | Paths are quoted, `eval` and sourced shell files are absent, default open command is `/usr/bin/open`, and the test override must be an absolute path invoked without shell evaluation. | closed |
| T-01-03-S | Spoofing | `RepoBinding.resolve(from:)` | mitigate | Resolver standardizes cwd and binds only to an ancestor containing a `.git` directory or regular file. | closed |
| T-01-03-T | Tampering | `.git` marker detection | accept | Phase 1 trusts local user-writable repositories; binding alone performs no privileged or remote action. | closed |
| T-01-03-R | Repudiation | Binding replacement | accept | Phase 1 stores only current binding and status; no remote side effect or audit requirement exists for binding changes. | closed |
| T-01-03-I | Information Disclosure | `MenuView` repo path display | mitigate | Menu displays only the bound repo name and path; no file lists, branches, remotes, environment variables, or command output. | closed |
| T-01-03-D | Denial of Service | Parent directory walk | mitigate | Resolver stops at `/`, returns nil for non-repo paths, and performs bounded ancestor checks only. | closed |
| T-01-03-E | Elevation of Privilege | Repo resolver | mitigate | Resolver does not execute `git` or any external command; it inspects filesystem markers only. | closed |

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-01-001 | T-01-02-R | Phase 1 launch handoff has no remote or privileged side effects; created-at timestamp is enough local traceability. | GSD security gate | 2026-06-24 |
| AR-01-002 | T-01-03-T | Local `.git` markers are user-writable, but Phase 1 binding alone does not execute code or create remote side effects. | GSD security gate | 2026-06-24 |
| AR-01-003 | T-01-03-R | Binding replacement is local UI state only; no durable audit trail is required for v1 Phase 1. | GSD security gate | 2026-06-24 |

---

## Evidence

| Check | Result |
|-------|--------|
| `swift test` | passed: 14 tests, 0 failures |
| `swift build` | passed |
| `sh -n bin/make-an-issue` | passed |
| Absolute open-command override smoke | passed: `/usr/bin/true` override writes launch request |
| Relative open-command override smoke | passed: relative `true` rejected and no launch request created |
| Phase 1 UAT | passed: 3/3 user-observable checks |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-24 | 17 | 17 | 0 | Codex |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-24
