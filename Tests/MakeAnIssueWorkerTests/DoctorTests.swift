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
}
