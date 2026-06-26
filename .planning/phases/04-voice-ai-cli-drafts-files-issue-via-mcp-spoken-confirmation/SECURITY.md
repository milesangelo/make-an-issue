---
phase: 04
slug: voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-25
---

# SECURITY.md — Phase 04: voice → AI CLI drafts → files GitHub issue via Docker MCP → spoken confirmation

**Audit date:** 2026-06-25
**ASVS Level:** 1
**Auditor:** gsd-security-auditor
**Phase plans audited:** 04-01, 04-02, 04-03, 04-04

---

## Audit Result: SECURED

**Threats Closed:** 10/10 (10 mitigate/accept/transfer — 0 open)

---

## Threat Verification

### Mitigate dispositions (verified against implementation)

| Threat ID | Category | Component | Evidence |
|-----------|----------|-----------|----------|
| T-04-01 | Information Disclosure | token passed to subprocess | `CLIRunner.swift:88-92` — `extra` dict overlaid onto `ProcessInfo.processInfo.environment`, assigned to `process.environment`. Token never appears in the `-lc` command string argument. |
| T-04-02 | Tampering | parsing AI-CLI stdout | `IssueResultParser.swift:111-113` — `if !deniedTools.isEmpty { throw IssueParseError.permissionDenied(deniedTools) }` executes before any URL check. `IssueResultParserTests.swift:70-97` asserts this on two distinct fixture payloads. |
| T-04-03 | Spoofing | wrong number spoken | `IssueResultParser.swift:38-43` — `structuredURLRegex` pattern `"(?:url|html_url)"\s*:\s*"(https?://github\.com/[^"]+/issues/(\d+))"` captures the number from the URL path only. The `id` node-id field is never read anywhere in the parser. `IssueResultParserTests.swift:21` comment: "Number must come from url path (/issues/89), not the id field." |
| T-04-04 | Tampering | transcript embedded in command string | `IssueFilingRunner.swift:86` — `let escapedPrompt = shellEscape(prompt)` applied to the full prompt (which embeds the transcript) before the prompt is inserted into the `-lc` string. `shellEscape` replaces `'` with `'\''` and wraps in single quotes. `IssueFilingRunnerTests.swift:179-207` verifies `'\''` appears for single-quote input and outer-quote balance. |
| T-04-05 | Information Disclosure | GitHub PAT | `IssueFilingRunner.swift:164` — `environment: [config.tokenEnvKey: token]` passes token in the environment dict to `CLIRunner.run`; token is absent from the command string. `IssueFilingRunner.swift:139` — `// Never log the token value.` MCP config JSON (`IssueFilingConfig.swift:87`) contains `-e GITHUB_PERSONAL_ACCESS_TOKEN` without a value — Docker inherits it from the process environment; token is never written to the tempfile. |
| T-04-06 | Elevation of Privilege | AI-CLI tool grant | `IssueFilingRunner.swift:90` — `--allowedTools \(config.allowedToolsArgument)` resolves to `mcp__github__issue_write Read Grep Glob`. `IssueFilingRunnerTests.swift:163-177` — two `XCTAssertFalse` assertions: command must not contain `bypassPermissions` (T-04-06) and must not contain `dangerously-skip` (T-04-06). |
| T-04-07 | Information Disclosure | MCP config tempfile | `IssueFilingRunner.swift:143-147` — tempfile at `FileManager.default.temporaryDirectory` with UUID suffix; `defer { try? FileManager.default.removeItem(at: tempURL) }` on every exit path. `IssueFilingRunnerTests.swift:259-302` verifies no `make-an-issue-mcp-*` file survives a token-failure throw. |
| T-04-08 | Denial of Service | runaway claude subprocess | `IssueFilingRunner.swift:165` — `timeout: .seconds(300)` passed to `CLIRunner.run`; `CLIRunner.swift:149-161` shows the timeout Task terminates the process and resumes the continuation with `.timeout`; `IssueFilingRunner.swift:171` maps it to `IssueFilingError.timeout`. |
| T-04-10 | Spoofing | spoken confirmation | `AppState.swift:258-263` — `speak` / `onSpeak` called inside the `do { let result = try await ... }` success block only, using `result.number` (an `Int` from the url-path parse). Error handlers at lines 266-278 set `statusText` only; no speak call on any failure path. `AppStateTests.swift:541` — `XCTAssertFalse(speakCalled, "speak seam must NOT be called on parseFailed (no false success)")`. |
| T-04-13 | Spoofing | false success on failure | Composite of T-04-02 gate + T-04-10 success-only speak. `AppStateTests.swift:513-543` — `testParseFailedStatusMessageIsNotMisleading` injects `onRunIssueFiling` stub throwing `.parseFailed`, asserts `speakCalled == false` and `captureState == .idle`. Human negative check (04-04-SUMMARY.md) confirmed Docker-stopped path shows status error and files nothing. |

### Accept dispositions (CLOSED by documented plan disposition — no mitigation code required)

| Threat ID | Category | Accepted Risk | Plan Reference |
|-----------|----------|---------------|----------------|
| T-04-09 | Spoofing (malicious MCP image) | Pinned official image `ghcr.io/github/github-mcp-server` from GitHub's own registry. Docker pull and image trust are a documented user prerequisite; the app does not bundle Docker. | 04-02-PLAN.md threat register |
| T-04-12 | Repudiation (real issue creation) | Issue filed under the user's own authenticated `gh` / `claude` session; attribution is the user's GitHub identity by design. | 04-04-PLAN.md threat register |
| T-04-SC | Tampering (npm/pip/cargo installs) | No package-manager installs in phase 04 — Apple frameworks and existing project code only. | 04-01, 04-02, 04-03, 04-04 PLAN threat registers |

### Transfer dispositions (CLOSED — mitigation delegated to another threat)

| Threat ID | Category | Transferred To | Evidence |
|-----------|----------|----------------|----------|
| T-04-11 | Tampering (transcript crossing AppState→Runner seam) | T-04-04 | `IssueFilingRunner.swift:86` `shellEscape(prompt)` is applied inside `assembleCommand` regardless of how the transcript arrives. AppState passes the raw transcript string; escaping is enforced at the runner boundary. |

---

## Unregistered Threat Flags

None. All four SUMMARY.md files (`04-01` through `04-04`) report no new threat surface beyond the registered threat register.

---

## Accepted Risks Log

| Risk ID | Description | Accepted In | Notes |
|---------|-------------|-------------|-------|
| T-04-09 | Pulling `ghcr.io/github/github-mcp-server` without digest pinning | 04-02-PLAN.md | Mitigated in practice by using the official GitHub-hosted registry; image tag is `latest`. Digest pinning is a v1.1 hardening candidate. |
| T-04-12 | Real issue creation is non-reversible | 04-04-PLAN.md | By design: the user authenticated their own `gh` session; deletion requires a separate UI action. |
| T-04-SC | No supply-chain legitimacy gate on Apple framework imports | All phase plans | No third-party packages added in this phase; risk surface is Apple OS frameworks only. |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-25 | 14 | 14 | 0 | gsd-security-auditor (verify mitigations, register_authored_at_plan_time: true) |

*14 threats = 10 mitigate (verified against implementation) + 3 accept + 1 transfer.*

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-25
