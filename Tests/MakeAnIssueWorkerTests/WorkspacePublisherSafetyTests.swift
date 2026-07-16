import Darwin
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class WorkspacePublisherSafetyTests: XCTestCase {
    func testForcePushArgumentsAreRejected() {
        XCTAssertThrowsError(
            try GitMutationPolicy.validate(
                arguments: ["push", "--force-with-lease", "origin", "refs/heads/topic:refs/heads/topic"],
                branch: "topic",
                defaultBranch: "main"
            )
        ) { error in
            guard case GitSafetyError.forceOperation = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertThrowsError(
            try GitMutationPolicy.validate(
                arguments: ["push", "origin", "+refs/heads/topic:refs/heads/topic"],
                branch: "topic",
                defaultBranch: "main"
            )
        )
    }

    func testDefaultBranchMutationIsRejected() {
        XCTAssertThrowsError(
            try GitMutationPolicy.validate(
                arguments: ["commit"],
                branch: "main",
                defaultBranch: "main"
            )
        ) { error in
            XCTAssertEqual(error as? GitSafetyError, .defaultBranchMutation("main"))
        }
    }

    func testDiffInspectorRejectsEmptyOversizedAndTooManyFiles() throws {
        try withPreparedWorkspace { _, config, _, git in
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: try git.currentHead())) { error in
                XCTAssertEqual(error as? DiffInspectionError, .empty)
            }
        }

        try withPreparedWorkspace(transform: {
            $0.replacingOccurrences(of: "max_diff_bytes = 5242880", with: "max_diff_bytes = 16")
        }) { workspace, config, base, git in
            try Data(String(repeating: "x", count: 128).utf8).write(to: workspace.appendingPathComponent("large.txt"))
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: base)) { error in
                guard case DiffInspectionError.diffTooLarge = error else { return XCTFail("unexpected error: \(error)") }
            }
        }

        try withPreparedWorkspace(transform: {
            $0.replacingOccurrences(of: "max_changed_files = 500", with: "max_changed_files = 1")
        }) { workspace, config, base, git in
            try Data("a".utf8).write(to: workspace.appendingPathComponent("a.txt"))
            try Data("b".utf8).write(to: workspace.appendingPathComponent("b.txt"))
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: base)) { error in
                XCTAssertEqual(error as? DiffInspectionError, .tooManyFiles(2))
            }
        }
    }

    func testDiffInspectorRejectsPerFileBinarySymlinkAndSubmoduleChanges() throws {
        try withPreparedWorkspace(transform: {
            $0.replacingOccurrences(of: "max_single_file_bytes = 1048576", with: "max_single_file_bytes = 4")
        }, gitTimeoutSeconds: loadTolerantGitTimeoutSeconds) { workspace, config, base, git in
            try Data("12345".utf8).write(to: workspace.appendingPathComponent("large.txt"))
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: base)) { error in
                XCTAssertEqual(error as? DiffInspectionError, .fileTooLarge("large.txt", 5))
            }
        }

        try withPreparedWorkspace(gitTimeoutSeconds: loadTolerantGitTimeoutSeconds) { workspace, config, base, git in
            try Data([0, 1, 2, 3]).write(to: workspace.appendingPathComponent("binary.dat"))
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: base)) { error in
                guard case DiffInspectionError.binary("binary.dat") = error else { return XCTFail("unexpected error: \(error)") }
            }
        }

        try withPreparedWorkspace(gitTimeoutSeconds: loadTolerantGitTimeoutSeconds) { workspace, config, base, git in
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("escape"),
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: base)) { error in
                guard case DiffInspectionError.unsafeSymlink("escape") = error else { return XCTFail("unexpected error: \(error)") }
            }
        }

        try withPreparedWorkspace(gitTimeoutSeconds: loadTolerantGitTimeoutSeconds) { workspace, config, base, git in
            try Data("[submodule \"x\"]\n\tpath = x\n\turl = https://example.invalid/x\n".utf8)
                .write(to: workspace.appendingPathComponent(".gitmodules"))
            XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: base)) { error in
                XCTAssertEqual(error as? DiffInspectionError, .submodule(".gitmodules"))
            }
        }
    }

    func testProviderIndexStagingIsAllowedButProtectedSurfaceTamperingIsLabeled() throws {
        try withPreparedWorkspace(gitTimeoutSeconds: loadTolerantGitTimeoutSeconds) { workspace, _, _, git in
            let baseline = try git.snapshotMetadata()

            // A provider staging its own edits (git add) is explicitly permitted and must not be
            // mistaken for tampering with the protected git surface.
            try Data("provider change\n".utf8).write(to: workspace.appendingPathComponent("change.txt"))
            try runProcess(
                "/usr/bin/git",
                ["add", "--all"],
                cwd: workspace,
                timeoutSeconds: loadTolerantGitTimeoutSeconds
            )
            XCTAssertNoThrow(try git.verifyMetadataUnchanged(from: baseline))

            // Tampering with a protected surface (here: refs) is rejected with a specific label.
            try runProcess(
                "/usr/bin/git",
                ["update-ref", "refs/heads/injected", "HEAD"],
                cwd: workspace,
                timeoutSeconds: loadTolerantGitTimeoutSeconds
            )
            XCTAssertThrowsError(try git.verifyMetadataUnchanged(from: baseline)) { error in
                guard case GitSafetyError.protectedSurfaceTampered(let surface) = error else {
                    return XCTFail("expected protectedSurfaceTampered, got \(error)")
                }
                XCTAssertEqual(surface, "refs")
            }
        }
    }

    func testReconciliationRejectsNonDraftPullRequest() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        try Data("change\n".utf8).write(to: prepared.workspace.appendingPathComponent("change.txt"))
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: "draft-check")
        try artifacts.archive(inspection)
        let environment = try nonDraftGHEnvironment(root: fixture.root, origin: origin.origin)
        let publisher = BuiltinPublisher(stateRoot: fixture.stateRoot, environment: environment)
        let receipt = try publisher.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)
        let request = PublicationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            issueTitle: "Draft safety",
            configRevision: config.revision,
            validationProfile: "default",
            defaultBranch: "main",
            branchName: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA,
            diffDigest: inspection.digest,
            git: prepared.git
        )

        XCTAssertThrowsError(try publisher.reconcile(PublicationIntent(request: request, validationReceipt: receipt))) { error in
            XCTAssertEqual(error as? PublisherError, .nonDraftPullRequest(9))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.workspace.path))
    }

    func testFreshBranchPushAndReconciliationNeverOverwriteRemoteDivergence() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        try Data("validated\n".utf8).write(to: prepared.workspace.appendingPathComponent("validated.txt"))
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: "divergence")
        try artifacts.archive(inspection)
        let publisher = BuiltinPublisher(stateRoot: fixture.stateRoot)
        let receipt = try publisher.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)
        XCTAssertThrowsError(try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)) { error in
            XCTAssertEqual(error as? GitSafetyError, .branchExists(prepared.branch))
        }

        try runProcess(
            "/usr/bin/git",
            ["--git-dir", origin.origin.path, "update-ref", "refs/heads/\(prepared.branch)", origin.mainSHA]
        )
        let request = PublicationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            issueTitle: "Divergence",
            configRevision: config.revision,
            validationProfile: "default",
            defaultBranch: "main",
            branchName: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA,
            diffDigest: inspection.digest,
            git: prepared.git
        )
        XCTAssertThrowsError(try publisher.reconcile(PublicationIntent(request: request, validationReceipt: receipt))) { error in
            XCTAssertEqual(
                error as? PublisherError,
                .remoteDivergence(expected: receipt.headSHA, observed: origin.mainSHA)
            )
        }
        let observed = try runProcess(
            "/usr/bin/git",
            ["--git-dir", origin.origin.path, "rev-parse", "refs/heads/\(prepared.branch)"]
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(observed, origin.mainSHA, "reconciliation must never overwrite a divergent remote ref")
    }

    func testTreehouseAdapterUsesDurableLeaseAndNeverReturnsRetainedWork() throws {
        let fixture = try ConfigFixture(workspaceBackend: "builtin")
        try FileManager.default.createDirectory(at: fixture.stateRoot, withIntermediateDirectories: true)
        let source = fixture.stateRoot.appendingPathComponent("repositories/acme--widgets", isDirectory: true)
        let workspace = fixture.stateRoot.appendingPathComponent("treehouse-pool/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executor = RecordingExecutor(workspacePath: workspace.path)
        let manager = TreehouseWorkspaceManager(
            stateRoot: fixture.stateRoot,
            executable: "/fixture/treehouse",
            processes: executor,
            path: "/usr/bin:/bin"
        )
        let store = RepositoryStore(
            repository: "acme/widgets",
            path: source,
            remote: "fixture",
            defaultBranch: "main",
            baseSHA: String(repeating: "a", count: 40)
        )

        let lease = try manager.acquire(repositoryStore: store, baseSHA: store.baseSHA, runID: "run-1")
        _ = try manager.retain(lease: lease, reason: "validation_failed_retained", artifacts: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.proofPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateRoot.appendingPathComponent("retained/run-1.json").path))
        XCTAssertTrue(executor.calls.contains { $0.arguments == ["get", "--lease", "--lease-holder", "run-1"] })
        XCTAssertFalse(executor.calls.contains { $0.arguments.contains("return") })
        let getCall = try XCTUnwrap(executor.calls.first { $0.arguments.first == "get" })
        XCTAssertEqual(getCall.environment["HOME"], fixture.stateRoot.appendingPathComponent("treehouse-home").path)
    }

    func testStartupReconciliationRepairsPushThenCrashExactlyOnce() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let inserted = try ledger.createRun(NewRun(
            id: prepared.lease.id,
            issue: makeIssue(),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let run) = inserted else { return XCTFail("expected run creation") }
        _ = try ledger.claimHost(runID: run.id, ownerPID: Int32.max)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: run.id)
        try ledger.recordPreparation(
            runID: run.id,
            baseSHA: prepared.baseSHA,
            branchName: prepared.branch,
            workspace: prepared.lease,
            artifacts: artifacts
        )
        _ = try ledger.transition(runID: run.id, to: .running)
        try Data("reconcile\n".utf8).write(to: prepared.workspace.appendingPathComponent("reconcile.txt"))
        try ledger.recordProviderExit(runID: run.id, pid: nil, exit: 0)
        _ = try ledger.transition(runID: run.id, to: .validating)
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        try artifacts.archive(inspection)
        try ledger.recordInspection(runID: run.id, inspection: inspection)
        let environment = try draftGHEnvironment(root: fixture.root, origin: origin.origin)
        let publisher = BuiltinPublisher(stateRoot: fixture.stateRoot, environment: environment)
        let receipt = try publisher.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        try ledger.recordValidatedSHA(runID: run.id, sha: receipt.headSHA, receiptID: receipt.id)
        try ledger.recordPublicationIntent(
            runID: run.id,
            branch: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA
        )
        _ = try ledger.transition(runID: run.id, to: .publishing)
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)

        let service = RunService(config: config, ledger: ledger, environment: environment)
        try service.reconcilePublishingRuns()
        XCTAssertEqual(try ledger.run(id: run.id).state, .prOpened)
        XCTAssertNil(try ledger.currentHostClaim())
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.workspace.path))
        let countURL = fixture.root.appendingPathComponent("create-count")
        XCTAssertEqual(try String(contentsOf: countURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")

        try service.reconcilePublishingRuns()
        XCTAssertEqual(try String(contentsOf: countURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testStartupReclaimsDeadOwnerClaimAndRetainsInterruptedRun() throws {
        // A crash while holding the singleton host claim in a pre-publication state (here: running)
        // must not block all future work. Startup reconciliation reclaims the dead owner's claim,
        // marks the interrupted run failed with an explicit disposition, retains its workspace and
        // artifacts, and frees the host so new runs can proceed.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root, timeoutSeconds: loadTolerantGitTimeoutSeconds)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let inserted = try ledger.createRun(NewRun(
            id: prepared.lease.id,
            issue: makeIssue(),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let run) = inserted else { return XCTFail("expected run creation") }
        _ = try ledger.claimHost(runID: run.id, ownerPID: Int32.max)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: run.id)
        try ledger.recordPreparation(
            runID: run.id,
            baseSHA: prepared.baseSHA,
            branchName: prepared.branch,
            workspace: prepared.lease,
            artifacts: artifacts
        )
        _ = try ledger.transition(runID: run.id, to: .running)

        let service = RunService(config: config, ledger: ledger)
        try service.reconcileStartup()

        let reconciled = try ledger.run(id: run.id)
        XCTAssertEqual(reconciled.state, .failed, "a run interrupted before publication must not be resumed")
        XCTAssertEqual(reconciled.failureCode, "worker_interrupted_retained")
        XCTAssertNil(try ledger.currentHostClaim(), "a dead owner's claim must be reclaimed so new work is never blocked")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.stateRoot.appendingPathComponent("retained/\(run.id).json").path),
            "the interrupted workspace must be retained"
        )
        let dispositions = try ledger.events(runID: run.id).filter { $0.kind == "workspace_disposition" }.compactMap(\.detail)
        XCTAssertTrue(
            dispositions.contains { $0.hasPrefix("retained:worker_interrupted_retained") },
            "the interrupted retention must be a visible diagnostic, got \(dispositions)"
        )

        // The host is provably free: a brand-new run claims it without a host_busy failure.
        let next = try ledger.createRun(NewRun(
            id: UUID().uuidString.lowercased(),
            issue: try makeIssue(number: 99),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let nextRun) = next else { return XCTFail("expected run creation") }
        XCTAssertNoThrow(try ledger.claimHost(runID: nextRun.id))
    }

    func testStartupNeverStealsALiveHostClaim() throws {
        // A live (or indeterminate) owner must never be reclaimed. pid 1 (launchd) is always alive
        // and is not this process, exercising the start-time liveness probe rather than the
        // self-PID shortcut.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let inserted = try ledger.createRun(makeNewRun(issue: try makeIssue()))
        guard case .created(let run) = inserted else { return XCTFail("expected run creation") }
        _ = try ledger.claimHost(runID: run.id, ownerPID: 1)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        _ = try ledger.transition(runID: run.id, to: .running)

        let service = RunService(config: config, ledger: ledger)
        try service.reconcileStartup()

        XCTAssertEqual(try ledger.run(id: run.id).state, .running, "a live owner's run must never be reclaimed or failed")
        XCTAssertEqual(try ledger.currentHostClaim()?.ownerPID, 1, "a live owner's host claim must be preserved")
    }

    func testReconciliationStaysPublishingOnTransientPublisherFailureThenConverges() throws {
        // A transient gh outage after a push-before-record crash must never terminalize a run whose
        // remote draft PR may already exist. The run stays in publishing (retryable) with a visible
        // diagnostic; when gh recovers, reconciliation converges to pr_opened, opening the PR once.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root, timeoutSeconds: loadTolerantGitTimeoutSeconds)
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let seeded = try seedPushedPublishingRun(fixture: fixture, config: config, origin: origin.origin, ledger: ledger, marker: "transient")
        let run = seeded.run

        let transientEnvironment = try transientGHEnvironment(root: fixture.root, origin: origin.origin)
        let transientService = RunService(config: config, ledger: ledger, environment: transientEnvironment)
        try transientService.reconcileStartup()

        let deferredRun = try ledger.run(id: run.id)
        XCTAssertEqual(deferredRun.state, .publishing, "a transient publisher failure must never terminalize a reconcilable run")
        XCTAssertNil(deferredRun.failureCode)
        XCTAssertNil(try ledger.currentHostClaim(), "the run must release the host claim while awaiting retry")
        let diagnostics = try ledger.events(runID: run.id).filter { $0.kind == "publication_reconciliation_deferred" }
        XCTAssertFalse(diagnostics.isEmpty, "a deferred reconciliation must leave a visible diagnostic")

        let draftEnvironment = try draftGHEnvironment(root: fixture.root, origin: origin.origin)
        let draftService = RunService(config: config, ledger: ledger, environment: draftEnvironment)
        try draftService.reconcileStartup()

        let reconciled = try ledger.run(id: run.id)
        XCTAssertEqual(reconciled.state, .prOpened)
        XCTAssertNil(reconciled.failureCode)
        XCTAssertEqual(reconciled.prNumber, 23)
        XCTAssertNil(try ledger.currentHostClaim())
        let countURL = fixture.root.appendingPathComponent("create-count")
        XCTAssertEqual(
            try String(contentsOf: countURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "1",
            "convergence after a transient failure must open the draft PR exactly once"
        )
    }

    func testReconciliationTerminalizesOnDeterministicNonDraftPullRequest() throws {
        // A deterministic safety violation — an existing pull request that is not a draft — must
        // terminalize the run (it can never converge on retry) with full retention, unlike a
        // transient failure which stays publishing.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root, timeoutSeconds: loadTolerantGitTimeoutSeconds)
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let seeded = try seedPushedPublishingRun(fixture: fixture, config: config, origin: origin.origin, ledger: ledger, marker: "nondraft")
        let run = seeded.run

        let environment = try nonDraftGHEnvironment(root: fixture.root, origin: origin.origin)
        let service = RunService(config: config, ledger: ledger, environment: environment)
        try service.reconcileStartup()

        let reconciled = try ledger.run(id: run.id)
        XCTAssertEqual(reconciled.state, .failed, "a non-draft PR is a deterministic safety violation and must terminalize")
        XCTAssertEqual(reconciled.failureCode, "publication_reconciliation_failed_retained")
        XCTAssertNil(try ledger.currentHostClaim(), "a failed reconciliation must release its host claim")
    }

    func testReconciliationKeepsPROpenedWhenPostPublicationCleanupFails() throws {
        // Regression: once the draft PR is recorded and the run transitions to the terminal
        // pr_opened state, a failure in post-publication cleanup (here the workspace-release
        // manager cannot be constructed because the frozen treehouse backend is not installed)
        // must be recorded as a deferred observation and must never route through
        // failReconciliation to reclassify the successful publication.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "treehouse")
        let origin = try makeBareOrigin(root: fixture.root)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let inserted = try ledger.createRun(NewRun(
            id: prepared.lease.id,
            issue: makeIssue(),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let run) = inserted else { return XCTFail("expected run creation") }
        _ = try ledger.claimHost(runID: run.id, ownerPID: Int32.max)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: run.id)
        try ledger.recordPreparation(
            runID: run.id,
            baseSHA: prepared.baseSHA,
            branchName: prepared.branch,
            workspace: prepared.lease,
            artifacts: artifacts
        )
        _ = try ledger.transition(runID: run.id, to: .running)
        try Data("cleanup\n".utf8).write(to: prepared.workspace.appendingPathComponent("cleanup.txt"))
        try ledger.recordProviderExit(runID: run.id, pid: nil, exit: 0)
        _ = try ledger.transition(runID: run.id, to: .validating)
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        try artifacts.archive(inspection)
        try ledger.recordInspection(runID: run.id, inspection: inspection)
        let environment = try draftGHEnvironment(root: fixture.root, origin: origin.origin)
        let publisher = BuiltinPublisher(stateRoot: fixture.stateRoot, environment: environment)
        let receipt = try publisher.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        try ledger.recordValidatedSHA(runID: run.id, sha: receipt.headSHA, receiptID: receipt.id)
        try ledger.recordPublicationIntent(
            runID: run.id,
            branch: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA
        )
        _ = try ledger.transition(runID: run.id, to: .publishing)
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)

        let service = RunService(config: config, ledger: ledger, environment: environment)
        try service.reconcilePublishingRuns()

        let reconciled = try ledger.run(id: run.id)
        XCTAssertEqual(reconciled.state, .prOpened, "post-publication cleanup failure must not reclassify a recorded draft PR")
        XCTAssertNil(reconciled.failureCode)
        XCTAssertEqual(reconciled.prNumber, 23)
        XCTAssertEqual(reconciled.prURL, "https://github.com/acme/widgets/pull/23")
        XCTAssertEqual(reconciled.prIsDraft, true)
        XCTAssertNil(try ledger.currentHostClaim(), "host claim must still be released after a deferred cleanup")

        let dispositions = try ledger.events(runID: run.id).filter { $0.kind == "workspace_disposition" }.compactMap(\.detail)
        XCTAssertTrue(
            dispositions.contains { $0.hasPrefix("clean_published_release_deferred") },
            "cleanup failure must be recorded as a deferred observation, got \(dispositions)"
        )
    }

    func testReconciliationRecordingFailureStaysPublishingAndConvergesExactlyOnce() throws {
        // Regression: once publisher.reconcile has verified the remote draft PR open, a failure of
        // the durable local recording (remote branch + PR metadata + the pr_opened transition, now
        // one atomic write) must never reclassify the run as failed. The run stays in publishing so
        // a later pass re-drives it idempotently — finding the already-open PR without a second
        // create — and a persistent recording failure is visible without ever looping.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root, timeoutSeconds: loadTolerantGitTimeoutSeconds)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let inserted = try ledger.createRun(NewRun(
            id: prepared.lease.id,
            issue: makeIssue(),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let run) = inserted else { return XCTFail("expected run creation") }
        _ = try ledger.claimHost(runID: run.id, ownerPID: Int32.max)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: run.id)
        try ledger.recordPreparation(
            runID: run.id,
            baseSHA: prepared.baseSHA,
            branchName: prepared.branch,
            workspace: prepared.lease,
            artifacts: artifacts
        )
        _ = try ledger.transition(runID: run.id, to: .running)
        try Data("recording\n".utf8).write(to: prepared.workspace.appendingPathComponent("recording.txt"))
        try ledger.recordProviderExit(runID: run.id, pid: nil, exit: 0)
        _ = try ledger.transition(runID: run.id, to: .validating)
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        try artifacts.archive(inspection)
        try ledger.recordInspection(runID: run.id, inspection: inspection)
        let environment = try draftGHEnvironment(root: fixture.root, origin: origin.origin)
        let publisher = BuiltinPublisher(stateRoot: fixture.stateRoot, environment: environment)
        let receipt = try publisher.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        try ledger.recordValidatedSHA(runID: run.id, sha: receipt.headSHA, receiptID: receipt.id)
        try ledger.recordPublicationIntent(
            runID: run.id,
            branch: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA
        )
        _ = try ledger.transition(runID: run.id, to: .publishing)
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)

        let countURL = fixture.root.appendingPathComponent("create-count")
        let service = RunService(config: config, ledger: ledger, environment: environment)

        // Persistent recording failure: the remote PR is opened but the local write always throws.
        ledger.recordPublicationFaultForTesting = { throw LedgerError.sqlite("injected recording failure") }
        for pass in 1...2 {
            try service.reconcilePublishingRuns()
            let deferred = try ledger.run(id: run.id)
            XCTAssertEqual(deferred.state, .publishing, "pass \(pass): recording failure must not reclassify the run")
            XCTAssertNil(deferred.failureCode, "pass \(pass): a run with an open remote PR must not be marked failed")
            XCTAssertNil(deferred.prNumber, "pass \(pass): the atomic recording must roll back, leaving no partial PR metadata")
            XCTAssertNil(deferred.remoteBranchSHA, "pass \(pass): the atomic recording must roll back the remote branch too")
            XCTAssertEqual(
                try String(contentsOf: countURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                "1",
                "pass \(pass): the remote draft PR must be created exactly once across retries"
            )
        }
        let diagnostics = try ledger.events(runID: run.id).filter { $0.kind == "publication_recording_deferred" }
        XCTAssertFalse(diagnostics.isEmpty, "the deferred recording must be recorded as a visible diagnostic")

        // The ledger becomes writable again; reconciliation converges without a second remote create.
        ledger.recordPublicationFaultForTesting = nil
        try service.reconcilePublishingRuns()
        let reconciled = try ledger.run(id: run.id)
        XCTAssertEqual(reconciled.state, .prOpened)
        XCTAssertNil(reconciled.failureCode)
        XCTAssertEqual(reconciled.prNumber, 23)
        XCTAssertEqual(reconciled.prURL, "https://github.com/acme/widgets/pull/23")
        XCTAssertEqual(reconciled.prIsDraft, true)
        XCTAssertNil(try ledger.currentHostClaim())
        XCTAssertEqual(
            try String(contentsOf: countURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "1",
            "convergence must reuse the existing remote PR, never create a second one"
        )

        // A terminal run is no longer a publishing candidate, so further passes are inert no-ops.
        try service.reconcilePublishingRuns()
        XCTAssertTrue(try ledger.publishingReconciliationCandidates().isEmpty)
        XCTAssertEqual(
            try String(contentsOf: countURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )
    }

    func testReconciliationIsolatesEachCandidateAndNeverBlocksTheBatch() throws {
        // Per-run isolation: a candidate that fails reconciliation must be marked failed,
        // release its host claim, and never abort the loop for the candidates queued behind it.
        // Kept ledger-only (no real git) so the guarantee stays deterministic under suite load.
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)

        let first = try seedIncompletePublishingCandidate(config: config, ledger: ledger, issueNumber: 42, claimOwnerPID: Int32.max)
        let second = try seedIncompletePublishingCandidate(config: config, ledger: ledger, issueNumber: 43)
        let third = try seedIncompletePublishingCandidate(config: config, ledger: ledger, issueNumber: 44)

        let service = RunService(config: config, ledger: ledger)
        try service.reconcilePublishingRuns()

        for runID in [first, second, third] {
            let run = try ledger.run(id: runID)
            XCTAssertEqual(run.state, .failed, "every candidate must be reconciled, not just the first")
            XCTAssertEqual(run.failureCode, "publication_reconciliation_failed_retained")
        }
        XCTAssertNil(try ledger.currentHostClaim(), "a failing candidate must release its host claim")

        // Persistent visibility: the failed runs stay terminal across repeated passes and are no
        // longer publishing candidates requiring attention.
        try service.reconcilePublishingRuns()
        XCTAssertTrue(try ledger.publishingReconciliationCandidates().isEmpty)
        for runID in [first, second, third] {
            XCTAssertEqual(try ledger.run(id: runID).state, .failed)
        }
    }

    /// Drives a run to the `publishing` state through the ledger without recording the artifacts
    /// reconciliation requires, so `reconcilePublishingRuns` fails it via the incomplete-artifacts
    /// guard — a fast, git-free failure that still exercises the per-candidate isolation path.
    @discardableResult
    private func seedIncompletePublishingCandidate(
        config: WorkerConfigSnapshot,
        ledger: RunLedger,
        issueNumber: Int,
        claimOwnerPID: Int32? = nil
    ) throws -> String {
        let inserted = try ledger.createRun(NewRun(
            id: UUID().uuidString.lowercased(),
            issue: try makeIssue(number: issueNumber),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let run) = inserted else {
            throw NSError(domain: "SeedRun", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected run creation"])
        }
        if let claimOwnerPID { _ = try ledger.claimHost(runID: run.id, ownerPID: claimOwnerPID) }
        for state in [RunState.claimed, .preparing, .running, .validating, .publishing] {
            _ = try ledger.transition(runID: run.id, to: state)
        }
        return run.id
    }

    func testCIObservationRecordsStatusAndNeverFailsOpenedDraftPullRequest() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        try Data("ci\n".utf8).write(to: prepared.workspace.appendingPathComponent("ci.txt"))
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: "ci-observe")
        try artifacts.archive(inspection)
        let validator = BuiltinPublisher(
            stateRoot: fixture.stateRoot,
            environment: try ciGHEnvironment(root: fixture.root, origin: origin.origin, checksStdout: "[]", checksStderr: "", checksExit: 0)
        )
        let receipt = try validator.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)
        let request = PublicationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            issueTitle: "CI recording",
            configRevision: config.revision,
            validationProfile: "default",
            defaultBranch: "main",
            branchName: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA,
            diffDigest: inspection.digest,
            git: prepared.git
        )

        let scenarios: [(stdout: String, stderr: String, exit: Int32, expected: String)] = [
            (#"[{"state":"FAILURE"},{"state":"SUCCESS"}]"#, "", 1, "failing"),
            ("[]", "", 1, "none"),
            ("", "no checks reported on the 'topic' branch", 1, "none"),
            (#"[{"state":"IN_PROGRESS"},{"state":"SUCCESS"}]"#, "", 8, "pending"),
            (#"[{"state":"SUCCESS"},{"state":"NEUTRAL"}]"#, "", 0, "passing"),
            ("", "gh: could not authenticate to github.com", 4, "unknown"),
        ]
        for scenario in scenarios {
            let publisher = BuiltinPublisher(
                stateRoot: fixture.stateRoot,
                environment: try ciGHEnvironment(
                    root: fixture.root,
                    origin: origin.origin,
                    checksStdout: scenario.stdout,
                    checksStderr: scenario.stderr,
                    checksExit: scenario.exit
                )
            )
            let status = try publisher.reconcile(PublicationIntent(request: request, validationReceipt: receipt))
            guard case .opened(let publication) = status else {
                return XCTFail("CI scenario \(scenario.expected) must still open the draft PR")
            }
            XCTAssertEqual(publication.ciStatus, scenario.expected, "unexpected ci_status for scenario \(scenario.expected)")
            XCTAssertTrue(publication.isDraft)
        }
    }

    func testDiffInspectorFailsClosedWhenGitOutputIsTruncated() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let config = try fixture.snapshot()
        let git = GitSupervisor(
            workspace: fixture.root.appendingPathComponent("phantom-workspace", isDirectory: true),
            branch: "mai/topic",
            defaultBranch: "main",
            processes: TruncatingGitExecutor(branch: "mai/topic"),
            environment: [:]
        )
        XCTAssertThrowsError(try DiffInspector(limits: config.worker.limits).inspect(git: git, baseSHA: "base")) { error in
            guard case DiffInspectionError.git = error else { return XCTFail("expected fail-closed git error, got \(error)") }
        }
    }

    private func ciGHEnvironment(
        root: URL,
        origin: URL,
        checksStdout: String,
        checksStderr: String,
        checksExit: Int32
    ) throws -> [String: String] {
        let gh = root.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        set -eu
        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          shift 2
          head=''
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--head" ]; then head="$2"; shift 2; else shift; fi
          done
          sha=$(/usr/bin/git --git-dir "$ORIGIN" rev-parse "refs/heads/$head")
          printf '[{"number":31,"url":"https://github.com/acme/widgets/pull/31","isDraft":true,"headRefOid":"%s"}]\n' "$sha"
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
          printf '%s' "$CHECKS_STDOUT"
          printf '%s' "$CHECKS_STDERR" >&2
          exit "$CHECKS_EXIT"
        fi
        exit 64
        """#
        try Data(script.utf8).write(to: gh)
        chmod(gh.path, 0o700)
        return [
            "PATH": "\(root.path):/usr/bin:/bin",
            "ORIGIN": origin.path,
            "CHECKS_STDOUT": checksStdout,
            "CHECKS_STDERR": checksStderr,
            "CHECKS_EXIT": String(checksExit),
        ]
    }

    private func withPreparedWorkspace(
        transform: (String) -> String = { $0 },
        gitTimeoutSeconds: Int = 120,
        body: (URL, WorkerConfigSnapshot, String, GitSupervisor) throws -> Void
    ) throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin", transform: transform)
        let origin = try makeBareOrigin(root: fixture.root, timeoutSeconds: gitTimeoutSeconds)
        let config = try fixture.snapshot()
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin.origin)
        try body(prepared.workspace, config, prepared.baseSHA, prepared.git)
    }

    private func prepareWorkspace(
        fixture: ConfigFixture,
        config: WorkerConfigSnapshot,
        origin: URL
    ) throws -> (workspace: URL, lease: WorkspaceLease, baseSHA: String, branch: String, git: GitSupervisor) {
        let store = try WorkerRepositoryStore(stateRoot: fixture.stateRoot).fetch(
            try XCTUnwrap(config.repository(slug: "acme/widgets")),
            remoteOverride: origin.path
        )
        let manager = BuiltinWorkspaceManager(stateRoot: fixture.stateRoot)
        let runID = UUID().uuidString.lowercased()
        let lease = try manager.acquire(repositoryStore: store, baseSHA: store.baseSHA, runID: runID)
        let branch = BranchPolicy.make(issueNumber: 42, title: "Safety test", runID: runID)
        _ = try manager.prepare(lease: lease, branchName: branch, baseSHA: store.baseSHA)
        return (
            lease.path,
            lease,
            store.baseSHA,
            branch,
            GitSupervisor(workspace: lease.path, branch: branch, defaultBranch: "main")
        )
    }

    /// Drives a run all the way to `publishing` with a real pushed remote branch — the exact
    /// push-before-record state startup reconciliation must re-drive — so a test only has to supply
    /// the gh behavior for the reconciliation pass.
    private func seedPushedPublishingRun(
        fixture: ConfigFixture,
        config: WorkerConfigSnapshot,
        origin: URL,
        ledger: RunLedger,
        marker: String,
        claimOwnerPID: Int32 = Int32.max
    ) throws -> (
        run: RunRecord,
        prepared: (workspace: URL, lease: WorkspaceLease, baseSHA: String, branch: String, git: GitSupervisor),
        receipt: ValidationReceipt
    ) {
        let prepared = try prepareWorkspace(fixture: fixture, config: config, origin: origin)
        let inserted = try ledger.createRun(NewRun(
            id: prepared.lease.id,
            issue: makeIssue(),
            configRevision: config.revision,
            redactedConfigSnapshot: config.redactedSnapshot,
            routeID: "bug",
            agentID: "bugfix",
            triggerKind: .cli
        ))
        guard case .created(let run) = inserted else {
            throw NSError(domain: "SeedRun", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected run creation"])
        }
        _ = try ledger.claimHost(runID: run.id, ownerPID: claimOwnerPID)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: run.id)
        try ledger.recordPreparation(
            runID: run.id,
            baseSHA: prepared.baseSHA,
            branchName: prepared.branch,
            workspace: prepared.lease,
            artifacts: artifacts
        )
        _ = try ledger.transition(runID: run.id, to: .running)
        try Data("\(marker)\n".utf8).write(to: prepared.workspace.appendingPathComponent("\(marker).txt"))
        try ledger.recordProviderExit(runID: run.id, pid: nil, exit: 0)
        _ = try ledger.transition(runID: run.id, to: .validating)
        let inspection = try DiffInspector(limits: config.worker.limits).inspect(git: prepared.git, baseSHA: prepared.baseSHA)
        try artifacts.archive(inspection)
        try ledger.recordInspection(runID: run.id, inspection: inspection)
        let publisher = BuiltinPublisher(stateRoot: fixture.stateRoot)
        let receipt = try publisher.validate(ValidationRequest(
            repository: "acme/widgets",
            issueNumber: 42,
            configRevision: config.revision,
            validationProfile: "default",
            baseSHA: prepared.baseSHA,
            inspection: inspection,
            git: prepared.git,
            limits: config.worker.limits,
            artifactStore: artifacts,
            timeoutSeconds: 300
        ))
        try ledger.recordValidatedSHA(runID: run.id, sha: receipt.headSHA, receiptID: receipt.id)
        try ledger.recordPublicationIntent(
            runID: run.id,
            branch: prepared.branch,
            baseSHA: prepared.baseSHA,
            headSHA: receipt.headSHA
        )
        _ = try ledger.transition(runID: run.id, to: .publishing)
        _ = try prepared.git.pushFreshBranch(expectedSHA: receipt.headSHA)
        return (run, prepared, receipt)
    }

    /// A gh that fails every invocation, standing in for a transient outage or rate limit.
    private func transientGHEnvironment(root: URL, origin: URL) throws -> [String: String] {
        let gh = root.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        echo 'gh: API rate limit exceeded (HTTP 403)' >&2
        exit 1
        """#
        try Data(script.utf8).write(to: gh)
        chmod(gh.path, 0o700)
        return ["PATH": "\(root.path):/usr/bin:/bin", "ORIGIN": origin.path]
    }

    private func nonDraftGHEnvironment(root: URL, origin: URL) throws -> [String: String] {
        let gh = root.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        set -eu
        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          shift 2
          head=''
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--head" ]; then head="$2"; shift 2; else shift; fi
          done
          sha=$(/usr/bin/git --git-dir "$ORIGIN" rev-parse "refs/heads/$head")
          printf '[{"number":9,"url":"https://github.com/acme/widgets/pull/9","isDraft":false,"headRefOid":"%s"}]\n' "$sha"
          exit 0
        fi
        exit 64
        """#
        try Data(script.utf8).write(to: gh)
        chmod(gh.path, 0o700)
        return ["PATH": "\(root.path):/usr/bin:/bin", "ORIGIN": origin.path]
    }

    private func draftGHEnvironment(root: URL, origin: URL) throws -> [String: String] {
        let gh = root.appendingPathComponent("gh")
        let state = root.appendingPathComponent("pr-created")
        let count = root.appendingPathComponent("create-count")
        try Data("0\n".utf8).write(to: count)
        let script = #"""
        #!/bin/sh
        set -eu
        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          shift 2
          head=''
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--head" ]; then head="$2"; shift 2; else shift; fi
          done
          if [ -f "$PR_STATE" ]; then
            sha=$(/usr/bin/git --git-dir "$ORIGIN" rev-parse "refs/heads/$head")
            printf '[{"number":23,"url":"https://github.com/acme/widgets/pull/23","isDraft":true,"headRefOid":"%s"}]\n' "$sha"
          else
            echo '[]'
          fi
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
          value=$(cat "$CREATE_COUNT")
          value=$((value + 1))
          printf '%s\n' "$value" > "$CREATE_COUNT"
          : > "$PR_STATE"
          echo 'https://github.com/acme/widgets/pull/23'
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
          echo '[]'
          exit 0
        fi
        exit 64
        """#
        try Data(script.utf8).write(to: gh)
        chmod(gh.path, 0o700)
        return [
            "PATH": "\(root.path):/usr/bin:/bin",
            "ORIGIN": origin.path,
            "PR_STATE": state.path,
            "CREATE_COUNT": count.path,
        ]
    }
}

private struct TruncatingGitExecutor: ProcessExecuting {
    let branch: String

    func resolveExecutable(_ name: String, environment: [String: String]) -> String? { "/usr/bin/\(name)" }

    func execute(_ request: ProcessRequest) -> ProcessExecution {
        switch request.arguments.first {
        case "symbolic-ref":
            return ProcessExecution(exitCode: 0, stdout: Data("\(branch)\n".utf8), stderr: Data(), timedOut: false)
        case "diff":
            return ProcessExecution(
                exitCode: 0,
                stdout: Data("a\u{0}b\u{0}".utf8),
                stderr: Data(),
                timedOut: false,
                stdoutTruncated: true
            )
        default:
            return ProcessExecution(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false)
        }
    }
}

private final class RecordingExecutor: @unchecked Sendable, ProcessExecuting {
    struct Call {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private let workspacePath: String
    private var storage: [Call] = []

    init(workspacePath: String) { self.workspacePath = workspacePath }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func resolveExecutable(_ name: String, environment: [String: String]) -> String? { "/fixture/\(name)" }

    func execute(_ request: ProcessRequest) -> ProcessExecution {
        lock.lock()
        storage.append(Call(executable: request.executable, arguments: request.arguments, environment: request.environment))
        lock.unlock()
        let stdout: String
        let exit: Int32
        switch request.arguments.first {
        case "get": stdout = workspacePath + "\n"; exit = 0
        case "status": stdout = ""; exit = 0
        case "rev-parse": stdout = String(repeating: "a", count: 40) + "\n"; exit = 0
        case "symbolic-ref": stdout = ""; exit = 1
        case "checkout": stdout = ""; exit = 0
        default: stdout = ""; exit = 0
        }
        return ProcessExecution(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data(), timedOut: false)
    }
}
