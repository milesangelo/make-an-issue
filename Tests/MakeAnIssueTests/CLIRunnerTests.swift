import XCTest
import Darwin
@testable import MakeAnIssue

/// Functional tests for CLIRunner using real system binaries (/bin/echo, /bin/sh).
/// No mock, no ASR binary required.
final class CLIRunnerTests: XCTestCase {

    // MARK: - Stdout capture

    func testStdoutCapture() async throws {
        let result = await CLIRunner().run(command: "echo hello")

        guard case .success(let stdout, _, _) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    // MARK: - Stderr / stdout separation (D-08)

    func testStderrSeparateFromStdout() async throws {
        // printf to stderr; nothing to stdout
        let result = await CLIRunner().run(command: "printf 'err\\n' 1>&2")

        guard case .success(let stdout, let stderr, _) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertTrue(stderr.contains("err"), "stderr should contain 'err', got: \(stderr.debugDescription)")
        XCTAssertTrue(stdout.isEmpty, "stdout should be empty, got: \(stdout.debugDescription)")
    }

    // MARK: - Exit code capture

    func testExitCodeCaptured() async throws {
        let result = await CLIRunner().run(command: "exit 1")

        guard case .failed(let exitCode, _) = result else {
            XCTFail("Expected failed, got \(result)")
            return
        }
        XCTAssertEqual(exitCode, 1)
    }

    // MARK: - Timeout terminates process and resolves exactly once

    func testTimeoutTerminatesAndResolvesOnce() async throws {
        let start = Date()
        let result = await CLIRunner().run(
            command: "sleep 5",
            timeout: .milliseconds(200)
        )
        let elapsed = Date().timeIntervalSince(start)

        if case .timeout = result {
            // Expected path
        } else {
            XCTFail("Expected .timeout, got \(result)")
        }
        // Must not block for the full 5s of the sleep command.
        XCTAssertLessThan(elapsed, 4.0, "Timeout should resolve well before 5s; elapsed: \(elapsed)s")
    }

    // MARK: - Single-resume holds under the timeout/exit race (CR-01 regression)

    func testTimeoutAndExitBoundaryResolvesExactlyOnce() async throws {
        // Stress the boundary where the natural-exit terminationHandler and the
        // timeout Task can fire near-simultaneously: a command whose sleep is the
        // same order as the timeout, run many times. A double-resume would trap
        // with SWIFT TASK CONTINUATION MISUSE and crash this test process, so
        // simply reaching the end of the loop proves the single-resume guard held.
        for _ in 0..<40 {
            let result = await CLIRunner().run(
                command: "sleep 0.05",
                timeout: .milliseconds(50)
            )
            // Any single resolution is acceptable at this boundary; the contract
            // under test is "resolved exactly once without crashing", not which arm.
            switch result {
            case .success, .failed, .timeout:
                break
            }
        }
    }

    // MARK: - Environment passthrough

    func testEnvironmentVariablePassedToSubprocess() async throws {
        // The injected env var must be visible to the subprocess via the inherited env.
        let result = await CLIRunner().run(
            command: "printf '%s' \"$MAI_TEST_TOKEN\"",
            environment: ["MAI_TEST_TOKEN": "sentinel-123"]
        )

        guard case .success(let stdout, _, _) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertEqual(stdout, "sentinel-123", "Injected env var must be visible to subprocess")
    }

    func testEnvironmentMergesOverInheritedEnv() async throws {
        // Custom env key is set alongside inherited keys (e.g. PATH must still resolve).
        // Confirm success (which requires PATH to work for echo) and that the custom var is set.
        let result = await CLIRunner().run(
            command: "echo ok && printf '%s' \"$MAI_MERGE_TEST\"",
            environment: ["MAI_MERGE_TEST": "merge-value"]
        )

        guard case .success(let stdout, _, _) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertTrue(stdout.contains("ok"), "Inherited env (PATH) must still resolve in merged env")
        XCTAssertTrue(stdout.contains("merge-value"), "Custom env var must appear in merged env")
    }

    // MARK: - Process-group gate (A1/A2 empirical validation — Phase 6 foundation)

    func testSpawnedChildIsProcessGroupLeader() async throws {
        // Gate: validates Assumptions A1/A2 from Phase-6 RESEARCH.md before any
        // kill(-pgid, …) code is written. If either assertion fails, the negated-PID
        // group-kill approach assumed by 06-02/03/04 is UNSAFE — halt Phase 6 and replan.

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sleep 30"]

        // Suppress output — we only care about process identity.
        process.standardOutput = Pipe()
        process.standardError  = Pipe()

        try process.run()
        let pid = process.processIdentifier

        // Always force-reap so the 30-second sleep never lingers, even on assertion failure.
        defer { kill(-pid, SIGKILL) }

        let childGroup = getpgid(pid)

        // A1: The spawned child is its own process-group leader (getpgid(child) == child).
        XCTAssertEqual(
            childGroup, pid,
            "A1 FAILED: getpgid(child) \(childGroup) ≠ child pid \(pid). " +
            "Foundation.Process no longer places children in their own group — " +
            "kill(-pgid, …) is UNSAFE. Halt Phase 6 and replan."
        )

        // A2: The child's process group is distinct from the test process's group
        //     (kill(-pgid, …) will NOT signal the app/test harness).
        XCTAssertNotEqual(
            childGroup, getpgrp(),
            "A2 FAILED: child's process group (\(childGroup)) equals the test process " +
            "group (\(getpgrp())). kill(-pgid, …) would signal the test harness — UNSAFE. " +
            "Halt Phase 6 and replan."
        )
    }

    func testNegativePIDSignalReapsProcessGroup() async throws {
        // Validates that kill(-pid, SIGTERM) reaps the spawned process group.
        // If this test fails, the group-directed signal does not work as expected
        // on this system and the kill(-pgid, …) mechanism is invalid.

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sleep 30"]

        process.standardOutput = Pipe()
        process.standardError  = Pipe()

        try process.run()
        let pid = process.processIdentifier

        // Safety net: force-kill the group on any exit path so the sleep never lingers.
        defer { kill(-pid, SIGKILL) }

        // Send a group-directed terminate signal.
        kill(-pid, SIGTERM)

        // Poll until the group leader is gone (ESRCH), with a generous bound for CI load.
        let deadline = ContinuousClock.now + .seconds(3)
        var reaped = false
        while ContinuousClock.now < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH {
                reaped = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            reaped,
            "kill(-pid, SIGTERM) did not reap the process group within 3s. " +
            "The group-directed signal mechanism may not work as expected on this system."
        )
    }

    // MARK: - Cancel scaffolds (fleshed out in 06-02)

    func testCancelKillsProcessGroup() async throws {
        // 06-02 will assert: cancelling the enclosing Task reaps the subprocess process
        // group within the SIGTERM grace window (2s), with SIGKILL as fallback escalation.
        throw XCTSkip("Pending — fleshed out in 06-02")
    }

    func testCancelAndExitBoundaryResolvesExactlyOnce() async throws {
        // 06-02 will assert: the cancel-vs-exit race resolves the CLIRunner continuation
        // exactly once — no double-resume SWIFT TASK CONTINUATION MISUSE trap.
        throw XCTSkip("Pending — fleshed out in 06-02")
    }

    // MARK: - Working directory respected

    func testWorkingDirectoryRespected() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Normalise /var vs /private/var on macOS: standardizedFileURL resolves symlinks
        // at the URL level, but on macOS /var is a symlink to /private/var. The shell
        // reports the real path (/private/var/...). Use the path as the shell sees it by
        // calling realpath() which matches what `pwd` outputs inside the subprocess.
        var resolvedPath = tempDir.path
        if let real = realpath(tempDir.path, nil) {
            resolvedPath = String(cString: real)
            free(real)
        }
        let expectedPath = resolvedPath

        let result = await CLIRunner().run(command: "pwd", workingDirectory: tempDir)

        guard case .success(let stdout, _, _) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        let actualPath = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(actualPath, expectedPath)
    }
}
