import XCTest
@testable import MakeAnIssueWorkerCore

final class WorkerVersionTests: XCTestCase {
    func testVersionIsPresent() {
        XCTAssertFalse(WorkerVersion.current.isEmpty)
    }
}
