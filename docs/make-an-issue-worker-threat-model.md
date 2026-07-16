# make-an-issue-worker threat model

**Status:** normative companion to the [product contract](./make-an-issue-worker-product-contract.md)

**Reviewed:** 2026-07-15

**Scope:** one macOS user, one host, GitHub repositories, local provider executables

## 1. Security objective and trust boundaries

The worker turns untrusted GitHub issue content into local code changes and, only after inspection
and validation, a draft pull request. Its primary objective is to prevent issue text or a coding
provider from acquiring the supervisor's publication authority or damaging user work.

Trusted for policy decisions:

- the signed worker and menu-app code;
- a validated immutable `agents.toml` snapshot controlled by the logged-in user;
- the worker's SQLite ledger and worker-owned repository/artifact store;
- GitHub authorization and repository metadata read by the supervisor through the user's `gh`
  login;
- named validation profiles from worker code or the trusted default branch.

Untrusted even when expected:

- issue title, body, comments, labels as text, and linked content;
- repository files, hooks, build scripts, tests, and generated output;
- provider executable, provider model output, stdout/stderr, and edited files;
- provider-suggested commands, paths, commit messages, PR text, or status;
- network services used by cloud or local-model providers;
- dependency CLI output and all filesystem paths until canonicalized.

The menu app is a low-authority client. The worker supervisor is the sole high-authority process.
Providers run as the same macOS user in v1, so environment minimization and process separation are
not a strong OS sandbox; that residual risk is explicit below.

## 2. Subprocess credential contract

The supervisor constructs environments from allowlists, never by copying its entire LaunchAgent
environment.

| Subprocess | Receives | Explicitly omitted | Residual access |
|---|---|---|---|
| Coding provider | Adapter-specific isolated `HOME`, workspace `PWD`, minimal system `PATH`, locale, temp dir, provider credential/config needed to run | `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`, real user `HOME`, SSH agent socket, git credential variables, worker socket/database paths, publication receipts | Same-user process may probe absolute paths, Keychain, network, or spawn other installed tools unless an OS sandbox is added |
| Validation command | Empty isolated `HOME`, workspace `PWD`, validation-only `PATH`, locale, temp dir | Provider credentials, GitHub credentials/config, SSH agent, worker IPC/state paths | Repository-controlled code executes as the user; filesystem/network access is not fully contained in v1 |
| `git` supervisor child | Worker-managed repo/workspace path, fixed `GIT_CONFIG_*`, hooks disabled, prompt disabled, narrowly scoped credential helper only when a network operation requires it | Provider credentials, issue prompt, worker IPC secrets | Git/SSH credential helpers may access user credentials; child runs only after provider exit |
| `gh` supervisor child | Dedicated `GH_CONFIG_DIR` or Keychain-backed user login, fixed repository, bounded request inputs | Provider credentials and provider output as argv | Has the user's GitHub authority; therefore arguments are built only from canonical ledger/config data |
| Treehouse adapter | Isolated worker `HOME`, worker-owned repo, worker-owned pool root, ephemeral `GIT_CONFIG_*` credential helper sourced at run time from `gh auth token` for private HTTPS fetches | User Treehouse config/hooks, provider credentials, persisted token material, changes to global git configuration | Treehouse invokes git and manages worktree metadata in the worker-owned store; the short-lived token lives only in the child environment and is never written to disk |
| no-mistakes adapter, if enabled | Dedicated `NM_HOME`, worker-owned repo, pinned config and exact skip/capability policy | Anything not required by the proven adapter contract | Current upstream daemon does not prove validator/publisher credential separation; adapter remains disabled until it does |

No provider receives a GitHub token in its environment. The supervisor launches publication
children only after the provider process group has exited and the diff has passed inspection. No
provider output is forwarded verbatim as a `git` or `gh` argument.

## 3. Threat register

### TM-01: issue text prompt injection

**Scenario.** An issue tells the provider to ignore instructions, read secrets, modify files outside
the repository, run `gh`, alter git metadata, weaken tests, or publish attacker-chosen content.
Linked pages and repository files can contain equivalent instructions.

**Impact.** Arbitrary local edits, secret disclosure, malicious commits, unauthorized GitHub
actions, or denial of service.

**Mitigations and enforcement.**

- `TriggerVerifier`: pickup requires repository opt-in and `agent:run`.
- `TriggerTrust`: for every repository, public or private, app activation requires the
  authenticated user to have write/maintain/admin permission; polled activation requires the
  effective label-add actor to have write/maintain/admin permission. Missing proof fails closed.
- `RouteResolver`: only explicit label routes launch a provider; no route adds `agent:unrouted` and
  runs nothing.
- `PromptBuilder`: issue data is size-bounded, quoted, and marked untrusted beneath fixed
  instructions; it cannot supply configuration or argv.
- `ProviderLauncher`: no publication credential or worker IPC authority is supplied.
- `DiffInspector`, `ValidationEngine`, and `Publisher`: provider intent is irrelevant; only the
  inspected diff and green receipt can publish.

Maintainer-only activation plus the label gate does not make issue text trustworthy. It bounds who
may spend local execution authority: an outsider on a public repository cannot self-trigger, a
read- or triage-only collaborator on a private repository cannot self-trigger, and a maintainer's
label is an explicit approval to process that specific text.

**Residual risk.** A trusted maintainer may label a malicious issue or have a compromised account.
Prompt injection can still persuade the provider to attempt same-user filesystem/network access.
The worker catches prohibited resulting diffs and withholds publication, but v1 does not provide a
complete OS sandbox for provider behavior. Residual severity: **high**.

### TM-02: malicious or compromised provider binary

**Scenario.** The configured executable is replaced, code-signed by an unexpected identity, or is
itself malicious. It ignores edit-only instructions, reads user files, exfiltrates data, kills other
processes, tampers with the worker, or invokes GitHub tooling directly.

**Impact.** Same-user code execution, credential theft, data loss, remote compromise, or persistence.

**Mitigations and enforcement.**

- `ConfigLoader` requires typed adapters, absolute executables, literal argv, and a user-owned
  non-writable config; no generic shell-string adapter exists.
- `ExecutableVerifier` records and rechecks file identity and signature immediately before launch.
- `ProviderLauncher` uses an isolated home/temp directory, minimal PATH, no GitHub/SSH environment,
  a workspace CWD, and a bounded process group.
- `GitSupervisor` and worker IPC are not callable through provider output; publication begins only
  after provider exit.
- `ArtifactStore` captures the resulting patch before other actions; `DiffInspector` rejects git
  metadata, unsafe paths, symlink escapes, submodules, binaries/size excess, and empty diffs.
- `ResourceGovernor` terminates the whole provider process group on timeout/cancellation.

**Residual risk.** macOS user permissions, not the worker, govern absolute filesystem reads,
Keychain prompts, and network access. Removing tokens from the environment does not prevent a
malicious same-user binary from searching for credential stores or other CLIs. The only strong
mitigation is an OS sandbox/container/VM with explicit file and network policy, which is not part
of v1. Users must treat configured providers as trusted local software. Residual severity:
**critical**.

### TM-03: configuration tampering

**Scenario.** Another local process changes `agents.toml`, provider argv, executable paths, routes,
repository remotes, instructions, or limits before or during a run.

**Impact.** Execution of a malicious binary, routing attacker content, weakening validation,
publishing to the wrong repository, or removing resource bounds.

**Mitigations and enforcement.**

- `ConfigLoader` rejects symlinks, wrong ownership, group/world writes, oversize files, unknown
  keys, unsupported schema versions, generic commands, and equal priorities.
- It hashes the exact bytes read through one file descriptor and snapshots referenced instruction
  files; the ledger binds every run to that revision.
- `RepositoryVerifier` checks remote identity and default branch against GitHub.
- `ExecutableVerifier` rechecks executable identity at launch.
- Invalid reloads stop new claims but do not mutate in-flight or retained runs.
- The menu shows the active revision/error and does not accept executable config through IPC.

**Residual risk.** Any process already running as the same user can generally rewrite user-owned
configuration and provider binaries or race non-kernel-enforced trust decisions. File permissions
do not defend against a compromised user session. Residual severity: **high**.

### TM-04: local-model and provider network egress

**Scenario.** `codex-oss` connects to a local server that proxies remotely, a supposedly local model
downloads resources or sends prompts, or a cloud provider exfiltrates issue/repository data.

**Impact.** Source, issue content, secrets embedded in files, and prompts leave the host.

**Mitigations and enforcement.**

- `ProviderAdapter` makes provider kind explicit; local models use only the typed Codex OSS/custom
  provider path, never an arbitrary command adapter.
- Configuration and UI identify provider kind and endpoint policy before enablement.
- Provider input is restricted to the issue and assigned workspace; worker/GitHub credentials are
  omitted.
- Logs record provider kind and redacted endpoint metadata for audit.

**Residual risk.** `local` describes model placement, not a network guarantee. The worker does not
install a packet filter, Network Extension, container network namespace, or VM in v1. Neither
Codex OSS nor an OpenAI-compatible custom endpoint proves zero egress. Users requiring no egress
must enforce it outside the worker and verify the model/provider stack. Residual severity:
**high** for confidential repositories.

### TM-05: secrets exposure through environment, files, logs, and child processes

**Scenario.** A token is inherited by a provider/test, checked into the diff, printed in logs,
read from the checkout, exposed through git credential helpers, or placed in a PR body.

**Impact.** Credential theft and unauthorized local or GitHub actions.

**Mitigations and enforcement.**

- `EnvironmentBuilder` uses the subprocess-specific allowlists in section 2 and never clones the
  LaunchAgent environment.
- Provider and validation subprocesses never receive GitHub token variables, real `GH_CONFIG_DIR`,
  SSH agent access, or publication receipts.
- `SecretScanner` runs on changed content and bounded logs before publication; findings fail
  validation and retain work locally.
- `LogSink` caps, escapes, redacts known credential formats, writes user-only files, and never sends
  raw logs to the menu.
- `GitSupervisor` disables repository hooks and untrusted git config for supervisor operations.
- `PRComposer` builds title/body from canonical issue/run facts and sanitized summaries, not raw
  provider output or logs.
- Publication children run after the provider exits and receive only the repository-scoped
  authority required for the operation.

**Residual risk.** Pattern scanning misses novel secrets. Tests and providers run as the same user
and may read secrets from accessible repository files or absolute paths. `gh` and credential
helpers necessarily have GitHub authority during supervisor publication. Residual severity:
**high**.

### TM-06: malicious repository code and validation commands

**Scenario.** The default branch, provider diff, test runner, compiler plugin, package script, or
git filter executes malicious code during preparation or validation.

**Impact.** Same-user code execution, secret access, persistence, or resource exhaustion.

**Mitigations and enforcement.**

- `ValidationProfileResolver` accepts commands only from a named worker profile or trusted default
  branch, never issue text, provider stdout, or feature-branch config.
- `GitSupervisor` disables hooks, external diff/textconv, recursive submodules, and unexpected
  smudge/clean filters for its own operations.
- `ValidationLauncher` uses an empty isolated home, no provider/GitHub credentials, a minimal PATH,
  bounded output, timeout, and process-group teardown.
- `DiffInspector` runs before validation and again if validation or formatting changes files.

**Residual risk.** Running project tests is code execution. Without an OS sandbox, hostile test or
build code can access the user's files and network. Maintainers must opt in only trusted
repositories. Residual severity: **critical** for an intentionally malicious repository.

### TM-07: publication confusion and interrupted runs

**Scenario.** The worker crashes after push but before recording the PR, retries against the wrong
branch, sees an existing attacker-created branch/PR, or a dependency opens a ready-for-review PR.

**Impact.** Duplicate PRs, publication of unvalidated code, overwritten refs, or bypass of review.

**Mitigations and enforcement.**

- `BranchPolicy` uses a unique run-derived branch and refuses any local or remote collision.
- `Publisher` requires a green receipt bound to exact base/head/diff/config values and records a
  publication intent before network mutation.
- `GitSupervisor` exposes only normal non-force push.
- `PublicationReconciler` checks exact remote SHA and PR head/base/draft state before retrying.
- A branch SHA mismatch, multiple PRs, or a non-draft PR fails closed for human action.
- Current no-mistakes PR creation lacks `--draft`; the adapter is disabled rather than allowed to
  weaken the draft-only invariant.

**Residual risk.** A GitHub administrator can mutate/delete refs or change PR state concurrently.
The worker detects observed mismatches but cannot prevent server-side administrative actions.
Residual severity: **medium**.

### TM-08: resource exhaustion

**Scenario.** Huge issues, repositories, diffs, binaries, logs, process trees, endless provider
output, API pagination, retained workspaces, or repeated labels exhaust CPU, memory, disk, network,
or provider quota.

**Impact.** Host instability, cost, stalled pickup, or loss of availability.

**Mitigations and enforcement.**

- `TriggerLedger` permits at most one non-terminal run per repository + issue group and
  suppresses passive pickup while the group's latest run record is terminal.
- `HostClaim` allows only one active run.
- `ResourceGovernor` applies prompt/body/page, time, output, workspace, file-count, file-size,
  diff-size, and log limits.
- Each subprocess has process-group TERM-to-KILL teardown.
- `DiskMonitor` stops new claims before its hard reserve is consumed.
- Dirty/unpublished work is never quota-deleted; the app asks the user to export/delete retained
  runs.
- Poll failures use bounded exponential backoff but retain the normative 60-second reconciliation
  cadence after recovery; failures never create tight retry loops.

**Residual risk.** One permitted run can still consume substantial compute or paid provider quota
within its bounds. The no-data-loss invariant means retained work can block future runs until the
user acts. Residual severity: **medium**.

### TM-09: dependency or update compromise

**Scenario.** A bundled/adopted Treehouse or no-mistakes binary is replaced or changes behavior,
or an app update points its LaunchAgent at an unexpected helper.

**Impact.** Workspace deletion, publication-policy bypass, credential exposure, or persistence.

**Mitigations and enforcement.**

- Dependencies are pinned, checksum/code-signature verified, and their MIT notices ship with the
  app.
- `WorkspaceManager` and `Publisher` run executable capability tests rather than trusting version
  strings.
- Missing durable retention, draft support, credential separation, or no-force behavior disables
  the adapter and selects the self-contained seam implementation.
- Helper/LaunchAgent installation is explicit and user-approved; updates are atomic and preserve
  the ledger/artifact store.

**Residual risk.** Capability tests cannot prove absence of malicious behavior. A signed supply
chain compromise remains possible. Residual severity: **high**.

## 4. Required security tests

Before MVP release, automated tests must cover:

- trigger actors on public and private repositories with read, triage, write, maintain, admin,
  missing, and changed permission;
- label remove/re-add timeline handling, stale-label versus re-application discrimination
  after a terminal run, and missing timeline failure;
- prompt injection strings attempting git, `gh`, path escape, secret reads, and publication;
- config symlink/ownership/mode/TOCTOU cases, unknown keys, and equal priorities;
- provider environment snapshots proving GitHub/SSH variables and real home are absent;
- malicious provider processes that fork, hang, flood output, edit `.git`, create a commit, and
  escape the workspace;
- symlink escapes, case-colliding paths, gitlinks, `.gitmodules` changes, binaries, huge files,
  huge diffs, and empty diffs;
- validation failure proving no remote branch and no PR while patch/log/workspace remain;
- crash points immediately before/after commit, push, PR create, draft verification, and ledger
  update;
- dependency capability failures selecting the builtin implementation;
- a no-mistakes probe that rejects the verified non-draft PR behavior;
- retained-workspace disk pressure stopping claims without deletion.

## 5. Accepted v1 residual risk

The worker is not a security boundary against a malicious executable or hostile repository running
as the same macOS user. The MVP meaningfully separates GitHub publication authority, prevents
automatic publication of uninspected or failing diffs, protects the user's checkout/default branch,
and retains recoverable work. It does not guarantee filesystem or network confinement. That limit
must be stated in setup UI and release documentation, especially for local-model/no-egress claims.
