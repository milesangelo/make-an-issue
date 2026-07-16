import Foundation

public struct IssueFacts: Equatable, Sendable {
    public let labels: Set<String>
    public let callerHasWriteAccess: Bool
    public let defaultBranch: String

    public init(labels: Set<String>, callerHasWriteAccess: Bool, defaultBranch: String) {
        self.labels = labels
        self.callerHasWriteAccess = callerHasWriteAccess
        self.defaultBranch = defaultBranch
    }
}

public protocol IssueInspecting: Sendable {
    func inspect(_ issue: IssueReference) throws -> IssueFacts
}

public enum IssueInspectionError: Error, Equatable, CustomStringConvertible, Sendable {
    case ghUnavailable
    case commandFailed(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .ghUnavailable: return "gh is not available on PATH"
        case .commandFailed(let detail): return "GitHub inspection failed: \(detail)"
        case .invalidResponse(let detail): return "GitHub inspection returned invalid data: \(detail)"
        }
    }
}

public struct GHIdentityInspector: IssueInspecting {
    private let commands: any CommandRunning

    public init(commands: any CommandRunning = ProcessCommandRunner()) {
        self.commands = commands
    }

    public func inspect(_ issue: IssueReference) throws -> IssueFacts {
        guard let gh = commands.resolveExecutable("gh") else { throw IssueInspectionError.ghUnavailable }
        let issueResult = commands.run(
            executable: gh,
            arguments: ["issue", "view", issue.url.absoluteString, "--json", "labels"]
        )
        guard issueResult.exitCode == 0 else {
            throw IssueInspectionError.commandFailed(concise(issueResult.stderr))
        }
        let labels: IssueLabelsResponse
        do {
            labels = try JSONDecoder().decode(IssueLabelsResponse.self, from: Data(issueResult.stdout.utf8))
        } catch {
            throw IssueInspectionError.invalidResponse("issue labels: \(error.localizedDescription)")
        }

        let repositoryResult = commands.run(
            executable: gh,
            arguments: ["api", "repos/\(issue.repository)"]
        )
        guard repositoryResult.exitCode == 0 else {
            throw IssueInspectionError.commandFailed(concise(repositoryResult.stderr))
        }
        let repository: RepositoryPermissionResponse
        do {
            repository = try JSONDecoder().decode(
                RepositoryPermissionResponse.self,
                from: Data(repositoryResult.stdout.utf8)
            )
        } catch {
            throw IssueInspectionError.invalidResponse("repository permission/default branch: \(error.localizedDescription)")
        }
        let permission = repository.permissions
        return IssueFacts(
            labels: Set(labels.labels.map(\.name)),
            callerHasWriteAccess: permission.admin || permission.maintain || permission.push,
            defaultBranch: repository.defaultBranch
        )
    }

    private func concise(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown gh error"
    }
}

private struct IssueLabelsResponse: Decodable {
    struct Label: Decodable { let name: String }
    let labels: [Label]
}

private struct RepositoryPermissionResponse: Decodable {
    struct Permissions: Decodable {
        let admin: Bool
        let maintain: Bool
        let push: Bool
    }

    let defaultBranch: String
    let permissions: Permissions

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
        case permissions
    }
}

public struct StubRunOutcome: Equatable, Sendable {
    public static let exitCode: Int32 = 3
    public static let failureCode = "publisher_slice_not_implemented"

    public let runID: String
    public let stateReached: RunState
    public let message: String
}

public enum RunServiceError: Error, CustomStringConvertible, Sendable {
    case untrustedCaller(String)
    case defaultBranchMismatch(expected: String, observed: String)
    case activeRunExists(String)
    case hostBusy(String)
    case routing(String)
    case ledger(String)
    case inspection(String)

    public var description: String {
        switch self {
        case .untrustedCaller(let repository): return "authenticated GitHub user lacks WRITE, MAINTAIN, or ADMIN permission on \(repository)"
        case .defaultBranchMismatch(let expected, let observed): return "configured default branch \(expected) does not match GitHub default branch \(observed)"
        case .activeRunExists(let id): return "issue already has non-terminal run \(id)"
        case .hostBusy(let detail): return detail
        case .routing(let detail): return detail
        case .ledger(let detail): return detail
        case .inspection(let detail): return detail
        }
    }
}

public struct RunService: Sendable {
    private let config: WorkerConfigSnapshot
    private let ledger: RunLedger
    private let inspector: any IssueInspecting
    private let routeResolver: RouteResolver
    private let ownerPID: Int32

    public init(
        config: WorkerConfigSnapshot,
        ledger: RunLedger,
        inspector: any IssueInspecting = GHIdentityInspector(),
        routeResolver: RouteResolver = RouteResolver(),
        ownerPID: Int32 = getpid()
    ) {
        self.config = config
        self.ledger = ledger
        self.inspector = inspector
        self.routeResolver = routeResolver
        self.ownerPID = ownerPID
    }

    public func run(issueURL: String, agentOverride: String? = nil) throws -> StubRunOutcome {
        let issue: IssueReference
        let repository: RepositoryConfig
        do {
            issue = try IssueReference.parse(issueURL)
            repository = try routeResolver.configuredRepository(for: issue, config: config)
        } catch {
            throw RunServiceError.routing(String(describing: error))
        }

        let facts: IssueFacts
        do {
            facts = try inspector.inspect(issue)
        } catch {
            throw RunServiceError.inspection(String(describing: error))
        }
        guard facts.callerHasWriteAccess else {
            throw RunServiceError.untrustedCaller(repository.repository)
        }
        guard facts.defaultBranch == repository.defaultBranch else {
            throw RunServiceError.defaultBranchMismatch(
                expected: repository.defaultBranch,
                observed: facts.defaultBranch
            )
        }

        let route: ResolvedRoute
        do {
            route = try routeResolver.resolve(
                repository: repository,
                labels: facts.labels,
                agentOverride: agentOverride,
                config: config
            )
        } catch {
            throw RunServiceError.routing(String(describing: error))
        }

        let insertion: RunInsertion
        do {
            insertion = try ledger.createRun(
                NewRun(
                    issue: issue,
                    configRevision: config.revision,
                    redactedConfigSnapshot: config.redactedSnapshot,
                    routeID: route.routeID,
                    agentID: route.agent.id,
                    triggerKind: .cli
                )
            )
        } catch {
            throw RunServiceError.ledger(String(describing: error))
        }
        let run: RunRecord
        switch insertion {
        case .created(let created): run = created
        case .existing(let existing): throw RunServiceError.activeRunExists(existing.id)
        }

        do {
            _ = try ledger.claimHost(runID: run.id, ownerPID: ownerPID)
        } catch let error as LedgerError {
            let busy: Bool
            if case .hostAlreadyClaimed = error { busy = true } else { busy = false }
            _ = try? ledger.transition(
                runID: run.id,
                to: .failed,
                failureCode: busy ? "host_busy" : "ledger_error",
                detail: error.description
            )
            if busy { throw RunServiceError.hostBusy(error.description) }
            throw RunServiceError.ledger(error.description)
        } catch {
            let detail = String(describing: error)
            _ = try? ledger.transition(
                runID: run.id,
                to: .failed,
                failureCode: "ledger_error",
                detail: detail
            )
            throw RunServiceError.ledger(detail)
        }

        do {
            _ = try ledger.transition(runID: run.id, to: .claimed)
            _ = try ledger.transition(
                runID: run.id,
                to: .preparing,
                detail: "repository identity, caller trust, default branch, and route verified"
            )
            _ = try ledger.transition(
                runID: run.id,
                to: .failed,
                failureCode: StubRunOutcome.failureCode,
                detail: "publisher slice not yet implemented; no workspace, provider, git, or publication action was attempted"
            )
            try ledger.releaseHostClaim(runID: run.id)
        } catch {
            _ = try? ledger.transition(
                runID: run.id,
                to: .failed,
                failureCode: "ledger_error",
                detail: String(describing: error)
            )
            try? ledger.releaseHostClaim(runID: run.id)
            throw RunServiceError.ledger(String(describing: error))
        }

        return StubRunOutcome(
            runID: run.id,
            stateReached: .preparing,
            message: "run \(run.id) reached preparing; publisher slice not yet implemented (recorded as \(StubRunOutcome.failureCode))"
        )
    }
}
