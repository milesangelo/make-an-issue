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
