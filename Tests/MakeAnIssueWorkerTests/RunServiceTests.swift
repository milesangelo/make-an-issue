import XCTest
@testable import MakeAnIssueWorkerCore

final class RunServiceTests: XCTestCase {
    func testRunDelegatesAfterPreparingAndRecordsTerminalDriverOutcome() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let service = RunService(
            config: config,
            ledger: ledger,
            inspector: trustedBugInspector(),
            ownerPID: 777,
            executionDriver: TerminalTestDriver()
        )

        let outcome = try service.run(issueURL: "https://github.com/acme/widgets/issues/42")

        XCTAssertEqual(outcome.stateReached, .failed)
        let stored = try ledger.run(id: outcome.runID)
        XCTAssertEqual(stored.state, .failed)
        XCTAssertEqual(stored.failureCode, "test_driver_terminal")
        XCTAssertNil(try ledger.currentHostClaim())
        let transitions = try ledger.events(runID: outcome.runID).compactMap(\.toState)
        XCTAssertEqual(transitions, [.queued, .claimed, .preparing, .failed])
    }

    func testExplicitCLIRunIsSafelyRerunnableAfterTerminalOutcome() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let service = RunService(
            config: config,
            ledger: ledger,
            inspector: trustedBugInspector(),
            executionDriver: TerminalTestDriver()
        )

        let first = try service.run(issueURL: "https://github.com/acme/widgets/issues/42")
        let second = try service.run(issueURL: "https://github.com/acme/widgets/issues/42")

        XCTAssertNotEqual(first.runID, second.runID)
        let runs = try ledger.runs(repository: "acme/widgets", issueNumber: 42)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.state), [.failed, .failed])
        XCTAssertEqual(Set(runs.map(\.configRevision)), [config.revision])
    }

    func testExistingNonterminalRunSuppressesDuplicate() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let existing = try created(ledger.createRun(makeNewRun(issue: makeIssue(), id: "existing")))
        let service = RunService(config: config, ledger: ledger, inspector: trustedBugInspector())

        XCTAssertThrowsError(try service.run(issueURL: existing.issueURL)) { error in
            guard case RunServiceError.activeRunExists("existing") = error else {
                return XCTFail("Expected activeRunExists, got \(error)")
            }
        }
        XCTAssertEqual(try ledger.runs(repository: "acme/widgets", issueNumber: 42).count, 1)
    }

    func testConcurrentHostClaimIsRefusedAndNewRunFailsWithoutStealingClaim() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let blocker = try created(ledger.createRun(makeNewRun(issue: makeIssue(number: 1), id: "blocker")))
        _ = try ledger.claimHost(runID: blocker.id, ownerPID: 111)
        let service = RunService(
            config: config,
            ledger: ledger,
            inspector: trustedBugInspector(),
            ownerPID: 222,
            executionDriver: TerminalTestDriver()
        )

        XCTAssertThrowsError(try service.run(issueURL: "https://github.com/acme/widgets/issues/2")) { error in
            guard case RunServiceError.hostBusy(let detail) = error else {
                return XCTFail("Expected hostBusy, got \(error)")
            }
            XCTAssertTrue(detail.contains("blocker"))
        }
        XCTAssertEqual(try ledger.currentHostClaim()?.runID, "blocker")
        let refused = try XCTUnwrap(ledger.runs(repository: "acme/widgets", issueNumber: 2).first)
        XCTAssertEqual(refused.state, .failed)
        XCTAssertEqual(refused.failureCode, "host_busy")
    }

    func testTrustAndDefaultBranchChecksFailClosedBeforeLedgerInsertion() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let untrusted = RunService(
            config: config,
            ledger: ledger,
            inspector: FakeIssueInspector(result: .success(IssueFacts(labels: ["agent:run", "bug"], callerHasWriteAccess: false, defaultBranch: "main")))
        )

        XCTAssertThrowsError(try untrusted.run(issueURL: "https://github.com/acme/widgets/issues/42")) { error in
            guard case RunServiceError.untrustedCaller = error else {
                return XCTFail("Expected untrustedCaller, got \(error)")
            }
        }
        XCTAssertEqual(try ledger.runs(repository: "acme/widgets", issueNumber: 42), [])

        let mismatch = RunService(
            config: config,
            ledger: ledger,
            inspector: FakeIssueInspector(result: .success(IssueFacts(labels: ["agent:run", "bug"], callerHasWriteAccess: true, defaultBranch: "trunk")))
        )
        XCTAssertThrowsError(try mismatch.run(issueURL: "https://github.com/acme/widgets/issues/42")) { error in
            guard case RunServiceError.defaultBranchMismatch(expected: "main", observed: "trunk") = error else {
                return XCTFail("Expected defaultBranchMismatch, got \(error)")
            }
        }
        XCTAssertEqual(try ledger.runs(repository: "acme/widgets", issueNumber: 42), [])
    }

    func testAgentOverrideDoesNotRequireRoutingLabels() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let ledger = try RunLedger(stateRoot: fixture.stateRoot)
        let inspector = FakeIssueInspector(
            result: .success(IssueFacts(labels: [], callerHasWriteAccess: true, defaultBranch: "main"))
        )
        let service = RunService(
            config: config,
            ledger: ledger,
            inspector: inspector,
            executionDriver: TerminalTestDriver()
        )

        let outcome = try service.run(
            issueURL: "https://github.com/acme/widgets/issues/42",
            agentOverride: "bugfix"
        )

        XCTAssertEqual(try ledger.run(id: outcome.runID).routeID, "cli-agent-override")
    }

    private func trustedBugInspector() -> FakeIssueInspector {
        FakeIssueInspector(
            result: .success(
                IssueFacts(labels: ["agent:run", "bug"], callerHasWriteAccess: true, defaultBranch: "main")
            )
        )
    }

    private func created(_ insertion: RunInsertion) throws -> RunRecord {
        guard case .created(let run) = insertion else {
            throw LedgerError.sqlite("test expected created")
        }
        return run
    }
}
