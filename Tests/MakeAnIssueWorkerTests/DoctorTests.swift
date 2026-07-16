import XCTest
@testable import MakeAnIssueWorkerCore

final class DoctorTests: XCTestCase {
    func testInvalidConfigIsTheOnlyBlockingCheck() throws {
        let fixture = try ConfigFixture { $0.replacingOccurrences(of: "schema_version = 1", with: "schema_version = 99") }

        let report = Doctor(
            commands: FakeCommandRunner(resolutions: [:], results: [:]),
            stateRoot: FakeStateRootProbe(result: .failure(DoctorProbeError("must not run")))
        ).run(configURL: fixture.configURL)

        XCTAssertTrue(report.hasBlockingIssues)
        XCTAssertNil(report.config)
        XCTAssertEqual(report.checks.count, 1)
        XCTAssertEqual(report.checks.first?.name, "config")
        XCTAssertTrue(report.checks.first?.detail.contains("schema_version") == true)
    }

    func testAutoPublisherFallsBackToBuiltinWhenNoMistakesCannotProveDraftCapability() throws {
        let fixture = try ConfigFixture(publisherBackend: "auto")
        let commands = passingCommands(capabilities: CommandResult(exitCode: 2, stderr: "unknown command"))

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL)

        XCTAssertFalse(report.hasBlockingIssues)
        let publisher = try XCTUnwrap(report.checks.first { $0.name == "publisher backend" })
        XCTAssertEqual(publisher.status, .warning)
        XCTAssertTrue(publisher.detail.contains("builtin selected under auto"))
        XCTAssertTrue(report.humanReadable().contains("treehouse v2.0.0"))
    }

    func testExplicitNoMistakesFailsClosedWithoutCapabilityProof() throws {
        let fixture = try ConfigFixture(publisherBackend: "no-mistakes")
        let commands = passingCommands(capabilities: CommandResult(exitCode: 2, stderr: "unknown command"))

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL)

        XCTAssertTrue(report.hasBlockingIssues)
        let publisher = try XCTUnwrap(report.checks.first { $0.name == "publisher backend" })
        XCTAssertEqual(publisher.status, .blocking)
        XCTAssertTrue(publisher.detail.contains("explicit no-mistakes selection fails closed"))
    }

    func testNoMistakesPassesOnlyWhenAllCapabilitiesAreProven() throws {
        let fixture = try ConfigFixture(publisherBackend: "no-mistakes")
        let json = """
        {
          "draft_pr": true,
          "pre_push_validation": true,
          "token_isolation": true,
          "no_force": true,
          "artifact_export": true,
          "startup_reconciliation": true
        }
        """
        let commands = passingCommands(capabilities: CommandResult(exitCode: 0, stdout: json))

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL)

        XCTAssertFalse(report.hasBlockingIssues)
        XCTAssertEqual(report.checks.first { $0.name == "publisher backend" }?.status, .pass)
    }

    func testProviderAuthFailureIsBlocking() throws {
        let fixture = try ConfigFixture()
        var results = baseResults(capabilities: CommandResult(exitCode: 2))
        results[FakeCommandRunner.key("/usr/bin/true", ["auth", "status"])] = CommandResult(
            exitCode: 1,
            stderr: "not authenticated"
        )
        let commands = FakeCommandRunner(
            resolutions: ["treehouse": "/fake/treehouse", "no-mistakes": "/fake/no-mistakes", "gh": "/fake/gh"],
            results: results
        )

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL)

        XCTAssertTrue(report.hasBlockingIssues)
        XCTAssertEqual(report.checks.first { $0.name == "provider claude-primary auth" }?.status, .blocking)
    }

    func testTimedOutProbeBecomesBlockingCheckWithBudget() throws {
        let fixture = try ConfigFixture()
        var results = baseResults(capabilities: CommandResult(exitCode: 2))
        results[FakeCommandRunner.key("/usr/bin/true", ["auth", "status"])] = CommandResult(
            exitCode: -SIGKILL,
            timedOut: true,
            timeoutSeconds: 1
        )
        let commands = FakeCommandRunner(
            resolutions: ["treehouse": "/fake/treehouse", "no-mistakes": "/fake/no-mistakes", "gh": "/fake/gh"],
            results: results
        )

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL)

        let auth = try XCTUnwrap(report.checks.first { $0.name == "provider claude-primary auth" })
        XCTAssertEqual(auth.status, .blocking)
        XCTAssertEqual(auth.detail, "timed out after 1s")
    }

    func testProcessCommandRunnerBoundsSleepingFixtureProbe() throws {
        let fixture = try ConfigFixture()
        let sleeper = try writeExecutable(in: fixture.root, name: "sleeping-probe", body: "/bin/sleep 60")
        let start = Date()
        let result = ProcessCommandRunner(probeTimeoutSeconds: 1).run(
            executable: sleeper.path,
            arguments: []
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.timeoutSeconds, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testProviderAuthProbeUsesRuntimeSandboxEnvironment() throws {
        let fixture = try ConfigFixture()
        let provider = try writeExecutable(
            in: fixture.root,
            name: "sandbox-auth-provider",
            body: """
            if [ "${1-}" = auth ] && [ "${2-}" = status ] \\
                && [ "${CLAUDE_CODE_OAUTH_TOKEN-}" = fixture-token ] \\
                && [ "${PATH}" = /usr/bin:/bin:/usr/sbin:/sbin ] \\
                && [ "${PWD}" = "${HOME%/provider-home}/workspace" ] \\
                && [ "${UNRELATED_SESSION_VALUE-unset}" = unset ]; then
              case "${HOME}" in
                */make-an-issue-doctor-*/provider-home) printf '{"loggedIn":true,"authMethod":"token"}\\n'; exit 0 ;;
              esac
            fi
            printf 'Not logged in under worker sandbox\\n' >&2
            exit 1
            """
        )
        try fixture.useProviderExecutable(provider)
        let commands = FixtureCommandRunner(
            fixtureExecutable: provider.path,
            fallback: passingCommands(capabilities: CommandResult(exitCode: 2)),
            environment: ["HOME": "/interactive-home", "UNRELATED_SESSION_VALUE": "present"]
        )

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path)),
            supervisorEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": "fixture-token", "UNRELATED_SESSION_VALUE": "present"]
        ).run(configURL: fixture.configURL)

        XCTAssertEqual(report.checks.first { $0.name == "provider claude-primary auth" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.name == "provider claude-primary auth" }?.detail, "authenticated via token")
    }

    func testChecksAreEmittedAsEachProbeCompletes() throws {
        let fixture = try ConfigFixture()
        let events = EventLog()
        let commands = RecordingCommandRunner(
            fallback: passingCommands(capabilities: CommandResult(exitCode: 2)),
            events: events
        )

        _ = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL) { check in
            events.values.append("check \(check.name)")
        }

        XCTAssertLessThan(
            try XCTUnwrap(events.values.firstIndex(of: "check provider claude-primary executable")),
            try XCTUnwrap(events.values.firstIndex(of: "run /usr/bin/true auth status"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(events.values.firstIndex(of: "run /usr/bin/true auth status")),
            try XCTUnwrap(events.values.firstIndex(of: "check provider claude-primary auth"))
        )
    }

    func testStateRootFailureIsBlocking() throws {
        let fixture = try ConfigFixture()
        let report = Doctor(
            commands: passingCommands(capabilities: CommandResult(exitCode: 2)),
            stateRoot: FakeStateRootProbe(result: .failure(DoctorProbeError("read only")))
        ).run(configURL: fixture.configURL)

        XCTAssertTrue(report.hasBlockingIssues)
        XCTAssertEqual(report.checks.first { $0.name == "state root" }?.detail, "read only")
    }

    func testProviderAuthDiscoveryRulesCoverCodexAndCodexOSS() throws {
        let fixture = try ConfigFixture { value in
            value
                .replacingOccurrences(
                    of: "[[agents]]",
                    with: """
                    [[providers]]
                    id = "codex-secondary"
                    kind = "codex"
                    executable = "/usr/bin/true"
                    argv = []
                    timeout_seconds = 2700

                    [[providers]]
                    id = "local-codex-oss"
                    kind = "codex-oss"
                    executable = "/usr/bin/true"
                    argv = []
                    timeout_seconds = 2700

                    [[agents]]
                    """,
                    options: [],
                    range: value.range(of: "[[agents]]")
                )
        }
        var results = baseResults(capabilities: CommandResult(exitCode: 2))
        results[FakeCommandRunner.key("/usr/bin/true", ["login", "status"])] = CommandResult(exitCode: 0, stdout: "logged in")
        let commands = FakeCommandRunner(
            resolutions: ["treehouse": "/fake/treehouse", "no-mistakes": "/fake/no-mistakes", "gh": "/fake/gh"],
            results: results
        )

        let report = Doctor(
            commands: commands,
            stateRoot: FakeStateRootProbe(result: .success(fixture.stateRoot.path))
        ).run(configURL: fixture.configURL)

        XCTAssertFalse(report.hasBlockingIssues)
        XCTAssertEqual(report.checks.first { $0.name == "provider codex-secondary auth" }?.status, .pass)
        XCTAssertTrue(report.checks.first { $0.name == "provider local-codex-oss auth" }?.detail.contains("not required") == true)
    }

    private func passingCommands(capabilities: CommandResult) -> FakeCommandRunner {
        FakeCommandRunner(
            resolutions: ["treehouse": "/fake/treehouse", "no-mistakes": "/fake/no-mistakes", "gh": "/fake/gh"],
            results: baseResults(capabilities: capabilities)
        )
    }

    private func baseResults(capabilities: CommandResult) -> [String: CommandResult] {
        [
            FakeCommandRunner.key("/usr/bin/true", ["auth", "status"]): CommandResult(exitCode: 0, stdout: "authenticated"),
            FakeCommandRunner.key("/usr/bin/true", ["login", "status"]): CommandResult(exitCode: 0, stdout: "logged in"),
            FakeCommandRunner.key("/fake/treehouse", ["--version"]): CommandResult(exitCode: 0, stdout: "treehouse v2.0.0"),
            FakeCommandRunner.key("/fake/no-mistakes", ["--version"]): CommandResult(exitCode: 0, stdout: "v1.34.0"),
            FakeCommandRunner.key("/fake/no-mistakes", ["publisher-capabilities", "--json"]): capabilities,
            FakeCommandRunner.key("/fake/gh", ["auth", "status"]): CommandResult(exitCode: 0, stdout: "authenticated"),
        ]
    }

    private func writeExecutable(in directory: URL, name: String, body: String) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
        chmod(executable.path, 0o700)
        return executable
    }
}

private final class FixtureCommandRunner: @unchecked Sendable, CommandRunning {
    private let fixtureExecutable: String
    private let fallback: FakeCommandRunner
    private let runner: ProcessCommandRunner

    init(fixtureExecutable: String, fallback: FakeCommandRunner, environment: [String: String]) {
        self.fixtureExecutable = fixtureExecutable
        self.fallback = fallback
        self.runner = ProcessCommandRunner(environment: environment)
    }

    func resolveExecutable(_ name: String) -> String? { fallback.resolveExecutable(name) }

    func run(executable: String, arguments: [String]) -> CommandResult {
        executable == fixtureExecutable
            ? runner.run(executable: executable, arguments: arguments)
            : fallback.run(executable: executable, arguments: arguments)
    }

    func run(executable: String, arguments: [String], environment: [String: String]) -> CommandResult {
        executable == fixtureExecutable
            ? runner.run(executable: executable, arguments: arguments, environment: environment)
            : fallback.run(executable: executable, arguments: arguments, environment: environment)
    }

    func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL?) -> CommandResult {
        executable == fixtureExecutable
            ? runner.run(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
            : fallback.run(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
    }
}

private final class EventLog {
    var values = [String]()
}

private final class RecordingCommandRunner: @unchecked Sendable, CommandRunning {
    private let fallback: FakeCommandRunner
    private let events: EventLog

    init(fallback: FakeCommandRunner, events: EventLog = EventLog()) {
        self.fallback = fallback
        self.events = events
    }

    func resolveExecutable(_ name: String) -> String? { fallback.resolveExecutable(name) }

    func run(executable: String, arguments: [String]) -> CommandResult {
        events.values.append("run \(([executable] + arguments).joined(separator: " "))")
        return fallback.run(executable: executable, arguments: arguments)
    }
}
