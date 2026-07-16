import Darwin
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class WorkerArtifactSmokeTests: XCTestCase {
    func testBuiltWorkerDoctorAndRunStubWithFakeGh() throws {
        let fixture = try ConfigFixture(publisherBackend: "builtin", workspaceBackend: "builtin")
        let fakeGH = fixture.root.appendingPathComponent("gh")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          echo authenticated
          exit 0
        fi
        if [ "$1" = "issue" ]; then
          echo '{"labels":[{"name":"agent:run"},{"name":"bug"}]}'
          exit 0
        fi
        if [ "$1" = "api" ]; then
          echo '{"default_branch":"main","permissions":{"admin":false,"maintain":false,"push":true}}'
          exit 0
        fi
        exit 64
        """
        try Data(script.utf8).write(to: fakeGH)
        chmod(fakeGH.path, 0o700)

        let worker = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("make-an-issue-worker")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: worker.path), "worker artifact must be built beside the test bundle")
        let environment = ["PATH": "\(fixture.root.path):/usr/bin:/bin:/usr/sbin:/sbin"]

        let doctor = try run(worker, ["--config", fixture.configURL.path, "doctor"], environment: environment)
        XCTAssertEqual(doctor.status, 0, doctor.stderr)
        XCTAssertTrue(doctor.stdout.contains("publisher backend: builtin selected"))

        let first = try run(
            worker,
            ["run", "--config", fixture.configURL.path, "--issue", "https://github.com/acme/widgets/issues/42"],
            environment: environment
        )
        XCTAssertEqual(first.status, StubRunOutcome.exitCode, first.stderr)
        XCTAssertTrue(first.stdout.contains("reached preparing"))
        XCTAssertTrue(first.stdout.contains(StubRunOutcome.failureCode))

        let second = try run(
            worker,
            ["--config", fixture.configURL.path, "run", "--issue", "https://github.com/acme/widgets/issues/42"],
            environment: environment
        )
        XCTAssertEqual(second.status, StubRunOutcome.exitCode, second.stderr)

        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let runs = try ledger.runs(repository: "acme/widgets", issueNumber: 42)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.failureCode), [StubRunOutcome.failureCode, StubRunOutcome.failureCode])
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
