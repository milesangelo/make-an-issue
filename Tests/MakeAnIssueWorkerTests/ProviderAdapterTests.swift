import Darwin
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class ProviderAdapterTests: XCTestCase {
    func testClaudeAdapterUsesTypedArgumentsPromptAndSanitizedEnvironment() throws {
        let fixture = try ConfigFixture()
        let argumentsFile = fixture.root.appendingPathComponent("arguments.txt")
        let promptFile = fixture.root.appendingPathComponent("prompt.txt")
        let environmentFile = fixture.root.appendingPathComponent("environment.txt")
        let cwdFile = fixture.root.appendingPathComponent("cwd.txt")
        let provider = try writeProvider(
            fixture: fixture,
            body: """
            printf '%s\n' "$@" > '\(argumentsFile.path)'
            /bin/cat > '\(promptFile.path)'
            /usr/bin/env | /usr/bin/sort > '\(environmentFile.path)'
            /bin/pwd > '\(cwdFile.path)'
            printf 'provider completed\n'
            printf 'edited\n' > changed.txt
            """
        )
        let setup = try makeRequest(
            fixture: fixture,
            provider: provider,
            environment: [
                "PATH": "/secret/provider/bin",
                "HOME": "/Users/real-home",
                "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz123456",
                "GH_TOKEN": "gho_abcdefghijklmnopqrstuvwxyz123456",
                "GH_CONFIG_DIR": "/Users/real-home/.config/gh",
                "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
                "WORKER_TOKEN": "ghu_abcdefghijklmnopqrstuvwxyz123456",
                "ANTHROPIC_API_KEY": "sk-ant-abcdefghijklmnopqrstuvwxyz123456",
            ]
        )

        let outcome = try ClaudeCodeProviderAdapter().execute(setup.request)

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertGreaterThanOrEqual(outcome.durationMilliseconds, 0)
        XCTAssertLessThanOrEqual(outcome.stdout.count, setup.request.maximumOutputBytes)
        XCTAssertEqual(try String(contentsOf: setup.workspace.appendingPathComponent("changed.txt"), encoding: .utf8), "edited\n")

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        XCTAssertTrue(arguments.contains("--model\nsonnet"), arguments)
        XCTAssertTrue(arguments.contains("--permission-mode\nacceptEdits"), arguments)
        XCTAssertTrue(arguments.contains("--allowedTools\nRead\nGrep\nGlob\nEdit\nWrite"), arguments)
        XCTAssertTrue(arguments.contains("--output-format\nstream-json\n--verbose"), arguments)
        XCTAssertFalse(arguments.contains("dangerously"), arguments)

        let prompt = try String(contentsOf: promptFile, encoding: .utf8)
        XCTAssertTrue(prompt.contains("Fix only the requested issue."), prompt)
        XCTAssertTrue(prompt.contains("A quoted issue title"), prompt)
        XCTAssertTrue(prompt.contains("body with \\\"quotes\\\""), prompt)
        XCTAssertTrue(prompt.contains("agent:run"), prompt)
        XCTAssertTrue(prompt.contains("untrusted issue data"), prompt)

        let childEnvironment = try String(contentsOf: environmentFile, encoding: .utf8)
        XCTAssertTrue(childEnvironment.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), childEnvironment)
        XCTAssertTrue(childEnvironment.contains("HOME=\(fixture.stateRoot.path)/provider-home/adapter-run"), childEnvironment)
        XCTAssertTrue(childEnvironment.contains("TMPDIR=\(fixture.stateRoot.path)/provider-tmp/adapter-run"), childEnvironment)
        XCTAssertTrue(childEnvironment.contains("PWD=\(setup.workspace.path)"), childEnvironment)
        XCTAssertTrue(childEnvironment.contains("ANTHROPIC_API_KEY=sk-ant-abcdefghijklmnopqrstuvwxyz123456"), childEnvironment)
        XCTAssertFalse(childEnvironment.contains("GITHUB_TOKEN"), childEnvironment)
        XCTAssertFalse(childEnvironment.contains("GH_TOKEN"), childEnvironment)
        XCTAssertFalse(childEnvironment.contains("GH_CONFIG_DIR"), childEnvironment)
        XCTAssertFalse(childEnvironment.contains("SSH_AUTH_SOCK"), childEnvironment)
        XCTAssertFalse(childEnvironment.contains("WORKER_TOKEN"), childEnvironment)
        XCTAssertEqual(
            try String(contentsOf: cwdFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            setup.workspace.path
        )
    }

    func testClaudeAdapterReportsNonzeroExitAndRedactsPersistedOutput() throws {
        let fixture = try ConfigFixture()
        let githubToken = "ghp_abcdefghijklmnopqrstuvwxyz123456"
        let anthropicToken = "sk-ant-abcdefghijklmnopqrstuvwxyz123456"
        let provider = try writeProvider(
            fixture: fixture,
            body: """
            echo 'stdout \(githubToken)'
            echo 'ANTHROPIC_API_KEY=\(anthropicToken)' >&2
            exit 42
            """
        )
        let setup = try makeRequest(fixture: fixture, provider: provider)

        let outcome = try ClaudeCodeProviderAdapter().execute(setup.request)

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.exitCode, 42)
        XCTAssertTrue(outcome.stdoutString.contains(githubToken), "the adapter outcome remains an in-memory diagnostic")
        let persisted = try String(
            contentsOf: setup.artifacts.logDirectory.appendingPathComponent("provider.log"),
            encoding: .utf8
        )
        XCTAssertTrue(persisted.contains("[REDACTED]"), persisted)
        XCTAssertFalse(persisted.contains(githubToken), persisted)
        XCTAssertFalse(persisted.contains(anthropicToken), persisted)
        XCTAssertLessThanOrEqual(Data(persisted.utf8).count, setup.request.maximumOutputBytes)
    }

    func testClaudeAdapterTimesOutAndKillsProviderProcessGroup() throws {
        let fixture = try ConfigFixture()
        let childPIDFile = fixture.root.appendingPathComponent("timeout-child.pid")
        let provider = try writeProvider(
            fixture: fixture,
            body: """
            /bin/sleep 120 &
            child=$!
            echo "$child" > '\(childPIDFile.path)'
            wait "$child"
            """
        )
        let setup = try makeRequest(fixture: fixture, provider: provider, timeoutSeconds: 1)

        let outcome = try ClaudeCodeProviderAdapter().execute(setup.request)

        XCTAssertEqual(outcome.status, .timedOut)
        XCTAssertEqual(outcome.exitCode, -SIGKILL)
        XCTAssertLessThan(outcome.durationMilliseconds, 10_000)
        try assertProcessExited(pidFile: childPIDFile)
    }

    func testClaudeAdapterCancellationKillsProviderProcessGroup() throws {
        let fixture = try ConfigFixture()
        let childPIDFile = fixture.root.appendingPathComponent("cancel-child.pid")
        let provider = try writeProvider(
            fixture: fixture,
            body: """
            /bin/sleep 120 &
            child=$!
            echo "$child" > '\(childPIDFile.path)'
            wait "$child"
            """
        )
        let setup = try makeRequest(fixture: fixture, provider: provider, timeoutSeconds: 60)
        let cancellation = ProcessCancellation()
        let box = OutcomeBox()
        let finished = expectation(description: "provider cancelled")
        Thread.detachNewThread {
            box.result = Result {
                try ClaudeCodeProviderAdapter().execute(setup.request, cancellation: cancellation)
            }
            finished.fulfill()
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
            usleep(20_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPIDFile.path))

        cancellation.cancel()
        wait(for: [finished], timeout: 10)

        let outcome = try XCTUnwrap(box.result).get()
        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.exitCode, -SIGTERM)
        try assertProcessExited(pidFile: childPIDFile)
    }

    func testLedgerRecordsMachineReadableProviderOutcome() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let run = try created(ledger.createRun(makeNewRun(issue: makeIssue(), id: "provider-ledger")))
        _ = try ledger.claimHost(runID: run.id, ownerPID: 99)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        _ = try ledger.transition(runID: run.id, to: .running)
        let outcome = ProviderExecutionOutcome(
            status: .completed,
            exitCode: 0,
            durationMilliseconds: 123,
            stdout: Data("not persisted".utf8),
            stderr: Data(),
            stdoutTruncated: false,
            stderrTruncated: false
        )

        try ledger.recordProviderOutcome(runID: run.id, pid: nil, outcome: outcome)

        XCTAssertEqual(try ledger.run(id: run.id).providerExit, 0)
        let event = try XCTUnwrap(ledger.events(runID: run.id).first { $0.kind == "provider_outcome" })
        let metadata = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(event.detail).utf8)) as? [String: Any]
        XCTAssertEqual(metadata?["status"] as? String, "completed")
        XCTAssertEqual(metadata?["duration_ms"] as? Int, 123)
        XCTAssertNil(metadata?["stdout"])
    }

    private func makeRequest(
        fixture: ConfigFixture,
        provider: URL,
        environment: [String: String] = [:],
        timeoutSeconds: Int = 30
    ) throws -> (request: ProviderExecutionRequest, workspace: URL, artifacts: ArtifactStore) {
        try fixture.useProviderExecutable(provider)
        let config = try fixture.snapshot()
        let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let artifacts = try ArtifactStore(stateRoot: fixture.stateRoot, runID: "adapter-run")
        let request = ProviderExecutionRequest(
            provider: try XCTUnwrap(config.provider(id: "claude-primary")),
            agent: try XCTUnwrap(config.agent(id: "bugfix")),
            issueTitle: "A quoted issue title",
            issueBody: "body with \"quotes\"",
            issueLabels: ["agent:run", "bug"],
            workspace: workspace,
            stateRoot: fixture.stateRoot,
            runID: "adapter-run",
            runTimeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: 1,
            maximumOutputBytes: 4096,
            artifactStore: artifacts,
            supervisorEnvironment: environment
        )
        return (request, workspace, artifacts)
    }

    private func writeProvider(fixture: ConfigFixture, body: String) throws -> URL {
        let provider = fixture.root.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: provider)
        chmod(provider.path, 0o700)
        return provider
    }

    private func assertProcessExited(pidFile: URL) throws {
        let value = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(value))
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            usleep(20_000)
        }
        XCTFail("provider descendant \(pid) survived process-group teardown")
    }

    private func created(_ insertion: RunInsertion) throws -> RunRecord {
        guard case .created(let run) = insertion else {
            throw LedgerError.sqlite("test expected created")
        }
        return run
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<ProviderExecutionOutcome, Error>?

    var result: Result<ProviderExecutionOutcome, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
