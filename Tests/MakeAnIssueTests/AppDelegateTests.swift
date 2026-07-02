import XCTest
@testable import MakeAnIssue

@MainActor
final class AppDelegateTests: XCTestCase {
    private var controlledDir: URL!

    override func setUpWithError() throws {
        controlledDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: controlledDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: controlledDir)
    }

    // MARK: - Sweep isolation tests (CANCEL-03 / T-6-06)

    func testSweepRemovesOnlyMCPTempFiles() throws {
        // Two matching files — both should be deleted.
        let match1 = controlledDir.appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
        let match2 = controlledDir.appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
        // Wrong suffix — no .json — must survive.
        let wrongSuffix = controlledDir.appendingPathComponent("make-an-issue-mcp-keep")
        // Wrong prefix — must survive even though it ends in .json.
        let wrongPrefix = controlledDir.appendingPathComponent("unrelated-\(UUID().uuidString).json")

        for url in [match1, match2, wrongSuffix, wrongPrefix] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }

        AppDelegate.sweepMCPTempFiles(in: controlledDir)

        // Matching files must be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: match1.path), "match1 should be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: match2.path), "match2 should be deleted")
        // Non-matching files must remain.
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrongSuffix.path), "wrongSuffix should survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrongPrefix.path), "wrongPrefix should survive")
    }

    // MARK: - Fast-path terminateNow test (CANCEL-03)

    func testTerminateNowWhenNoFilingJobs() {
        let delegate = AppDelegate()
        // A freshly constructed AppState has an empty jobs array — no .filing job.
        XCTAssertTrue(delegate.appState.jobs.isEmpty, "fresh AppState should have no jobs")

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow, "no filing jobs → fast path must return .terminateNow")
    }

    // MARK: - Slow-path synchronous sweep regression (CANCEL-03 / SC-3, UAT phase 6 test 2)

    /// Quit-mid-flight must sweep the MCP temp file synchronously — not solely inside the
    /// post-grace async Task, which can be reaped before it runs on MenuBarExtra ⌘Q quit.
    func testTerminateLaterSweepsMCPTempFileSynchronously() {
        let delegate = AppDelegate()
        // Drive the slow path: one job in .filing state.
        let binding = RepoBinding(
            rootURL: URL(fileURLWithPath: "/tmp/test-repo"),
            displayName: "test-repo",
            displayPath: "/tmp/test-repo"
        )
        delegate.appState.jobs = [
            FilingJob(id: UUID(), transcript: "x", repo: binding, state: .filing)
        ]

        // A matching temp file in the REAL temp dir the sweep targets.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("make-an-issue-mcp-\(UUID().uuidString).json")
        try? "x".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path), "precondition: temp file exists")

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        // Slow path taken, and the file is gone immediately on return — before the 2s async
        // Task could possibly have run. A leftover here is the SC-3 orphan regression.
        XCTAssertEqual(reply, .terminateLater, "a .filing job → slow path must return .terminateLater")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempFile.path),
            "MCP temp file must be swept synchronously on quit, not only by the post-grace Task"
        )
    }
}
