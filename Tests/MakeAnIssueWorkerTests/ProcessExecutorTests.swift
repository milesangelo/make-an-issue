import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class ProcessExecutorTests: XCTestCase {
    func testOutputIsBoundedToCapAndFlaggedTruncated() throws {
        let cap = 4096
        let execution = FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/bin/sh",
            arguments: ["-c", "exec /bin/dd if=/dev/zero bs=1024 count=1024 2>/dev/null | /usr/bin/tr '\\0' 'x'"],
            timeoutSeconds: 60,
            maximumOutputBytes: cap
        ))
        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertFalse(execution.timedOut)
        XCTAssertEqual(execution.stdout.count, cap, "stdout must be truncated to the byte cap")
        XCTAssertTrue(execution.stdoutTruncated, "oversized output must set the truncation flag")
    }

    func testExactCapOutputIsNotFlaggedTruncated() throws {
        let cap = 2048
        let execution = FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/usr/bin/head",
            arguments: ["-c", String(cap), "/dev/zero"],
            timeoutSeconds: 60,
            maximumOutputBytes: cap
        ))
        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertEqual(execution.stdout.count, cap)
        XCTAssertFalse(execution.stdoutTruncated, "output exactly at the cap must not be reported as truncated")
    }

    func testTimeoutKillsChildPromptlyAndReportsTimedOut() throws {
        let start = Date()
        let execution = FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/bin/sleep",
            arguments: ["120"],
            timeoutSeconds: 1,
            terminationGraceSeconds: 1
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(execution.timedOut, "an over-running child must be reported as timed out")
        XCTAssertEqual(execution.exitCode, -SIGKILL)
        XCTAssertLessThan(elapsed, 20, "timeout must terminate the child and return without hanging on pipe drain")
    }

    func testDrainDoesNotDeadlockWhenDescendantHoldsPipeAfterChildExit() throws {
        // The direct child exits promptly (exit 0) but leaves a backgrounded descendant holding the
        // stdout write-end open. Without a bounded drain, outputGroup.wait() would block until the
        // descendant exits. The bounded drain must return near the grace window while still
        // capturing the output produced before the child exited.
        let start = Date()
        let execution = FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/bin/sh",
            arguments: ["-c", "echo parent-output; /bin/sleep 30 & exit 0"],
            timeoutSeconds: 30,
            terminationGraceSeconds: 1
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 20, "an escaped descendant holding the pipe must not deadlock the drain after child exit")
        XCTAssertFalse(execution.timedOut, "a promptly-exiting child must not be reported as timed out")
        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertTrue(execution.stdoutString.contains("parent-output"), "output produced before exit must still be captured")
    }

    func testTimeoutTerminatesChildAndDescendants() throws {
        let start = Date()
        let execution = FoundationProcessExecutor().execute(ProcessRequest(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 120"],
            timeoutSeconds: 1,
            terminationGraceSeconds: 1
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(execution.timedOut)
        XCTAssertLessThan(elapsed, 20, "a descendant holding the output pipe must not stall the drain past the kill")
    }
}
