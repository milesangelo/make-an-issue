import XCTest
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
