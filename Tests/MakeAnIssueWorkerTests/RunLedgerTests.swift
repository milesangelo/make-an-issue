import CSQLite
import Darwin
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

    func testKernelEraLedgerMigratesForwardPreservingRows() throws {
        let fixture = try ConfigFixture()
        try FileManager.default.createDirectory(
            at: fixture.stateRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(fixture.stateRoot.path, 0o700)
        let databaseURL = fixture.stateRoot.appendingPathComponent(RunLedger.databaseFileName)

        // A ledger created before `runs` carried the publisher columns (base_sha…pr_is_draft),
        // seeded with a run and its history that the additive migration must preserve verbatim.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let kernelSchema = """
        PRAGMA user_version=1;
        CREATE TABLE run_groups(
            id INTEGER PRIMARY KEY,
            repository TEXT NOT NULL,
            issue_number INTEGER NOT NULL CHECK(issue_number > 0),
            label_removal_outcome TEXT,
            label_cleanup_cursor_event_id TEXT,
            UNIQUE(repository, issue_number),
            UNIQUE(id, repository, issue_number)
        );
        CREATE TABLE runs(
            id TEXT PRIMARY KEY,
            group_id INTEGER NOT NULL REFERENCES run_groups(id),
            repository TEXT NOT NULL,
            issue_number INTEGER NOT NULL,
            issue_url TEXT NOT NULL,
            config_revision TEXT NOT NULL,
            config_snapshot_redacted TEXT NOT NULL,
            route_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            trigger_kind TEXT NOT NULL,
            trigger_event_id TEXT,
            trigger_event_at REAL,
            state TEXT NOT NULL,
            failure_code TEXT,
            created_at REAL NOT NULL,
            claimed_at REAL,
            updated_at REAL NOT NULL,
            finished_at REAL,
            FOREIGN KEY(group_id, repository, issue_number)
                REFERENCES run_groups(id, repository, issue_number)
        );
        CREATE TABLE run_events(
            id INTEGER PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES runs(id),
            sequence INTEGER NOT NULL,
            kind TEXT NOT NULL,
            from_state TEXT,
            to_state TEXT,
            detail TEXT,
            created_at REAL NOT NULL,
            UNIQUE(run_id, sequence)
        );
        CREATE TABLE host_claim(
            singleton_key INTEGER PRIMARY KEY CHECK(singleton_key = 1),
            run_id TEXT UNIQUE REFERENCES runs(id),
            owner_pid INTEGER,
            claimed_at REAL
        );
        INSERT INTO host_claim(singleton_key) VALUES (1);
        INSERT INTO run_groups(id, repository, issue_number) VALUES (1, 'acme/widgets', 42);
        INSERT INTO runs(
            id, group_id, repository, issue_number, issue_url, config_revision,
            config_snapshot_redacted, route_id, agent_id, trigger_kind, state, created_at, updated_at
        ) VALUES (
            'kernel-run', 1, 'acme/widgets', 42, 'https://github.com/acme/widgets/issues/42',
            'rev', 'snap', 'bug', 'bugfix', 'cli', 'queued', 1000.0, 1000.0
        );
        INSERT INTO run_events(run_id, sequence, kind, to_state, created_at)
        VALUES ('kernel-run', 1, 'run_created', 'queued', 1000.0);
        """
        XCTAssertEqual(sqlite3_exec(database, kernelSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let ledger = try RunLedger(stateRoot: fixture.stateRoot)

        let runs = try ledger.runs(repository: "acme/widgets", issueNumber: 42)
        XCTAssertEqual(runs.map(\.id), ["kernel-run"], "the pre-migration run must survive")
        XCTAssertEqual(runs.first?.state, .queued)
        XCTAssertNil(runs.first?.baseSHA, "backfilled publisher columns default to NULL")
        XCTAssertEqual(try ledger.events(runID: "kernel-run").map(\.kind), ["run_created"])

        // The migrated ledger is fully usable: transitions and new-surface writes both succeed.
        _ = try ledger.claimHost(runID: "kernel-run", ownerPID: 4242)
        _ = try ledger.transition(runID: "kernel-run", to: .claimed)
        _ = try ledger.transition(runID: "kernel-run", to: .preparing)
        _ = try ledger.transition(runID: "kernel-run", to: .running)
        try ledger.recordProviderExit(runID: "kernel-run", pid: 99, exit: 0)
        let updated = try ledger.run(id: "kernel-run")
        XCTAssertEqual(updated.state, .running)
        XCTAssertEqual(updated.providerExit, 0)

        XCTAssertEqual(try Self.userVersion(databaseURL), 2, "the schema version must be recorded forward")
    }

    func testLedgerRefusesToStartOnUnknownNewerSchema() throws {
        let fixture = try ConfigFixture()
        try FileManager.default.createDirectory(
            at: fixture.stateRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(fixture.stateRoot.path, 0o700)
        let databaseURL = fixture.stateRoot.appendingPathComponent(RunLedger.databaseFileName)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=999;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        XCTAssertThrowsError(try RunLedger(stateRoot: fixture.stateRoot)) { error in
            guard case .sqlite(let reason)? = error as? LedgerError else {
                return XCTFail("expected sqlite ledger error, got \(error)")
            }
            XCTAssertTrue(reason.contains("newer than this build supports"), "unexpected reason: \(reason)")
        }
    }

    private static func userVersion(_ databaseURL: URL) throws -> Int64 {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func created(_ insertion: RunInsertion) throws -> RunRecord {
        guard case .created(let run) = insertion else {
            XCTFail("Expected a newly created run")
            throw LedgerError.sqlite("test expected created")
        }
        return run
    }
}
