import CSQLite
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class RunLedgerTests: XCTestCase {
    func testLegalTransitionsAppendEventsAndReachTerminalState() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let run = try created(ledger.createRun(makeNewRun(issue: makeIssue())))

        _ = try ledger.claimHost(runID: run.id, ownerPID: 123)
        _ = try ledger.transition(runID: run.id, to: .claimed)
        _ = try ledger.transition(runID: run.id, to: .preparing)
        _ = try ledger.transition(runID: run.id, to: .failed, failureCode: "test_failure")
        try ledger.releaseHostClaim(runID: run.id)

        let stored = try ledger.run(id: run.id)
        XCTAssertEqual(stored.state, .failed)
        XCTAssertEqual(stored.failureCode, "test_failure")
        XCTAssertNotNil(stored.finishedAt)
        XCTAssertEqual(
            try ledger.events(runID: run.id).map(\.kind),
            ["run_created", "host_claimed", "state_transition", "state_transition", "state_transition", "host_released"]
        )
    }

    func testIllegalTransitionFailsClosed() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let run = try created(ledger.createRun(makeNewRun(issue: makeIssue())))

        XCTAssertThrowsError(try ledger.transition(runID: run.id, to: .running)) { error in
            XCTAssertEqual(error as? LedgerError, .invalidTransition(from: .queued, to: .running))
        }
        XCTAssertEqual(try ledger.run(id: run.id).state, .queued)
        XCTAssertEqual(try ledger.events(runID: run.id).count, 1)
    }

    func testTerminalRecordsRemainImmutableAndExplicitRerunAppendsHistory() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let issue = try makeIssue()
        let first = try created(ledger.createRun(makeNewRun(issue: issue, id: "first-run")))
        _ = try ledger.transition(runID: first.id, to: .failed, failureCode: "first")
        let firstEvents = try ledger.events(runID: first.id)

        XCTAssertThrowsError(try ledger.transition(runID: first.id, to: .claimed)) { error in
            XCTAssertEqual(error as? LedgerError, .invalidTransition(from: .failed, to: .claimed))
        }

        let second = try created(ledger.createRun(makeNewRun(issue: issue, id: "second-run")))
        let history = try ledger.runs(repository: issue.repository, issueNumber: issue.issueNumber)
        XCTAssertEqual(history.map(\.id), ["first-run", "second-run"])
        XCTAssertEqual(history.map(\.state), [.failed, .queued])
        XCTAssertEqual(try ledger.events(runID: first.id), firstEvents)
        XCTAssertEqual(second.configRevision, String(repeating: "a", count: 64))
    }

    func testDatabaseTriggersRejectRunDeletionAndEventMutation() throws {
        let fixture = try ConfigFixture()
        let databaseURL = fixture.stateRoot.appendingPathComponent(RunLedger.databaseFileName)
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let run = try created(ledger.createRun(makeNewRun(issue: makeIssue())))
        _ = try ledger.transition(runID: run.id, to: .failed, failureCode: "terminal")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertNotEqual(sqlite3_exec(database, "DELETE FROM runs", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(database, "UPDATE run_events SET kind = 'changed'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try ledger.runs(repository: run.repository, issueNumber: run.issueNumber).count, 1)
    }

    func testDuplicateObservationReturnsExistingNonterminalRun() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let issue = try makeIssue()
        let first = try created(ledger.createRun(makeNewRun(issue: issue, id: "first")))

        let duplicate = try ledger.createRun(makeNewRun(issue: issue, id: "duplicate"))

        XCTAssertEqual(duplicate, .existing(first))
        XCTAssertEqual(try ledger.runs(repository: issue.repository, issueNumber: issue.issueNumber).map(\.id), ["first"])
    }

    func testHostClaimIsSingletonAndOwnerChecked() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let first = try created(ledger.createRun(makeNewRun(issue: makeIssue(number: 1), id: "first")))
        let second = try created(ledger.createRun(makeNewRun(issue: makeIssue(number: 2), id: "second")))
        let claim = try ledger.claimHost(runID: first.id, ownerPID: 111)

        XCTAssertEqual(claim, try ledger.currentHostClaim())
        XCTAssertThrowsError(try ledger.claimHost(runID: second.id, ownerPID: 222)) { error in
            XCTAssertEqual(error as? LedgerError, .hostAlreadyClaimed(claim))
        }
        XCTAssertThrowsError(try ledger.releaseHostClaim(runID: second.id)) { error in
            XCTAssertEqual(error as? LedgerError, .claimNotOwned(second.id))
        }
        try ledger.clearReconciledHostClaim(expectedRunID: first.id)
        XCTAssertNil(try ledger.currentHostClaim())
    }

    func testStartupAndPublishingReconciliationQueries() throws {
        let fixture = try ConfigFixture()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let publishing = try created(ledger.createRun(makeNewRun(issue: makeIssue(number: 1), id: "publishing")))
        _ = try ledger.transition(runID: publishing.id, to: .claimed)
        _ = try ledger.transition(runID: publishing.id, to: .preparing)
        _ = try ledger.transition(runID: publishing.id, to: .running)
        _ = try ledger.transition(runID: publishing.id, to: .validating)
        _ = try ledger.transition(runID: publishing.id, to: .publishing)
        let terminal = try created(ledger.createRun(makeNewRun(issue: makeIssue(number: 2), id: "terminal")))
        _ = try ledger.transition(runID: terminal.id, to: .failed, failureCode: "done")

        XCTAssertEqual(try ledger.startupReconciliationCandidates().map(\.id), ["publishing"])
        XCTAssertEqual(try ledger.publishingReconciliationCandidates().map(\.id), ["publishing"])
    }

    private func created(_ insertion: RunInsertion) throws -> RunRecord {
        guard case .created(let run) = insertion else {
            XCTFail("Expected a newly created run")
            throw LedgerError.sqlite("test expected created")
        }
        return run
    }
}
