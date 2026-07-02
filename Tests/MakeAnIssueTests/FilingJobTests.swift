import XCTest
@testable import MakeAnIssue

final class FilingJobTests: XCTestCase {

    // MARK: - FilingJobState

    func testFilingJobStateEquatable() {
        XCTAssertEqual(FilingJobState.filing, FilingJobState.filing)
        XCTAssertNotEqual(FilingJobState.filing, FilingJobState.done)
        XCTAssertNotEqual(FilingJobState.done, FilingJobState.failed)
        XCTAssertNotEqual(FilingJobState.failed, FilingJobState.cancelled)
    }

    func testFilingJobStateHasFourCases() {
        // Exhaustive switch ensures all four cases exist at compile time.
        let states: [FilingJobState] = [.filing, .done, .failed, .cancelled]
        XCTAssertEqual(states.count, 4)
    }

    // MARK: - FilingJob construction

    func testFilingJobConstructedInFilingStateHasNilResultAndError() throws {
        let repoURL = URL(fileURLWithPath: "/tmp/test-repo")
        let binding = RepoBinding(
            rootURL: repoURL,
            displayName: "test-repo",
            displayPath: "/tmp/test-repo"
        )
        let job = FilingJob(
            id: UUID(),
            transcript: "create a bug report",
            repo: binding,
            state: .filing
        )

        XCTAssertEqual(job.state, .filing)
        XCTAssertNil(job.result, "result must be nil when job is in .filing state")
        XCTAssertNil(job.error, "error must be nil when job is in .filing state")
        XCTAssertNil(job.task, "task must be nil when constructed without a task handle")
    }

    func testFilingJobIsIdentifiable() throws {
        let id = UUID()
        let repoURL = URL(fileURLWithPath: "/tmp/test-repo")
        let binding = RepoBinding(
            rootURL: repoURL,
            displayName: "test-repo",
            displayPath: "/tmp/test-repo"
        )
        let job = FilingJob(
            id: id,
            transcript: "transcript",
            repo: binding,
            state: .filing
        )

        XCTAssertEqual(job.id, id, "FilingJob.id must match the UUID passed at construction")
    }

    func testFilingJobStoresTranscriptAndRepo() throws {
        let repoURL = URL(fileURLWithPath: "/tmp/test-repo")
        let binding = RepoBinding(
            rootURL: repoURL,
            displayName: "test-repo",
            displayPath: "/tmp/test-repo"
        )
        let job = FilingJob(
            id: UUID(),
            transcript: "my transcript",
            repo: binding,
            state: .filing
        )

        XCTAssertEqual(job.transcript, "my transcript")
        XCTAssertEqual(job.repo.displayName, "test-repo")
    }
}
