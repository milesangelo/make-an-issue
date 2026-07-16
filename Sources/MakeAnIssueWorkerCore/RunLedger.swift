import CSQLite
import Darwin
import Foundation

public enum RunState: String, CaseIterable, Sendable {
    case queued
    case claimed
    case preparing
    case running
    case validating
    case publishing
    case prOpened = "pr_opened"
    case failed

    public var isTerminal: Bool { self == .prOpened || self == .failed }

    public func permits(_ next: RunState) -> Bool {
        switch self {
        case .queued: return next == .claimed || next == .failed
        case .claimed: return next == .preparing || next == .failed
        case .preparing: return next == .running || next == .failed
        case .running: return next == .validating || next == .failed
        case .validating: return next == .publishing || next == .failed
        case .publishing: return next == .prOpened || next == .failed
        case .prOpened, .failed: return false
        }
    }
}

public enum TriggerKind: String, Sendable {
    case cli
    case label
    case appPostFile = "app-post-file"
}

public struct NewRun: Sendable {
    public let id: String
    public let issue: IssueReference
    public let configRevision: String
    public let redactedConfigSnapshot: String
    public let routeID: String
    public let agentID: String
    public let triggerKind: TriggerKind
    public let triggerEventID: String?
    public let triggerEventAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        issue: IssueReference,
        configRevision: String,
        redactedConfigSnapshot: String,
        routeID: String,
        agentID: String,
        triggerKind: TriggerKind,
        triggerEventID: String? = nil,
        triggerEventAt: Date? = nil
    ) {
        self.id = id
        self.issue = issue
        self.configRevision = configRevision
        self.redactedConfigSnapshot = redactedConfigSnapshot
        self.routeID = routeID
        self.agentID = agentID
        self.triggerKind = triggerKind
        self.triggerEventID = triggerEventID
        self.triggerEventAt = triggerEventAt
    }
}

public struct RunRecord: Equatable, Sendable {
    public let id: String
    public let repository: String
    public let issueNumber: Int
    public let issueURL: String
    public let configRevision: String
    public let routeID: String
    public let agentID: String
    public let triggerKind: TriggerKind
    public let state: RunState
    public let failureCode: String?
    public let baseSHA: String?
    public let branchName: String?
    public let workspaceID: String?
    public let workspacePath: String?
    public let providerPID: Int32?
    public let providerExit: Int32?
    public let patchPath: String?
    public let logDirectory: String?
    public let validatedSHA: String?
    public let remoteBranchSHA: String?
    public let prNumber: Int?
    public let prURL: String?
    public let prIsDraft: Bool?
    public let createdAt: Date
    public let claimedAt: Date?
    public let updatedAt: Date
    public let finishedAt: Date?
}

public struct RunEvent: Equatable, Sendable {
    public let sequence: Int
    public let runID: String
    public let kind: String
    public let fromState: RunState?
    public let toState: RunState?
    public let detail: String?
    public let createdAt: Date
}

public struct HostClaim: Equatable, Sendable {
    public let runID: String
    public let ownerPID: Int32
    public let claimedAt: Date
}

public enum RunInsertion: Equatable, Sendable {
    case created(RunRecord)
    case existing(RunRecord)
}

public enum LedgerError: Error, Equatable, CustomStringConvertible, Sendable {
    case sqlite(String)
    case runNotFound(String)
    case invalidTransition(from: RunState, to: RunState)
    case hostAlreadyClaimed(HostClaim)
    case claimNotOwned(String)

    public var description: String {
        switch self {
        case .sqlite(let reason): return "SQLite ledger error: \(reason)"
        case .runNotFound(let id): return "run \(id) was not found"
        case .invalidTransition(let from, let to): return "invalid run transition \(from.rawValue) -> \(to.rawValue)"
        case .hostAlreadyClaimed(let claim): return "host is already claimed by run \(claim.runID) (pid \(claim.ownerPID))"
        case .claimNotOwned(let id): return "host claim is not owned by run \(id)"
        }
    }
}

public final class RunLedger: @unchecked Sendable {
    public static let databaseFileName = "worker.sqlite3"

    private let database: OpaquePointer
    private let lock = NSLock()
    private let stateRoot: URL

    /// Test-only seam invoked inside `recordPublicationAndOpen`'s transaction to deterministically
    /// simulate a durable-write failure after the remote draft PR has been opened. Always nil in
    /// production; throwing here rolls back the whole publication recording.
    var recordPublicationFaultForTesting: (() throws -> Void)?

    public convenience init(stateRoot: URL) throws {
        try StateDirectory.ensure(stateRoot)
        try self.init(databaseURL: stateRoot.appendingPathComponent(Self.databaseFileName))
    }

    public init(databaseURL: URL) throws {
        try StateDirectory.ensure(databaseURL.deletingLastPathComponent())
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close(handle) }
            throw LedgerError.sqlite(reason)
        }
        database = handle
        stateRoot = databaseURL.deletingLastPathComponent().standardizedFileURL
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=5000")
            try execute("PRAGMA synchronous=FULL")
            try migrate()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public func createRun(_ newRun: NewRun) throws -> RunInsertion {
        try synchronized {
            try transaction(immediate: true) {
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    INSERT INTO run_groups(repository, issue_number)
                    VALUES (?, ?)
                    ON CONFLICT(repository, issue_number) DO NOTHING
                    """,
                    [.text(newRun.issue.repository), .integer(Int64(newRun.issue.issueNumber))]
                )
                let groupID = try scalarInt64(
                    "SELECT id FROM run_groups WHERE repository = ? AND issue_number = ?",
                    [.text(newRun.issue.repository), .integer(Int64(newRun.issue.issueNumber))]
                )
                try execute(
                    """
                    INSERT INTO runs(
                        id, group_id, repository, issue_number, issue_url, config_revision,
                        config_snapshot_redacted, route_id, agent_id, trigger_kind,
                        trigger_event_id, trigger_event_at, state, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?)
                    ON CONFLICT DO NOTHING
                    """,
                    [
                        .text(newRun.id), .integer(groupID), .text(newRun.issue.repository),
                        .integer(Int64(newRun.issue.issueNumber)), .text(newRun.issue.url.absoluteString),
                        .text(newRun.configRevision), .text(newRun.redactedConfigSnapshot),
                        .text(newRun.routeID), .text(newRun.agentID), .text(newRun.triggerKind.rawValue),
                        .optionalText(newRun.triggerEventID), .optionalDouble(newRun.triggerEventAt?.timeIntervalSince1970),
                        .double(now), .double(now),
                    ]
                )
                if sqlite3_changes(database) == 1 {
                    try insertEvent(
                        runID: newRun.id,
                        kind: "run_created",
                        from: nil,
                        to: .queued,
                        detail: nil,
                        at: now
                    )
                    return .created(try fetchRunUnlocked(id: newRun.id))
                }
                let existing = try fetchActiveRunUnlocked(
                    repository: newRun.issue.repository,
                    issueNumber: newRun.issue.issueNumber
                )
                guard let existing else {
                    throw LedgerError.sqlite("run insert was ignored without an active conflicting run")
                }
                return .existing(existing)
            }
        }
    }

    @discardableResult
    public func transition(
        runID: String,
        to nextState: RunState,
        failureCode: String? = nil,
        detail: String? = nil
    ) throws -> RunRecord {
        try synchronized {
            try transaction(immediate: true) {
                let current = try fetchRunUnlocked(id: runID)
                guard current.state.permits(nextState) else {
                    throw LedgerError.invalidTransition(from: current.state, to: nextState)
                }
                let now = Date().timeIntervalSince1970
                let claimedAt: Double? = nextState == .claimed ? now : current.claimedAt?.timeIntervalSince1970
                let finishedAt: Double? = nextState.isTerminal ? now : nil
                try execute(
                    """
                    UPDATE runs
                    SET state = ?, failure_code = ?, claimed_at = ?, updated_at = ?, finished_at = ?
                    WHERE id = ?
                    """,
                    [
                        .text(nextState.rawValue), .optionalText(failureCode), .optionalDouble(claimedAt),
                        .double(now), .optionalDouble(finishedAt), .text(runID),
                    ]
                )
                try insertEvent(
                    runID: runID,
                    kind: "state_transition",
                    from: current.state,
                    to: nextState,
                    detail: detail ?? failureCode,
                    at: now
                )
                return try fetchRunUnlocked(id: runID)
            }
        }
    }

    public func claimHost(runID: String, ownerPID: Int32 = getpid()) throws -> HostClaim {
        try synchronized {
            try transaction(immediate: true) {
                let run = try fetchRunUnlocked(id: runID)
                guard !run.state.isTerminal else {
                    throw LedgerError.sqlite("terminal run \(runID) cannot claim the host")
                }
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE host_claim
                    SET run_id = ?, owner_pid = ?, claimed_at = ?
                    WHERE singleton_key = 1 AND run_id IS NULL
                    """,
                    [.text(runID), .integer(Int64(ownerPID)), .double(now)]
                )
                guard sqlite3_changes(database) == 1 else {
                    if let claim = try currentHostClaimUnlocked() {
                        throw LedgerError.hostAlreadyClaimed(claim)
                    }
                    throw LedgerError.sqlite("host claim update failed")
                }
                try insertEvent(runID: runID, kind: "host_claimed", from: nil, to: nil, detail: "pid=\(ownerPID)", at: now)
                return HostClaim(runID: runID, ownerPID: ownerPID, claimedAt: Date(timeIntervalSince1970: now))
            }
        }
    }

    public func releaseHostClaim(runID: String) throws {
        try synchronized {
            try transaction(immediate: true) {
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE host_claim
                    SET run_id = NULL, owner_pid = NULL, claimed_at = NULL
                    WHERE singleton_key = 1 AND run_id = ?
                    """,
                    [.text(runID)]
                )
                guard sqlite3_changes(database) == 1 else { throw LedgerError.claimNotOwned(runID) }
                try insertEvent(runID: runID, kind: "host_released", from: nil, to: nil, detail: nil, at: now)
            }
        }
    }

    /// Startup reconciliation calls this only after proving the owner process is gone and
    /// reconciling the referenced run. The expected ID prevents clearing a changed claim.
    public func clearReconciledHostClaim(expectedRunID: String) throws {
        try releaseHostClaim(runID: expectedRunID)
    }

    public func currentHostClaim() throws -> HostClaim? {
        try synchronized { try currentHostClaimUnlocked() }
    }

    public func run(id: String) throws -> RunRecord {
        try synchronized { try fetchRunUnlocked(id: id) }
    }

    public func configSnapshot(runID: String) throws -> String {
        try synchronized {
            guard let value = try scalarText(
                "SELECT config_snapshot_redacted FROM runs WHERE id = ?",
                [.text(runID)]
            ) else { throw LedgerError.runNotFound(runID) }
            return value
        }
    }

    public func runs(repository: String, issueNumber: Int) throws -> [RunRecord] {
        try synchronized {
            try queryRuns(
                "SELECT \(runColumns) FROM runs WHERE repository = ? AND issue_number = ? ORDER BY created_at, id",
                [.text(repository), .integer(Int64(issueNumber))]
            )
        }
    }

    public func events(runID: String) throws -> [RunEvent] {
        try synchronized {
            var statement: OpaquePointer?
            try prepare(
                """
                SELECT sequence, run_id, kind, from_state, to_state, detail, created_at
                FROM run_events WHERE run_id = ? ORDER BY sequence
                """,
                &statement
            )
            defer { sqlite3_finalize(statement) }
            try bind([.text(runID)], to: statement)
            var results: [RunEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(
                    RunEvent(
                        sequence: Int(sqlite3_column_int64(statement, 0)),
                        runID: columnText(statement, 1)!,
                        kind: columnText(statement, 2)!,
                        fromState: columnText(statement, 3).flatMap(RunState.init(rawValue:)),
                        toState: columnText(statement, 4).flatMap(RunState.init(rawValue:)),
                        detail: columnText(statement, 5),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                    )
                )
            }
            try checkStatement(statement)
            return results
        }
    }

    public func recordPreparation(
        runID: String,
        baseSHA: String,
        branchName: String,
        workspace: WorkspaceLease,
        artifacts: ArtifactStore
    ) throws {
        try requireStoredPath(workspace.path)
        try requireStoredPath(artifacts.patchURL)
        try requireStoredPath(artifacts.logDirectory)
        try updateArtifacts(
            runID: runID,
            assignments: "base_sha = ?, branch_name = ?, workspace_id = ?, workspace_path = ?, patch_path = ?, log_dir = ?",
            values: [
                .text(baseSHA), .text(branchName), .text(workspace.id), .text(workspace.path.path),
                .text(artifacts.patchURL.path), .text(artifacts.logDirectory.path),
            ],
            event: "preparation_recorded",
            detail: "base=\(baseSHA) branch=\(branchName) workspace=\(workspace.id)"
        )
    }

    public func recordProviderExit(runID: String, pid: Int32?, exit: Int32) throws {
        try updateArtifacts(
            runID: runID,
            assignments: "provider_pid = ?, provider_exit = ?",
            values: [.optionalInt64(pid.map(Int64.init)), .integer(Int64(exit))],
            event: "provider_exited",
            detail: "exit=\(exit)"
        )
    }

    public func recordProviderOutcome(
        runID: String,
        pid: Int32?,
        outcome: ProviderExecutionOutcome
    ) throws {
        let metadata: [String: Any] = [
            "status": outcome.status.rawValue,
            "process_id": pid.map { $0 as Any } ?? NSNull(),
            "exit_code": outcome.exitCode,
            "duration_ms": outcome.durationMilliseconds,
            "stdout_truncated": outcome.stdoutTruncated,
            "stderr_truncated": outcome.stderrTruncated,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try updateArtifacts(
            runID: runID,
            assignments: "provider_pid = ?, provider_exit = ?",
            values: [.optionalInt64(pid.map(Int64.init)), .integer(Int64(outcome.exitCode))],
            event: "provider_outcome",
            detail: String(decoding: data, as: UTF8.self)
        )
    }

    public func recordInspection(runID: String, inspection: DiffInspection) throws {
        try appendObservation(
            runID: runID,
            kind: "diff_inspected",
            detail: "id=\(inspection.id) digest=\(inspection.digest) files=\(inspection.changedFiles.count)"
        )
    }

    public func recordValidatedSHA(runID: String, sha: String, receiptID: String) throws {
        try updateArtifacts(
            runID: runID,
            assignments: "validated_sha = ?",
            values: [.text(sha)],
            event: "validation_green",
            detail: "receipt=\(receiptID) sha=\(sha)"
        )
    }

    public func recordPublicationIntent(runID: String, branch: String, baseSHA: String, headSHA: String) throws {
        try appendObservation(
            runID: runID,
            kind: "publication_intent",
            detail: "branch=\(branch) base=\(baseSHA) head=\(headSHA) draft=true"
        )
    }

    public func recordRemoteBranch(runID: String, sha: String) throws {
        try updateArtifacts(
            runID: runID,
            assignments: "remote_branch_sha = ?",
            values: [.text(sha)],
            event: "remote_branch_observed",
            detail: sha
        )
    }

    public func recordPullRequest(runID: String, number: Int, url: String, isDraft: Bool) throws {
        try updateArtifacts(
            runID: runID,
            assignments: "pr_number = ?, pr_url = ?, pr_is_draft = ?",
            values: [.integer(Int64(number)), .text(url), .integer(isDraft ? 1 : 0)],
            event: "pull_request_verified",
            detail: "number=\(number) draft=\(isDraft) url=\(url)"
        )
    }

    /// Atomically records the verified remote branch, pull-request metadata, and the terminal
    /// `pr_opened` transition in a single transaction: either every write lands or none do.
    public func recordPublicationAndOpen(
        runID: String,
        remoteBranchSHA: String,
        prNumber: Int,
        prURL: String,
        prIsDraft: Bool,
        detail: String? = nil
    ) throws -> RunRecord {
        try synchronized {
            try transaction(immediate: true) {
                let current = try fetchRunUnlocked(id: runID)
                guard current.state.permits(.prOpened) else {
                    throw LedgerError.invalidTransition(from: current.state, to: .prOpened)
                }
                let now = Date().timeIntervalSince1970
                try execute(
                    """
                    UPDATE runs
                    SET remote_branch_sha = ?, pr_number = ?, pr_url = ?, pr_is_draft = ?,
                        state = ?, failure_code = NULL, updated_at = ?, finished_at = ?
                    WHERE id = ?
                    """,
                    [
                        .text(remoteBranchSHA), .integer(Int64(prNumber)), .text(prURL),
                        .integer(prIsDraft ? 1 : 0), .text(RunState.prOpened.rawValue),
                        .double(now), .double(now), .text(runID),
                    ]
                )
                try insertEvent(
                    runID: runID, kind: "remote_branch_observed", from: nil, to: nil,
                    detail: remoteBranchSHA, at: now
                )
                try insertEvent(
                    runID: runID, kind: "pull_request_verified", from: nil, to: nil,
                    detail: "number=\(prNumber) draft=\(prIsDraft) url=\(prURL)", at: now
                )
                try insertEvent(
                    runID: runID, kind: "state_transition", from: current.state, to: .prOpened,
                    detail: detail, at: now
                )
                try recordPublicationFaultForTesting?()
                return try fetchRunUnlocked(id: runID)
            }
        }
    }

    public func appendObservation(runID: String, kind: String, detail: String?) throws {
        try synchronized {
            try transaction(immediate: true) {
                _ = try fetchRunUnlocked(id: runID)
                try insertEvent(
                    runID: runID,
                    kind: kind,
                    from: nil,
                    to: nil,
                    detail: detail,
                    at: Date().timeIntervalSince1970
                )
            }
        }
    }

    /// Non-terminal rows that startup must inspect before claiming new work.
    public func startupReconciliationCandidates() throws -> [RunRecord] {
        try synchronized {
            try queryRuns(
                "SELECT \(runColumns) FROM runs WHERE state NOT IN ('pr_opened', 'failed') ORDER BY created_at",
                []
            )
        }
    }

    /// Publication-specific hook used by the future publisher reconciliation slice.
    public func publishingReconciliationCandidates() throws -> [RunRecord] {
        try synchronized {
            try queryRuns(
                "SELECT \(runColumns) FROM runs WHERE state = 'publishing' ORDER BY created_at",
                []
            )
        }
    }

    private var runColumns: String {
        "id, repository, issue_number, issue_url, config_revision, route_id, agent_id, trigger_kind, state, failure_code, base_sha, branch_name, workspace_id, workspace_path, provider_pid, provider_exit, patch_path, log_dir, validated_sha, remote_branch_sha, pr_number, pr_url, pr_is_draft, created_at, claimed_at, updated_at, finished_at"
    }

    private static let currentSchemaVersion: Int64 = 2

    private func migrate() throws {
        let existingVersion = try scalarInt64("PRAGMA user_version", [])
        guard existingVersion <= Self.currentSchemaVersion else {
            throw LedgerError.sqlite(
                "worker ledger schema version \(existingVersion) is newer than this build supports "
                    + "(\(Self.currentSchemaVersion)); refusing to start"
            )
        }
        try transaction(immediate: true) {
            try executeScript(Self.schemaScript)
            try addMissingRunColumns()
            try executeScript("PRAGMA user_version=\(Self.currentSchemaVersion);")
        }
    }

    /// Additive migration for ledgers created before `runs` carried the publisher columns. Every
    /// column is nullable, so `ALTER TABLE ADD COLUMN` preserves all existing runs/events/artifacts
    /// rows and only backfills the missing surface with NULL defaults.
    private func addMissingRunColumns() throws {
        let existing = try runColumnNames()
        let additive: [(name: String, type: String)] = [
            ("base_sha", "TEXT"), ("branch_name", "TEXT"), ("workspace_id", "TEXT"),
            ("workspace_path", "TEXT"), ("provider_pid", "INTEGER"), ("provider_exit", "INTEGER"),
            ("patch_path", "TEXT"), ("log_dir", "TEXT"), ("validated_sha", "TEXT"),
            ("remote_branch_sha", "TEXT"), ("pr_number", "INTEGER"), ("pr_url", "TEXT"),
            ("pr_is_draft", "INTEGER"),
        ]
        for column in additive where !existing.contains(column.name) {
            try execute("ALTER TABLE runs ADD COLUMN \(column.name) \(column.type)")
        }
    }

    private func runColumnNames() throws -> Set<String> {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(runs)", &statement)
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement, 1) { names.insert(name) }
        }
        try checkStatement(statement)
        return names
    }

    private static let schemaScript =
            """
            CREATE TABLE IF NOT EXISTS run_groups(
                id INTEGER PRIMARY KEY,
                repository TEXT NOT NULL,
                issue_number INTEGER NOT NULL CHECK(issue_number > 0),
                label_removal_outcome TEXT,
                label_cleanup_cursor_event_id TEXT,
                UNIQUE(repository, issue_number),
                UNIQUE(id, repository, issue_number)
            );

            CREATE TABLE IF NOT EXISTS runs(
                id TEXT PRIMARY KEY,
                group_id INTEGER NOT NULL REFERENCES run_groups(id),
                repository TEXT NOT NULL,
                issue_number INTEGER NOT NULL,
                issue_url TEXT NOT NULL,
                config_revision TEXT NOT NULL,
                config_snapshot_redacted TEXT NOT NULL,
                route_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                trigger_kind TEXT NOT NULL CHECK(trigger_kind IN ('cli', 'label', 'app-post-file')),
                trigger_event_id TEXT,
                trigger_event_at REAL,
                state TEXT NOT NULL CHECK(state IN ('queued', 'claimed', 'preparing', 'running', 'validating', 'publishing', 'pr_opened', 'failed')),
                failure_code TEXT,
                base_sha TEXT,
                branch_name TEXT,
                workspace_id TEXT,
                workspace_path TEXT,
                provider_pid INTEGER,
                provider_exit INTEGER,
                patch_path TEXT,
                log_dir TEXT,
                validated_sha TEXT,
                remote_branch_sha TEXT,
                pr_number INTEGER,
                pr_url TEXT,
                pr_is_draft INTEGER,
                created_at REAL NOT NULL,
                claimed_at REAL,
                updated_at REAL NOT NULL,
                finished_at REAL,
                FOREIGN KEY(group_id, repository, issue_number)
                    REFERENCES run_groups(id, repository, issue_number)
            );

            CREATE UNIQUE INDEX IF NOT EXISTS one_nonterminal_run_per_group
            ON runs(repository, issue_number)
            WHERE state NOT IN ('pr_opened', 'failed');

            CREATE TABLE IF NOT EXISTS run_events(
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

            CREATE TABLE IF NOT EXISTS host_claim(
                singleton_key INTEGER PRIMARY KEY CHECK(singleton_key = 1),
                run_id TEXT UNIQUE REFERENCES runs(id),
                owner_pid INTEGER,
                claimed_at REAL
            );

            INSERT INTO host_claim(singleton_key) VALUES (1)
            ON CONFLICT(singleton_key) DO NOTHING;

            CREATE TRIGGER IF NOT EXISTS runs_no_delete
            BEFORE DELETE ON runs BEGIN SELECT RAISE(ABORT, 'run records are append-only'); END;

            CREATE TRIGGER IF NOT EXISTS run_events_no_update
            BEFORE UPDATE ON run_events BEGIN SELECT RAISE(ABORT, 'run events are append-only'); END;

            CREATE TRIGGER IF NOT EXISTS run_events_no_delete
            BEFORE DELETE ON run_events BEGIN SELECT RAISE(ABORT, 'run events are append-only'); END;

            CREATE TRIGGER IF NOT EXISTS runs_identity_immutable
            BEFORE UPDATE ON runs
            WHEN OLD.id IS NOT NEW.id
              OR OLD.group_id IS NOT NEW.group_id
              OR OLD.repository IS NOT NEW.repository
              OR OLD.issue_number IS NOT NEW.issue_number
              OR OLD.issue_url IS NOT NEW.issue_url
              OR OLD.config_revision IS NOT NEW.config_revision
              OR OLD.config_snapshot_redacted IS NOT NEW.config_snapshot_redacted
              OR OLD.route_id IS NOT NEW.route_id
              OR OLD.agent_id IS NOT NEW.agent_id
              OR OLD.trigger_kind IS NOT NEW.trigger_kind
              OR OLD.trigger_event_id IS NOT NEW.trigger_event_id
              OR OLD.trigger_event_at IS NOT NEW.trigger_event_at
              OR OLD.created_at IS NOT NEW.created_at
            BEGIN SELECT RAISE(ABORT, 'run identity fields are immutable'); END;

            CREATE TRIGGER IF NOT EXISTS terminal_runs_immutable
            BEFORE UPDATE ON runs
            WHEN OLD.state IN ('pr_opened', 'failed')
            BEGIN SELECT RAISE(ABORT, 'terminal run records are immutable'); END;

            CREATE TRIGGER IF NOT EXISTS runs_valid_transition
            BEFORE UPDATE OF state ON runs
            WHEN NOT (
                (OLD.state = 'queued' AND NEW.state IN ('claimed', 'failed')) OR
                (OLD.state = 'claimed' AND NEW.state IN ('preparing', 'failed')) OR
                (OLD.state = 'preparing' AND NEW.state IN ('running', 'failed')) OR
                (OLD.state = 'running' AND NEW.state IN ('validating', 'failed')) OR
                (OLD.state = 'validating' AND NEW.state IN ('publishing', 'failed')) OR
                (OLD.state = 'publishing' AND NEW.state IN ('pr_opened', 'failed'))
            )
            BEGIN SELECT RAISE(ABORT, 'invalid run state transition'); END;
            """

    private func insertEvent(
        runID: String,
        kind: String,
        from: RunState?,
        to: RunState?,
        detail: String?,
        at: Double
    ) throws {
        let next = try scalarInt64(
            "SELECT COALESCE(MAX(sequence), 0) + 1 FROM run_events WHERE run_id = ?",
            [.text(runID)]
        )
        try execute(
            """
            INSERT INTO run_events(run_id, sequence, kind, from_state, to_state, detail, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(runID), .integer(next), .text(kind), .optionalText(from?.rawValue),
                .optionalText(to?.rawValue), .optionalText(detail), .double(at),
            ]
        )
    }

    private func fetchRunUnlocked(id: String) throws -> RunRecord {
        let results = try queryRuns("SELECT \(runColumns) FROM runs WHERE id = ?", [.text(id)])
        guard let run = results.first else { throw LedgerError.runNotFound(id) }
        return run
    }

    private func fetchActiveRunUnlocked(repository: String, issueNumber: Int) throws -> RunRecord? {
        try queryRuns(
            """
            SELECT \(runColumns) FROM runs
            WHERE repository = ? AND issue_number = ? AND state NOT IN ('pr_opened', 'failed')
            LIMIT 1
            """,
            [.text(repository), .integer(Int64(issueNumber))]
        ).first
    }

    private func queryRuns(_ sql: String, _ bindings: [SQLiteValue]) throws -> [RunRecord] {
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var results: [RunRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let triggerKind = columnText(statement, 7).flatMap(TriggerKind.init(rawValue:)),
                  let state = columnText(statement, 8).flatMap(RunState.init(rawValue:)) else {
                throw LedgerError.sqlite("ledger contains an unknown enum value")
            }
            results.append(
                RunRecord(
                    id: columnText(statement, 0)!,
                    repository: columnText(statement, 1)!,
                    issueNumber: Int(sqlite3_column_int64(statement, 2)),
                    issueURL: columnText(statement, 3)!,
                    configRevision: columnText(statement, 4)!,
                    routeID: columnText(statement, 5)!,
                    agentID: columnText(statement, 6)!,
                    triggerKind: triggerKind,
                    state: state,
                    failureCode: columnText(statement, 9),
                    baseSHA: columnText(statement, 10),
                    branchName: columnText(statement, 11),
                    workspaceID: columnText(statement, 12),
                    workspacePath: columnText(statement, 13),
                    providerPID: columnInt64(statement, 14).map(Int32.init),
                    providerExit: columnInt64(statement, 15).map(Int32.init),
                    patchPath: columnText(statement, 16),
                    logDirectory: columnText(statement, 17),
                    validatedSHA: columnText(statement, 18),
                    remoteBranchSHA: columnText(statement, 19),
                    prNumber: columnInt64(statement, 20).map(Int.init),
                    prURL: columnText(statement, 21),
                    prIsDraft: columnInt64(statement, 22).map { $0 != 0 },
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 23)),
                    claimedAt: columnDouble(statement, 24).map(Date.init(timeIntervalSince1970:)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 25)),
                    finishedAt: columnDouble(statement, 26).map(Date.init(timeIntervalSince1970:))
                )
            )
        }
        try checkStatement(statement)
        return results
    }

    private func currentHostClaimUnlocked() throws -> HostClaim? {
        var statement: OpaquePointer?
        try prepare("SELECT run_id, owner_pid, claimed_at FROM host_claim WHERE singleton_key = 1 AND run_id IS NOT NULL", &statement)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError() }
        return HostClaim(
            runID: columnText(statement, 0)!,
            ownerPID: Int32(sqlite3_column_int64(statement, 1)),
            claimedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        )
    }

    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(immediate: Bool, _ body: () throws -> T) throws -> T {
        try execute(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw sqliteError()
        }
    }

    private func executeScript(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw LedgerError.sqlite(reason)
        }
    }

    private func scalarInt64(_ sql: String, _ bindings: [SQLiteValue]) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String, _ bindings: [SQLiteValue]) throws -> String? {
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func checkStatement(_ statement: OpaquePointer?) throws {
        let result = sqlite3_errcode(database)
        if result != SQLITE_OK && result != SQLITE_DONE && result != SQLITE_ROW {
            throw sqliteError()
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func columnInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func updateArtifacts(
        runID: String,
        assignments: String,
        values: [SQLiteValue],
        event: String,
        detail: String
    ) throws {
        try synchronized {
            try transaction(immediate: true) {
                let run = try fetchRunUnlocked(id: runID)
                guard !run.state.isTerminal else {
                    throw LedgerError.sqlite("terminal run records are immutable")
                }
                try execute(
                    "UPDATE runs SET \(assignments), updated_at = ? WHERE id = ?",
                    values + [.double(Date().timeIntervalSince1970), .text(runID)]
                )
                try insertEvent(
                    runID: runID,
                    kind: event,
                    from: nil,
                    to: nil,
                    detail: detail,
                    at: Date().timeIntervalSince1970
                )
            }
        }
    }

    private func requireStoredPath(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let root = stateRoot.path
        guard path == root || path.hasPrefix(root + "/") else {
            throw LedgerError.sqlite("artifact path is outside state root: \(path)")
        }
    }

    private func sqliteError() -> LedgerError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case double(Double)
    case null

    static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    static func optionalDouble(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.double) ?? .null }
    static func optionalInt64(_ value: Int64?) -> SQLiteValue { value.map(SQLiteValue.integer) ?? .null }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StateDirectory {
    static func ensure(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw LedgerError.sqlite("state root is not a directory: \(path)")
            }
            guard metadata.st_uid == getuid() else {
                throw LedgerError.sqlite("state root is not owned by the current user: \(path)")
            }
            guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw LedgerError.sqlite("state root is group- or world-writable: \(path)")
            }
            return
        }
        guard errno == ENOENT else {
            throw LedgerError.sqlite("cannot inspect state root \(path): \(String(cString: strerror(errno)))")
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if chmod(path, 0o700) != 0 {
                throw LedgerError.sqlite("cannot secure state root \(path): \(String(cString: strerror(errno)))")
            }
        } catch let error as LedgerError {
            throw error
        } catch {
            throw LedgerError.sqlite("cannot create state root \(path): \(error.localizedDescription)")
        }
    }
}
