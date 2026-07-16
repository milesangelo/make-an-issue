import Darwin
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class WorkerArtifactSmokeTests: XCTestCase {
    func testBuiltWorkerCompletesOfflinePipelineAndCreatesDraftPR() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root, timeoutSeconds: loadTolerantGitTimeoutSeconds)
        let provider = try writeProvider(in: fixture.root, contents: "printf 'implemented\\n' > feature.txt")
        let fake = try writeFakeGH(in: fixture.root, origin: origin.origin)
        let environment = fixtureEnvironment(
            fixture: fixture,
            origin: origin.origin,
            provider: provider,
            fake: fake
        )
        let worker = try workerArtifact()

        let doctor = try run(worker, ["--config", fixture.configURL.path, "doctor"], environment: environment)
        XCTAssertEqual(doctor.status, 0, doctor.stderr)
        XCTAssertTrue(doctor.stdout.contains("publisher backend: builtin selected"))

        let result = try run(
            worker,
            ["run", "--config", fixture.configURL.path, "--issue", "https://github.com/acme/widgets/issues/42"],
            environment: environment
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("draft PR #17 opened"))

        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let run = try XCTUnwrap(ledger.runs(repository: "acme/widgets", issueNumber: 42).first)
        XCTAssertEqual(run.state, .prOpened)
        XCTAssertEqual(run.baseSHA, origin.mainSHA)
        XCTAssertEqual(run.remoteBranchSHA, run.validatedSHA)
        XCTAssertEqual(run.prNumber, 17)
        XCTAssertEqual(run.prIsDraft, true)
        XCTAssertNotNil(run.patchPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(run.patchPath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(run.workspacePath)))
        XCTAssertEqual(
            try ledger.events(runID: run.id).compactMap(\.toState),
            [.queued, .claimed, .preparing, .running, .validating, .publishing, .prOpened]
        )
        XCTAssertTrue(try ledger.events(runID: run.id).contains { $0.kind == "ci_status_recorded" })

        let mainAfter = try runProcess(
            "/usr/bin/git",
            ["--git-dir", origin.origin.path, "rev-parse", "refs/heads/main"],
            timeoutSeconds: loadTolerantGitTimeoutSeconds
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mainAfter, origin.mainSHA, "default branch must remain immutable")
        let branch = try XCTUnwrap(run.branchName)
        let remoteHead = try runProcess(
            "/usr/bin/git",
            ["--git-dir", origin.origin.path, "rev-parse", "refs/heads/\(branch)"],
            timeoutSeconds: loadTolerantGitTimeoutSeconds
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, run.validatedSHA)

        let ghLog = try String(contentsOf: fake.log, encoding: .utf8)
        XCTAssertTrue(ghLog.contains("pr create"))
        XCTAssertTrue(ghLog.contains("--draft"))
        XCTAssertTrue(ghLog.contains("Closes #42"))

        if let evidenceDir = ProcessInfo.processInfo.environment["MAI_EVIDENCE_DIR"] {
            let transitions = try ledger.events(runID: run.id).compactMap(\.toState)
            let transcript = """
            $ make-an-issue-worker --config agents.toml doctor
            \(doctor.stdout)
            $ make-an-issue-worker run --config agents.toml --issue https://github.com/acme/widgets/issues/42
            \(result.stdout)
            --- ledger state ---
            run.state          = \(run.state)
            run.prNumber       = \(run.prNumber.map(String.init) ?? "nil")
            run.prIsDraft      = \(run.prIsDraft.map(String.init) ?? "nil")
            run.branchName     = \(run.branchName ?? "nil")
            state transitions  = \(transitions)
            default branch SHA before/after = \(origin.mainSHA) / \(mainAfter) (immutable)
            --- gh invocation log (offline fake) ---
            \(ghLog)
            """
            try? Data(transcript.utf8).write(
                to: URL(fileURLWithPath: evidenceDir).appendingPathComponent("worker-offline-pipeline-transcript.txt")
            )
        }
    }

    func testValidationFailureRetainsDirtyWorkspaceAndPublishesNothing() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let origin = try makeBareOrigin(root: fixture.root)
        let provider = try writeProvider(in: fixture.root, contents: "printf 'trailing whitespace  \\n' > bad.txt")
        let fake = try writeFakeGH(in: fixture.root, origin: origin.origin)
        let environment = fixtureEnvironment(
            fixture: fixture,
            origin: origin.origin,
            provider: provider,
            fake: fake
        )

        let result = try run(
            try workerArtifact(),
            ["--config", fixture.configURL.path, "run", "--issue", "https://github.com/acme/widgets/issues/42"],
            environment: environment
        )

        XCTAssertEqual(result.status, 1)
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let run = try XCTUnwrap(ledger.runs(repository: "acme/widgets", issueNumber: 42).first)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.failureCode, "validation_failed_retained")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(run.workspacePath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(run.patchPath)))
        XCTAssertTrue(try ledger.events(runID: run.id).contains {
            $0.kind == "workspace_disposition" && $0.detail?.contains("retained") == true
        })
        let refs = try runProcess(
            "/usr/bin/git",
            ["--git-dir", origin.origin.path, "for-each-ref", "--format=%(refname)", "refs/heads"]
        ).stdoutString
        XCTAssertEqual(refs.trimmingCharacters(in: .whitespacesAndNewlines), "refs/heads/main")
        let ghLog = try String(contentsOf: fake.log, encoding: .utf8)
        XCTAssertFalse(ghLog.contains("pr create"))
    }

    private func workerArtifact() throws -> URL {
        let worker = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("make-an-issue-worker")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: worker.path))
        return worker
    }

    private func writeProvider(in root: URL, contents: String) throws -> URL {
        let url = root.appendingPathComponent("fixture-provider")
        try Data("#!/bin/sh\nset -eu\n\(contents)\n".utf8).write(to: url)
        chmod(url.path, 0o700)
        return url
    }

    private func writeFakeGH(in root: URL, origin: URL) throws -> (url: URL, log: URL, state: URL) {
        let url = root.appendingPathComponent("gh")
        let log = root.appendingPathComponent("gh.log")
        let state = root.appendingPathComponent("gh-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        set -eu
        printf '%s\n' "$*" >> "$GH_LOG"
        if [ "$1" = "auth" ]; then
          echo authenticated
          exit 0
        fi
        if [ "$1" = "issue" ]; then
          echo '{"labels":[{"name":"agent:run"},{"name":"bug"}],"title":"Fix fixture behavior"}'
          exit 0
        fi
        if [ "$1" = "api" ]; then
          echo '{"default_branch":"main","permissions":{"admin":false,"maintain":false,"push":true}}'
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
          shift 2
          head=''
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--head" ]; then head="$2"; shift 2; else shift; fi
          done
          key=$(printf '%s' "$head" | tr '/' '_')
          : > "$GH_STATE/$key"
          echo 'https://github.com/acme/widgets/pull/17'
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          shift 2
          head=''
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--head" ]; then head="$2"; shift 2; else shift; fi
          done
          key=$(printf '%s' "$head" | tr '/' '_')
          if [ -f "$GH_STATE/$key" ]; then
            sha=$(/usr/bin/git --git-dir "$ORIGIN" rev-parse "refs/heads/$head")
            printf '[{"number":17,"url":"https://github.com/acme/widgets/pull/17","isDraft":true,"headRefOid":"%s"}]\n' "$sha"
          else
            echo '[]'
          fi
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
          echo '[]'
          exit 0
        fi
        exit 64
        """#
        try Data(script.utf8).write(to: url)
        chmod(url.path, 0o700)
        try Data().write(to: log)
        return (url, log, state)
    }

    private func fixtureEnvironment(
        fixture: ConfigFixture,
        origin: URL,
        provider: URL,
        fake: (url: URL, log: URL, state: URL)
    ) -> [String: String] {
        [
            "PATH": "\(fixture.root.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "MAKE_AN_ISSUE_WORKER_ALLOW_TEST_FIXTURES": "1",
            "MAKE_AN_ISSUE_WORKER_TEST_PROVIDER": provider.path,
            "MAKE_AN_ISSUE_WORKER_TEST_REMOTE": origin.path,
            "GH_LOG": fake.log.path,
            "GH_STATE": fake.state.path,
            "ORIGIN": origin.path,
        ]
    }

    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
