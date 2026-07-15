# make-an-issue-worker product contract

**Status:** implementation contract

**Decision date:** 2026-07-15

**Schema version:** 1

**Companion:** [Threat model](./make-an-issue-worker-threat-model.md)

This document is the normative contract for the `make-an-issue-worker` MVP. An implementation
may change internal types, but it must preserve every MUST, MUST NOT, and state transition here.
If an adopted dependency cannot uphold this contract, the worker must fail closed or select the
self-contained implementation behind the same seam; dependency behavior never weakens an
invariant.

## 1. Product boundary

After `make-an-issue` files a GitHub issue, a separate worker picks up eligible issues, asks a
configured coding provider to edit an isolated workspace, validates the result, and opens a draft
pull request. The worker ships inside the signed app bundle and runs only after the user approves
its per-user LaunchAgent.

Responsibilities are intentionally split:

| Component | Owns | Must not own |
|---|---|---|
| Menu app | Per-repository enable/disable, adding `agent:run` to voice-filed issues, fast-path enqueue, status display | Provider execution, workspaces, git mutation, GitHub credentials, publication |
| Worker supervisor | Trigger verification, routing, SQLite ledger, workspaces, provider lifecycle, diff inspection, validation, all git operations, all `gh` operations, recovery | Editing source on the provider's behalf |
| Provider adapter | Editing files in the assigned workspace only | Git, GitHub, labels, pull requests, tokens, publication decisions |
| `WorkspaceManager` | Worker-owned isolated workspace lifecycle | Publication |
| `Publisher` | Validation, gated push, draft PR creation, CI observation, publication reconciliation | Provider execution or edits before validation |

The MVP is GitHub-only. Docker is not required by the worker. A repository's existing build or
test commands may themselves require Docker; that is a repository concern and not a worker
runtime assumption.

## 2. Locked product decisions

The following decisions are closed and are not implementation questions:

1. Pickup is per-repository opt-in. An enabled repository auto-adds `agent:run` to issues filed by
   the voice flow.
2. Labels are `agent:run` for activation and `bug`, `enhancement`, or `spike` for type. Routes are
   evaluated by explicit descending priority; first match wins. Equal route priorities are a
   configuration error. No match causes the worker to add `agent:unrouted` and run nothing. Ties
   fail closed.
3. Validation failure preserves the provider's work locally only. Failing work is never pushed and
   never receives a pull request.
4. Provider adapter delivery order is Claude Code first, Codex second, then local models through
   the Codex OSS/custom-provider path.
5. A trigger is trusted only when activated by an actor with `WRITE`, `MAINTAIN`, or `ADMIN`
   permission. This requirement applies uniformly to public and private repositories and fails
   closed when trust cannot be proven.
6. MVP concurrency is one host and one active run at a time.
7. Pull requests are always draft and are never auto-merged.
8. Configuration is versioned TOML at
   `~/Library/Application Support/MakeAnIssue/agents.toml`. Provider commands are a typed adapter,
   executable, and argv array; shell command strings are forbidden.

## 3. Architecture and data flow

```text
IssueFilingResult success                 60-second reconciliation poll
        |                                            |
        +---- issue URL enqueue ----+---- eligible labeled issues ----+
                                    v
                         Trigger verifier + router
                                    |
         SQLite guarded insert: one non-terminal run per repo+issue
                                    |
                     one-host global claim transaction
                                    |
          worker-owned repo store -> WorkspaceManager -> provider
                                    |
                          DiffInspector -> Publisher
                                    |
                       green -> push -> draft PR -> CI
                       red   -> retain locally, publish nothing
```

The worker communicates with the app through a local, versioned IPC seam. The concrete transport
may be XPC or a worker-owned Unix socket under Application Support. It MUST authenticate the peer
as the same logged-in user, reject paths outside the agreed state directory, bound message size,
and never accept executable configuration through the enqueue call.

### 3.1 Worker-owned repository store

The worker MUST NOT use a user's checkout as a workspace or as the backing repository for pooled
worktrees. For each configured `owner/name`, it maintains a supervisor-owned clone or bare source
store below its state directory. Only that managed store may be fetched, have remotes configured,
or be passed to `WorkspaceManager` and `Publisher`.

The configured `repository` slug and the issue URL identify a repository. A local checkout path is
not part of the run contract. This prevents the app's current `RepoBinding.rootURL` from becoming
an authority to mutate the checkout.

## 4. Configuration contract

### 4.1 Loading and revision

The worker reads exactly
`~/Library/Application Support/MakeAnIssue/agents.toml`. Before parsing it MUST reject a symlink,
a non-regular file, a file not owned by the current user, or group/world-writable permissions. It
reads through one already-open file descriptor, caps the file at 1 MiB, parses strictly, and
rejects unknown keys.

`schema_version` MUST equal `1`. A config revision is the lowercase SHA-256 of the exact bytes read
from that descriptor. Validation produces an immutable in-memory snapshot. Each run retains the
revision and a redacted copy of the snapshot. A later file change affects only newly discovered
work; it never changes an in-flight run.

Any configuration error disables new claims, surfaces `Configuration error` in the app, and leaves
existing retained work untouched. In particular, duplicate route priorities are an error even if
the two routes would not match the same sample issue.

### 4.2 Complete annotated example

Comments are explanatory; every uncommented field is part of schema version 1.

```toml
schema_version = 1

[worker]
# Fixed at 60 for v1; other values are rejected rather than silently rounded.
poll_interval_seconds = 60
# Fixed at 1 for v1: one host-wide provider/publication run at a time.
max_concurrent_runs = 1
run_timeout_seconds = 3600
provider_grace_seconds = 10
state_root = "~/Library/Application Support/MakeAnIssue/Worker"
workspace_backend = "treehouse"
publisher_backend = "auto"

[worker.limits]
max_log_bytes = 10485760
max_workspace_bytes = 5368709120
max_changed_files = 500
max_diff_bytes = 5242880
max_single_file_bytes = 1048576
allow_binary_files = false

[[providers]]
id = "claude-primary"
kind = "claude-code"
executable = "/Users/example/.local/bin/claude"
# Literal argv elements only. The adapter owns prompt transport and required safety flags.
argv = ["--model", "sonnet"]
timeout_seconds = 2700

[[providers]]
id = "codex-secondary"
kind = "codex"
executable = "/opt/homebrew/bin/codex"
argv = ["--model", "gpt-5-codex"]
timeout_seconds = 2700

[[providers]]
id = "local-codex-oss"
kind = "codex-oss"
executable = "/opt/homebrew/bin/codex"
# The typed adapter maps these values to Codex's custom-provider interface.
argv = ["--config", "model_provider=local", "--model", "qwen3-coder"]
timeout_seconds = 2700

[[agents]]
id = "bugfix"
provider = "claude-primary"
instructions_file = "~/Library/Application Support/MakeAnIssue/prompts/bugfix.md"
validation_profile = "default"

[[agents]]
id = "feature"
provider = "codex-secondary"
instructions_file = "~/Library/Application Support/MakeAnIssue/prompts/feature.md"
validation_profile = "default"

[[agents]]
id = "research"
provider = "local-codex-oss"
instructions_file = "~/Library/Application Support/MakeAnIssue/prompts/spike.md"
validation_profile = "spike"

[[routes]]
id = "urgent-bug"
priority = 300
labels_all = ["agent:run", "bug"]
labels_any = ["priority:critical", "priority:high"]
agent = "bugfix"

[[routes]]
id = "bug"
priority = 200
labels_all = ["agent:run", "bug"]
labels_any = []
agent = "bugfix"

[[routes]]
id = "enhancement"
priority = 100
labels_all = ["agent:run", "enhancement"]
labels_any = []
agent = "feature"

[[routes]]
id = "spike"
priority = 50
labels_all = ["agent:run", "spike"]
labels_any = []
agent = "research"

[[repositories]]
repository = "acme/widgets"
enabled = true
default_branch = "main"
remote = "https://github.com/acme/widgets.git"
route_ids = ["urgent-bug", "bug", "enhancement", "spike"]

[[repositories]]
repository = "acme/legacy"
enabled = false
default_branch = "main"
remote = "https://github.com/acme/legacy.git"
route_ids = ["bug"]
```

### 4.3 Schema rules

#### `[worker]`

| Field | Contract |
|---|---|
| `poll_interval_seconds` | Required integer and exactly `60` in v1 |
| `max_concurrent_runs` | Required integer and exactly `1` in v1 |
| `run_timeout_seconds` | `60...14400`; wall-clock bound for one run |
| `provider_grace_seconds` | `1...60`; SIGTERM-to-SIGKILL grace |
| `state_root` | Absolute after `~` expansion; user-owned, not a symlink |
| `workspace_backend` | `treehouse` or `builtin`; `auto` is forbidden because workspace retention semantics must be known |
| `publisher_backend` | `auto`, `no-mistakes`, or `builtin`; `auto` selects only an adapter that passes capability probes |

Numeric `worker.limits` values are required positive integers. `allow_binary_files` defaults to
and should remain `false`; if true, binaries are still subject to changed-file, per-file, and
total limits.

#### `[[providers]]`

`id` is unique. `kind` is exactly `claude-code`, `codex`, or `codex-oss`; generic command kinds do
not exist. `executable` resolves to an absolute regular executable file at config-validation time.
The worker records its device, inode, size, mtime, and code-signing result and rechecks them before
launch. `argv` is an array of literal strings with no shell expansion, substitutions, or embedded
environment assignments. The adapter, not config, supplies the prompt, workspace, edit-only mode,
output format, and required safety flags.

Provider adapter implementation and default preference order is Claude Code, then Codex, then
Codex OSS/custom provider for local models. A route selects one agent; v1 does not automatically
fall through to another provider after partial edits. A launch failure before any edit may be
retried once with the same provider, then fails the run.

#### `[[agents]]`

`id` is unique and references one provider. `instructions_file` is a user-owned, non-symlink,
regular UTF-8 file capped at 256 KiB. It is snapshotted into the config revision. A
`validation_profile` selects only a named, worker-defined validation profile; it is not a shell
command.

#### `[[routes]]`

`id` and `priority` are unique. Priority is an integer. `labels_all` must all be present;
`labels_any` is satisfied when empty or when at least one value is present. Every route must
require `agent:run` through `labels_all`. The labels `bug`, `enhancement`, and `spike` are the only
built-in type labels, though additional matching labels such as priority labels are allowed.

For a repository, enabled routes in `route_ids` are sorted by descending priority. The first match
wins. Multiple issue type labels are permitted and are resolved only by this ordering. A missing
route, agent, provider, or duplicate priority makes the whole config invalid. If no route matches,
the worker adds `agent:unrouted`, records an unrouted observation, and creates no run.

#### `[[repositories]]`

`repository` is a lowercase canonical `owner/name` GitHub slug and is unique. `enabled = true` is
the opt-in boundary. `remote` must be the matching GitHub repository over HTTPS or SSH; redirects
or a fetched repository identity that disagree with `repository` are rejected. Because GitHub
preserves case in owner and repository names, the worker case-folds the fetched owner and
repository identity and compares it case-insensitively with the configured lowercase slug.
`default_branch` is a configured expectation and is verified against GitHub before each run. A
disagreement stops preparation; the worker never guesses a different publication base.

## 5. Trigger and routing contract

### 5.1 Fast path: app post-file enqueue

The integration point is the success arm in `AppState.spawnFilingJob`, immediately after
`IssueFilingResult` is stored and before or adjacent to the spoken success announcement
(`Sources/MakeAnIssue/AppState.swift`, current lines 316-325).

For an enabled repository the app:

1. Requests the existing issue-filing backend to add `agent:run` to the newly created issue. The
   label is part of pickup authorization, not an optional hint.
2. Sends the worker `{schemaVersion, issueURL, observedAt, source = "app-post-file"}`.
3. Treats a successful durable enqueue as complete; it does not wait for claim or provider work.

If labeling or enqueue fails, issue filing remains successful and the app shows a separate worker
status. The 60-second poll repairs a lost enqueue once the label exists. The app cannot provide a
route, provider command, repository path, or trust decision in the message.

The worker parses the URL structurally, requires HTTPS GitHub `/owner/repo/issues/N`, canonicalizes
the slug, and verifies the issue and labels through `gh` under the user's login before inserting a
run.

### 5.2 Reconciliation: 60-second label poll

At startup and every 60 seconds, the worker lists open `agent:run` issues for every enabled
repository. Startup polling happens before normal sleeping. Pagination continues to completion
within configured resource bounds; a partial page never proves absence.

Both fast path and polling call the same `observe(issueURL, configSnapshot)` function. There is no
separate fast-path state machine.

For every repository, public or private, the worker verifies that activation was performed by a
trusted actor:

- An app fast-path activation is accepted only when the authenticated `gh` user has
  `WRITE`, `MAINTAIN`, or `ADMIN` permission on the repository.
- A polled activation is accepted only when the issue timeline shows the effective `agent:run`
  label addition was performed by an actor whose current repository permission is `WRITE`,
  `MAINTAIN`, or `ADMIN`.
- If the label was removed and re-added, the latest effective addition is authoritative.
- Missing timeline/permission evidence, API errors, or ambiguous identity fail closed. No run is
  inserted.

This permits a maintainer to deliberately label an outsider's issue while preventing an outsider
on a public repository — or a collaborator with only `READ` or `TRIAGE` permission on a private
repository — from self-activating arbitrary prompt text.

### 5.3 SQLite run ledger and idempotency

The SQLite database lives under `state_root`, uses WAL mode, foreign keys, a busy timeout, and
full durability for state transitions (`synchronous=FULL`). The durable run-group identity is:

```text
(repository, issue_number)
```

Every execution, including a rerun, creates a new immutable append-only run record under that
group with a unique run ID and its own `config_revision` snapshot. `config_revision` is per-run
audit data, never part of a unique key; prior terminal records are never mutated or deleted. A
partial unique index permits at most one non-terminal run per group, and `observe` inserts with
`INSERT ... ON CONFLICT DO NOTHING` against it, so fast path and polling converge on one row
while a run is in flight.

Passive eligibility is governed by the group's latest run record. While the latest record is
non-terminal, observation is a no-op. Once the latest record is terminal (`pr_opened` or
`failed`), or a pull request is already linked to the issue, `observe` suppresses passive pickup
of that issue regardless of later configuration edits; a new config revision alone never re-runs
it. On entering a terminal state the worker removes the `agent:run` label; when removal fails or
is not permitted, it durably marks the group label-removal-failed, so polling never treats a
completed issue as eligible.

Re-running an issue requires an explicit re-trigger, which creates a new run record under the
same group. v1 defines exactly two re-trigger paths:

1. **Activation-label re-application.** A trusted actor re-adds `agent:run` after the latest
   terminal record. Every run persists the identity and timestamp of the effective timeline
   label-add event that activated it. `observe` accepts a polled issue past a terminal latest
   record only when the timeline shows an effective `agent:run` addition strictly newer than the
   activating event of that terminal record. A label that is merely still present because
   terminal removal failed is a stale label, not a re-trigger; a group marked
   label-removal-failed fails closed and creates no run until the label state is reconciled.
2. **Local CLI rerun.** The worker CLI invocation `run --issue <url>` executes as the logged-in
   local user, applies the same uniform write-access verification and fail-closed trust rule from
   section 5.2, and creates a new run record.

The UI must show earlier terminal runs and a newer run separately.

Minimum durable fields are:

```text
id, repository, issue_number, issue_url, config_revision, route_id, agent_id,
trigger_kind, trigger_event_id, trigger_event_at, label_removal_outcome,
state, failure_code, base_sha, branch_name, workspace_id, workspace_path,
provider_pid, provider_exit, patch_path, log_dir, validated_sha,
remote_branch_sha, pr_number, pr_url, pr_is_draft,
created_at, claimed_at, updated_at, finished_at
```

Every transition also appends a `run_events` row in the same transaction. State is not inferred
from logs. Paths stored in SQLite must remain below `state_root` or a workspace path returned by
`WorkspaceManager`.

## 6. Run state machine

```text
queued -> claimed -> preparing -> running -> validating -> publishing -> pr_opened
   |         |           |          |             |            |
   +---------+-----------+----------+-------------+------------+-> failed
```

| State | Entry condition and owned work | Allowed next state |
|---|---|---|
| `queued` | Trusted trigger, matching route, unique ledger row | `claimed`, `failed` |
| `claimed` | Won the host-wide claim transaction | `preparing`, `failed` |
| `preparing` | Verified repo/default branch; pinned base SHA; acquired isolated lease; created fresh branch | `running`, `failed` |
| `running` | Provider process group launched with edit-only contract | `validating`, `failed` |
| `validating` | Provider exited; supervisor captured artifacts and accepted structural diff inspection | `publishing`, `failed` |
| `publishing` | All local validation green; publication intent durably recorded | `pr_opened`, `failed` |
| `pr_opened` | Remote branch SHA and matching draft PR verified; CI status recorded | terminal |
| `failed` | Failure code and retention disposition durably recorded | terminal |

The one-run concurrency rule is enforced by a SQLite `host_claim` singleton row updated in a
`BEGIN IMMEDIATE` transaction. A process-local mutex is insufficient. Startup clears a stale claim
only after proving its owning process is gone and reconciling the associated run.

Cancellation, timeout, provider failure, diff rejection, validation failure, and publication
failure all enter `failed` with distinct codes. Validation failure is specifically
`validation_failed_retained`; it is never retried automatically and never enters `publishing`.
On entering `pr_opened` or `failed`, the worker removes or marks the `agent:run` label as
specified in section 5.3 so the issue is no longer eligible for passive pickup.

### 6.1 Preparation

The worker resolves and fetches the configured default branch in its managed repository store,
records an immutable `base_sha`, and acquires a leased workspace. It creates exactly one fresh
branch:

```text
mai/issue-<N>-<slug>-<run-id>
```

`slug` is a lowercase ASCII issue-title slug, collapsed to hyphens and capped so the complete ref
is at most 120 bytes. `run-id` is an immutable short encoding of the ledger UUID. The worker fails
if the branch exists locally or remotely; it never reuses or force-updates it.

### 6.2 Provider execution

The supervisor writes a bounded prompt file containing trusted instructions and a clearly marked,
quoted untrusted issue block. The adapter launches without a shell, in the workspace, as a new
process group. Provider stdout/stderr are untrusted bytes: logs are length-bounded and escaped for
display; provider output never supplies a command, path, branch, commit message, PR title, or
publication decision without supervisor validation.

On timeout or cancellation, send SIGTERM to the positive process-group ID, wait
`provider_grace_seconds`, then SIGKILL the still-live group. The supervisor waits for process exit
before inspecting the workspace.

The provider may edit files only. The worker detects and rejects provider-created commits, tags,
remote changes, git configuration changes, hooks, or modifications to git metadata. The supervisor
resets only git metadata it owns; it retains file edits on failure.

### 6.3 Diff inspection and validation

Before any commit or network publication, `DiffInspector` compares the workspace to `base_sha` and
enforces all policies in section 8. An empty diff fails with `empty_diff_retained`. An accepted diff
is archived as a patch before validation.

Validation commands come from a named worker validation profile or trusted default-branch config,
not from the issue, provider output, or feature-branch config. A zero exit from every required
review/test/lint gate is necessary but not sufficient: the worker also verifies the workspace tree
and diff are unchanged from the inspected/validated SHA except for explicitly accepted formatter
fixes, which trigger inspection and validation again.

### 6.4 Publication and recovery

Only the supervisor commits. It writes a deterministic commit message referencing the issue,
records the resulting local SHA, then asks `Publisher` to validate and publish. Immediately before
the first network write it persists a publication-intent checkpoint containing repository,
branch, base SHA, head SHA, and required `draft = true`.

`Publisher` may push only the fresh run branch with a normal non-force push. It creates a PR only
with an explicit draft option and verifies the returned PR is draft. The PR body links the issue
without an auto-close keyword; merge remains a human decision. No code path invokes merge,
auto-merge, ready-for-review, force push, force-with-lease, or deletion of the default branch.

On startup, any `publishing` run is reconciled in this order:

1. Query the remote branch by exact name and record its SHA if present.
2. Query open and closed PRs by exact head branch and base repository.
3. If a matching PR exists, verify its head SHA and draft state; mark `pr_opened` only when both
   match. A non-draft PR is a safety failure requiring human correction.
4. If the remote branch exists at the expected SHA but no PR exists, create the draft PR once and
   verify it.
5. If no remote branch exists, resume the normal non-force push only when local artifacts still
   prove the expected SHA and validation result.
6. Any mismatched SHA, multiple PRs, unknown provider state, or API failure fails closed and retains
   the workspace. It never deletes or overwrites remote state.

This makes an interruption after push but before ledger update idempotent.

## 7. Menu-app integration contract

The app adds three worker-facing surfaces without moving sensitive work into `AppState`:

1. **Enable/disable per repository.** The repository picker/settings shows whether the canonical
   GitHub repository is configured and enabled. Enabling writes config through a worker-owned
   validated API or deliberately edits `agents.toml`; it must not synthesize executable argv.
   Disabling stops new labeling/enqueues and polling for that repository. It does not cancel or
   delete an in-flight or retained run.
2. **Fast-path enqueue.** On the existing `IssueFilingResult` success path, enqueue only the issue
   URL after `agent:run` has been requested. Filing success remains independent of pickup success.
3. **Status display.** The app reads a redacted projection: run ID, repository, issue number,
   state, timestamps, safe failure summary, retained-work flag, and draft PR URL. It never receives
   provider environment, raw logs, credentials, or arbitrary file paths. Terminal retained work
   offers `Reveal in Finder` through a worker-validated path, not direct path trust from IPC.

Expected user-visible states mirror the ledger: Queued, Preparing, Agent running, Validating,
Publishing, Draft PR opened, Failed (work retained), Unrouted, and Configuration error.

## 8. Safety invariants and enforcement points

| Invariant | Named enforcement point |
|---|---|
| Never work in the user's checkout | `RepositoryStore` accepts only worker-managed roots; `WorkspaceManager.acquire` rejects source/workspace paths outside them; provider CWD check before launch |
| Default branch is immutable | `RunPreparer` pins `base_sha`; `GitSupervisor` rejects default-branch checkout/commit/push and verifies branch name before every mutating git call |
| One fresh run branch | `BranchPolicy` generates `mai/issue-<N>-<slug>-<run-id>` and requires local/remote nonexistence |
| No force operations ever | `GitSupervisor` exposes no force option and rejects argv containing force, ref deletion, or leading `+`; `Publisher` contract forbids them |
| Provider cannot publish | `ProviderLauncher` uses a minimal environment with no `GH_TOKEN`, `GITHUB_TOKEN`, credential-helper variables, SSH agent socket, or `gh` config path; supervisor performs all git/`gh` after provider exit; provider output is untrusted |
| Diff inspected before publication | `DiffInspector` runs before validation and again after any accepted fix; `Publisher.publish` requires its signed result ID |
| Scope and path safety | `DiffInspector` rejects absolute paths, `..` escapes, `.git`/gitfile changes, case-collision tricks, device/FIFO/socket nodes, and files resolving outside workspace |
| Symlink safety | `DiffInspector` rejects new/changed absolute symlinks and relative symlinks whose lexical or resolved target escapes the workspace; traversal uses no-follow APIs |
| Submodule safety | `DiffInspector` rejects gitlink changes and any `.gitmodules` URL/path change in v1 |
| Size and binary safety | `DiffInspector` applies changed-file count, per-file, total-diff, workspace-size, and binary policy from `worker.limits` before validation and publication |
| Empty diff never publishes | `DiffInspector` returns `empty_diff_retained`; state cannot enter `publishing` |
| Validation precedes publication | `Publisher.publish` requires a durable green `ValidationReceipt` bound to config revision, base SHA, head SHA, diff digest, and validation profile |
| Draft PR only | `Publisher` requires `draft = true`; `PublicationReconciler` reads the created PR back and fails if it is not draft |
| Never auto-merge | No merge capability exists in `Publisher`; config has no merge field; CI completion only updates status |
| No data loss on cleanup | `ArtifactStore` records base SHA, full patch, logs, config revision, and run events before cleanup; `WorkspaceManager.release` is allowed only for clean, published work |
| Dirty/unpublished workspaces persist | `RetentionPolicy` converts the Treehouse lease to retained state and never calls reset/return/destroy automatically; deletion requires a separate user action after patch export |
| Idempotent triggers | Partial unique index allowing at most one non-terminal run per repository + issue group in `TriggerLedger.observe` |
| Terminal outcomes suppress passive pickup | `TriggerLedger.observe` skips issues whose latest run record is terminal or that have a linked PR, regardless of config edits; terminal transitions remove `agent:run` or durably mark removal failure; only an explicit re-trigger (label re-add newer than the latest terminal record's activating event, or `run --issue <url>`) creates a new run record |
| Interrupted publication reconciles | `PublicationReconciler` checks exact remote ref and PR before any retry |
| Bounded resources | `ResourceGovernor` applies run/provider/command timeouts, log caps, disk quotas, output truncation markers, one-run claim, and process-group teardown |

Environment removal is defense in depth, not an OS sandbox. A malicious same-user executable can
still attempt to read credential stores by absolute path; the companion threat model records that
residual risk. The invariant means no token is injected or intentionally made available to the
provider, and no worker publication capability is delegated to it.

## 9. Dependency seams

### 9.1 `WorkspaceManager`

The production preference is the MIT-licensed
[Treehouse](https://github.com/kunchenguid/treehouse), wrapped so the worker does not depend on its
CLI text or storage layout.

```text
acquire(repositoryStore, baseSHA, runID) -> WorkspaceLease
prepare(lease, branchName, baseSHA) -> PreparedWorkspace
inspect(lease) -> WorkspaceFacts
retain(lease, reason, artifacts) -> RetainedWorkspace
releaseCleanPublished(lease, publicationReceipt) -> void
recover() -> [RecoveredWorkspace]
```

`WorkspaceLease` contains an opaque ID, canonical path, source-store identity, and durable lease
proof. `acquire` must be exclusive and return a clean detached worktree at the requested base.
`prepare` must fail if the requested branch exists. `retain` is non-destructive and survives worker
restart. `releaseCleanPublished` is the only automatic release operation and must verify a clean
tree plus archived artifacts. There is deliberately no generic `force cleanup` method.

#### Treehouse verification and adapter posture

Verification on 2026-07-15 used installed `treehouse v2.0.0` and `treehouse --help`, `get --help`,
`return --help`, and `destroy --help`, plus the upstream README. Treehouse provides pooled reusable
isolated worktrees, a non-interactive durable `treehouse get --lease`, and no daemon. Its return
path resets a workspace, and destructive inclusion of unlanded work is explicit.

The adapter therefore:

- runs Treehouse against the worker-owned repository store with an isolated worker HOME/config so
  user-level Treehouse shell hooks are not inherited;
- acquires with `get --lease` and records the returned canonical path;
- never calls `return --force` or `destroy`;
- does not call normal `return` for dirty, failed, unvalidated, or unpublished work;
- may call normal return only through `releaseCleanPublished` after artifact retention.

If a pinned Treehouse version loses durable leases, no-daemon operation, dirty detection, or safe
release semantics, the adapter is disabled and a self-contained git-worktree implementation must
provide the same seam.

### 9.2 `Publisher`

The production direction is the MIT-licensed
[no-mistakes](https://github.com/kunchenguid/no-mistakes), wrapped behind:

```text
capabilities() -> PublisherCapabilities
validate(request) -> ValidationReceipt | ValidationFailure
publish(request, ValidationReceipt, draft=true) -> PublicationReceipt
reconcile(PublicationIntent) -> PublicationStatus
collectArtifacts(runID) -> PublisherArtifacts
```

`ValidationReceipt` is immutable and bound to repository, config revision, base SHA, head SHA,
diff digest, validation profile, tool version, and timestamp. `publish` rejects a stale/mismatched
receipt, any `draft != true`, an existing branch, or a non-fast-forward/force requirement.
`PublicationReceipt` includes pushed SHA, PR number/URL, verified draft state, and observed CI.

`PublisherCapabilities` must explicitly report draft creation, pre-push validation, token isolation
between validator and publisher, no-force behavior, artifact export, and startup reconciliation.
Marketing text or a zero exit code is not a capability proof.

#### no-mistakes capability verdict (verified 2026-07-15)

Installed version: `no-mistakes v1.34.0 (dc5a800)`. The following were inspected locally:
`no-mistakes --help`, `init --help`, `doctor`, `status`, `daemon --help`, and
`axi run --help`. Upstream docs and the source for v1.34.0 and current main were also inspected.

Findings:

1. **Green-gated push and PR:** supported. The documented pipeline is review -> test -> document ->
   lint -> push -> PR -> CI in a disposable worktree, and nothing is forwarded until checks pass.
2. **Draft PR creation:** **not supported by v1.34.0 or current main.** Both GitHub `CreatePR`
   implementations build `gh pr create --head ... --base ... --title ... --body-file -` without
   `--draft`; no installed CLI flag requests draft creation. Running that PR step would violate
   this product contract.
3. **Per-repository initialization footprint:** `no-mistakes init` creates/refreshes a bare gate at
   `~/.no-mistakes/repos/<id>.git`, installs a post-receive hook, adds/repairs a `no-mistakes`
   remote, records the repo, and installs its agent skill. For this product it may operate only on
   the worker-owned repository store, never the user's checkout.
4. **Daemon footprint:** no-mistakes installs one long-running per-user daemon shared by all
   initialized repositories. On macOS that is an additional LaunchAgent, with socket, database,
   logs, and disposable worktrees under `NM_HOME`. This is separate from the
   `make-an-issue-worker` LaunchAgent and must be disclosed and user-approved during installation.
5. **Credential/process split:** current no-mistakes owns both validation-agent processes and the
   provider CLI used for PR/CI in one daemon environment. Its docs describe prompt steering rather
   than an OS sandbox. The adapter must prove that validation agents cannot inherit or discover the
   worker's GitHub publication credentials before claiming `tokenIsolation = true`.

Consequently, the upstream no-mistakes full adapter is **disabled for MVP publication** until both
draft creation and credential separation pass executable capability tests. `publisher_backend =
"no-mistakes"` with the currently verified binary is a configuration error, not permission to open
a ready-for-review PR.

With `publisher_backend = "auto"`, the MVP uses the self-contained `Publisher` implementation for
the incompatible portions. It may use no-mistakes for a validation-only/gated-push subflow only if
the exact pinned version proves that PR and CI are skipped, no publication occurs on red, all
artifacts are exported before its disposable workspace is removed, and validation subprocesses do
not receive GitHub credentials. The supervisor then creates the draft PR itself and observes CI.
Otherwise the fallback performs validation, normal push, `gh pr create --draft`, read-back
verification, and CI polling itself. The seam and receipts are identical, so a future compatible
no-mistakes release can replace it without changing routing, ledger, or safety policy.

The fallback is intentionally narrow; it is not a general pipeline engine. It runs only named
validation profiles, normal git push, draft PR creation, and CI status observation.

### 9.3 Evidence references

- [Treehouse README at verified main](https://github.com/kunchenguid/treehouse/blob/f31e04e052a3fba1f50afedc65f2c781769aab4a/README.md)
- [Treehouse MIT license](https://github.com/kunchenguid/treehouse/blob/f31e04e052a3fba1f50afedc65f2c781769aab4a/LICENSE)
- [no-mistakes README pipeline description](https://github.com/kunchenguid/no-mistakes/blob/2bbbc143bd4520056e97957883a02615657b2a62/README.md)
- [no-mistakes v1.34.0 GitHub PR creation source](https://github.com/kunchenguid/no-mistakes/blob/v1.34.0/internal/scm/github/github.go#L218-L235)
- [no-mistakes current GitHub PR creation source](https://github.com/kunchenguid/no-mistakes/blob/2bbbc143bd4520056e97957883a02615657b2a62/internal/scm/github/github.go#L218-L235)
- [no-mistakes quick-start init footprint](https://github.com/kunchenguid/no-mistakes/blob/2bbbc143bd4520056e97957883a02615657b2a62/docs/src/content/docs/start-here/quick-start.md#L36-L73)
- [no-mistakes daemon/worktree footprint](https://github.com/kunchenguid/no-mistakes/blob/2bbbc143bd4520056e97957883a02615657b2a62/docs/src/content/docs/concepts/daemon.md)
- [no-mistakes MIT license](https://github.com/kunchenguid/no-mistakes/blob/2bbbc143bd4520056e97957883a02615657b2a62/LICENSE)
- [GitHub CLI draft PR flag](https://cli.github.com/manual/gh_pr_create)

## 10. Retention and resource policy

Before any cleanup, the worker retains:

- repository and issue identity, config revision, route, agent, timestamps, and final state;
- immutable base SHA and every local/validated/published SHA;
- full patch against base SHA plus a SHA-256 digest;
- bounded provider, validation, git, and publication logs with truncation markers;
- the workspace lease/path and a reason when work remains dirty or unpublished;
- remote branch and PR observations used during reconciliation.

Published, clean workspaces may return to the pool after artifacts are durable. Dirty or
unpublished workspaces are never automatically reset, returned, destroyed, garbage-collected, or
quota-evicted. When retained work exceeds disk limits, the worker stops claiming new runs and asks
the user to export/delete retained runs; it does not reclaim them silently.

Every subprocess has a wall-clock timeout, capped stdout/stderr, an isolated process group, a
minimal environment, and TERM-to-KILL teardown. The worker also caps prompt size, issue body size,
SQLite result counts, GitHub pagination, workspace bytes, changed file count, diff bytes, and
single-file bytes. Hitting a cap fails the run and retains available artifacts.

## 11. Out of scope for v1

The following are explicitly not part of the MVP:

- Webhooks.
- Multi-host claiming or distributed locks.
- Auto-merge or automatic ready-for-review transitions.
- Generic arbitrary-command provider adapters.
- Hosted GitHub Actions execution backends.
- Multiple simultaneous runs on one host.
- Provider fallback after a provider has begun editing.
- Automatic deletion of retained dirty/unpublished work.
- A dedicated rerun verb. It is deferred from v1 because `run --issue <url>` and activation-label
  re-application already provide the v1 rerun paths.

## 12. Implementation acceptance checklist

An implementation is conformant only when tests demonstrate:

- fast enqueue and a 60-second startup/periodic poll converge on one ledger row;
- observation is idempotent per repository + issue run group: at most one non-terminal run exists
  per group, a terminal latest run or linked pull request suppresses passive pickup regardless of
  configuration edits, a stale still-present label after failed removal creates no run, and only
  an explicit re-trigger — label re-application newer than the latest terminal record's activating
  event, or `run --issue <url>` — creates a new run record with its own config-revision snapshot;
- untrusted triggers on public and private repositories and equal route priorities fail closed;
- no route adds `agent:unrouted` and launches no process;
- the exact state transitions and one-host claim survive restart;
- provider processes have no injected GitHub credential and cannot call a publication API through
  the worker;
- user checkout, default branch, force operations, unsafe paths/symlinks/submodules, empty diffs,
  oversized/binary diffs, and stale validation receipts are rejected;
- validation failure produces no remote ref or PR and leaves patch/logs/workspace retained;
- interruption after push reconciles to exactly one verified draft PR;
- all created PRs are read back as draft and no merge capability exists;
- Treehouse and no-mistakes adapters pass executable capability/contract tests, with the builtin
  fallback selected when they do not.
