import Foundation

public struct PublisherCapabilities: Equatable, Sendable {
    public let draftCreation: Bool
    public let prePushValidation: Bool
    public let tokenIsolation: Bool
    public let noForce: Bool
    public let artifactExport: Bool
    public let startupReconciliation: Bool

    public var satisfiesContract: Bool {
        draftCreation && prePushValidation && tokenIsolation && noForce && artifactExport && startupReconciliation
    }
}

public struct ValidationReceipt: Equatable, Sendable {
    public let id: String
    public let repository: String
    public let configRevision: String
    public let baseSHA: String
    public let headSHA: String
    public let diffDigest: String
    public let validationProfile: String
    public let toolVersion: String
    public let createdAt: Date
}

public struct ValidationRequest: Sendable {
    public let repository: String
    public let issueNumber: Int
    public let configRevision: String
    public let validationProfile: String
    public let baseSHA: String
    public let inspection: DiffInspection
    public let git: GitSupervisor
    public let limits: WorkerLimits
    public let artifactStore: ArtifactStore
    public let timeoutSeconds: Int
}

public struct PublicationRequest: Sendable {
    public let repository: String
    public let issueNumber: Int
    public let issueTitle: String
    public let configRevision: String
    public let validationProfile: String
    public let defaultBranch: String
    public let branchName: String
    public let baseSHA: String
    public let headSHA: String
    public let diffDigest: String
    public let git: GitSupervisor
}

public struct PublicationIntent: Sendable {
    public let request: PublicationRequest
    public let validationReceipt: ValidationReceipt
}

public enum PublicationStatus: Equatable, Sendable {
    case absent
    case remoteBranch(String)
    case opened(PublicationReceipt)
}

public struct PublisherArtifacts: Equatable, Sendable {
    public let paths: [URL]
}

public enum PublisherError: Error, Equatable, CustomStringConvertible, Sendable {
    case validationFailed(String)
    case staleReceipt
    case draftRequired
    case ghUnavailable
    case commandFailed(String)
    case remoteDivergence(expected: String, observed: String)
    case multiplePullRequests
    case nonDraftPullRequest(Int)
    case pullRequestHeadMismatch(expected: String, observed: String)

    public var description: String {
        switch self {
        case .validationFailed(let detail): return "validation failed: \(detail)"
        case .staleReceipt: return "validation receipt does not match publication request"
        case .draftRequired: return "publisher requires draft=true"
        case .ghUnavailable: return "gh is unavailable"
        case .commandFailed(let detail): return detail
        case .remoteDivergence(let expected, let observed): return "remote branch diverged: expected \(expected), observed \(observed)"
        case .multiplePullRequests: return "multiple pull requests match the exact run branch"
        case .nonDraftPullRequest(let number): return "pull request #\(number) is not draft; human correction required"
        case .pullRequestHeadMismatch(let expected, let observed): return "pull request head mismatch: expected \(expected), observed \(observed)"
        }
    }
}

public protocol Publisher: Sendable {
    func capabilities() -> PublisherCapabilities
    func validate(_ request: ValidationRequest) throws -> ValidationReceipt
    func publish(_ request: PublicationRequest, receipt: ValidationReceipt, draft: Bool) throws -> PublicationReceipt
    func reconcile(_ intent: PublicationIntent) throws -> PublicationStatus
    func collectArtifacts(runID: String) throws -> PublisherArtifacts
}

public struct BuiltinPublisher: Publisher {
    private let stateRoot: URL
    private let processes: any ProcessExecuting
    private let supervisorEnvironment: [String: String]

    public init(
        stateRoot: URL,
        processes: any ProcessExecuting = FoundationProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.stateRoot = stateRoot
        self.processes = processes
        supervisorEnvironment = environment
    }

    public func capabilities() -> PublisherCapabilities {
        PublisherCapabilities(
            draftCreation: true,
            prePushValidation: true,
            tokenIsolation: true,
            noForce: true,
            artifactExport: true,
            startupReconciliation: true
        )
    }

    public func validate(_ request: ValidationRequest) throws -> ValidationReceipt {
        let commands = try ValidationProfileRegistry.commands(named: request.validationProfile)
        let home = stateRoot.appendingPathComponent("validation-home/\(request.inspection.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let validationEnvironment = WorkerEnvironment.minimal(home: home)
        for (index, command) in commands.enumerated() {
            let execution = processes.execute(ProcessRequest(
                executable: command.executable,
                arguments: command.arguments,
                workingDirectory: request.git.workspace,
                environment: validationEnvironment,
                timeoutSeconds: min(request.timeoutSeconds, command.timeoutSeconds),
                maximumOutputBytes: request.limits.maxLogBytes
            ))
            try request.artifactStore.writeLog(name: "validation-\(index + 1)", execution: execution)
            guard execution.exitCode == 0, !execution.timedOut else {
                throw PublisherError.validationFailed(concise(execution.stderrString))
            }
        }

        let reinspected = try DiffInspector(limits: request.limits).inspect(git: request.git, baseSHA: request.baseSHA)
        guard reinspected.digest == request.inspection.digest else {
            throw PublisherError.validationFailed("workspace changed during validation")
        }
        let headSHA = try request.git.commit(issueNumber: request.issueNumber)
        return ValidationReceipt(
            id: UUID().uuidString.lowercased(),
            repository: request.repository,
            configRevision: request.configRevision,
            baseSHA: request.baseSHA,
            headSHA: headSHA,
            diffDigest: request.inspection.digest,
            validationProfile: request.validationProfile,
            toolVersion: "builtin-v1",
            createdAt: Date()
        )
    }

    public func publish(
        _ request: PublicationRequest,
        receipt: ValidationReceipt,
        draft: Bool
    ) throws -> PublicationReceipt {
        guard draft else { throw PublisherError.draftRequired }
        try verify(receipt: receipt, request: request)
        _ = try request.git.pushFreshBranch(expectedSHA: request.headSHA)
        return try createOrVerifyPullRequest(request, draft: true)
    }

    public func reconcile(_ intent: PublicationIntent) throws -> PublicationStatus {
        try verify(receipt: intent.validationReceipt, request: intent.request)
        if let remoteSHA = try intent.request.git.remoteBranchSHA() {
            guard remoteSHA == intent.request.headSHA else {
                throw PublisherError.remoteDivergence(expected: intent.request.headSHA, observed: remoteSHA)
            }
            if let existing = try matchingPullRequest(intent.request) {
                return .opened(try verifyPullRequest(existing, request: intent.request))
            }
            return .opened(try createOrVerifyPullRequest(intent.request, draft: true))
        }
        guard try intent.request.git.currentHead() == intent.request.headSHA else {
            throw PublisherError.commandFailed("validated local publication artifacts are unavailable")
        }
        _ = try intent.request.git.pushFreshBranch(expectedSHA: intent.request.headSHA)
        return .opened(try createOrVerifyPullRequest(intent.request, draft: true))
    }

    public func collectArtifacts(runID: String) throws -> PublisherArtifacts {
        let root = stateRoot.appendingPathComponent("artifacts/\(runID)")
        try requireContained(root, within: stateRoot)
        let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return PublisherArtifacts(paths: paths)
    }

    private func verify(receipt: ValidationReceipt, request: PublicationRequest) throws {
        guard receipt.repository == request.repository,
              receipt.configRevision == request.configRevision,
              receipt.baseSHA == request.baseSHA,
              receipt.headSHA == request.headSHA,
              receipt.diffDigest == request.diffDigest,
              receipt.validationProfile == request.validationProfile else {
            throw PublisherError.staleReceipt
        }
    }

    private func createOrVerifyPullRequest(_ request: PublicationRequest, draft: Bool) throws -> PublicationReceipt {
        guard draft else { throw PublisherError.draftRequired }
        if let existing = try matchingPullRequest(request) {
            return try verifyPullRequest(existing, request: request)
        }
        let gh = try ghExecutable()
        let title = "Address #\(request.issueNumber): \(sanitizedTitle(request.issueTitle))"
        let body = "Closes #\(request.issueNumber)\n\nCreated by make-an-issue-worker."
        let create = processes.execute(ProcessRequest(
            executable: gh,
            arguments: [
                "pr", "create", "--repo", request.repository,
                "--head", request.branchName, "--base", request.defaultBranch,
                "--draft", "--title", title, "--body", body,
            ],
            environment: supervisorEnvironment,
            timeoutSeconds: 120
        ))
        guard create.exitCode == 0 else {
            throw PublisherError.commandFailed("draft PR creation failed: \(concise(create.stderrString))")
        }
        guard let created = try matchingPullRequest(request) else {
            throw PublisherError.commandFailed("created pull request could not be read back")
        }
        return try verifyPullRequest(created, request: request)
    }

    private func matchingPullRequest(_ request: PublicationRequest) throws -> PullRequestObservation? {
        let gh = try ghExecutable()
        let result = processes.execute(ProcessRequest(
            executable: gh,
            arguments: [
                "pr", "list", "--repo", request.repository, "--head", request.branchName,
                "--state", "all", "--json", "number,url,isDraft,headRefOid",
            ],
            environment: supervisorEnvironment,
            timeoutSeconds: 60
        ))
        guard result.exitCode == 0 else {
            throw PublisherError.commandFailed("pull request reconciliation query failed: \(concise(result.stderrString))")
        }
        let observations: [PullRequestObservation]
        do {
            observations = try JSONDecoder().decode([PullRequestObservation].self, from: result.stdout)
        } catch {
            throw PublisherError.commandFailed("invalid pull request reconciliation response")
        }
        guard observations.count <= 1 else { throw PublisherError.multiplePullRequests }
        return observations.first
    }

    private func verifyPullRequest(
        _ observation: PullRequestObservation,
        request: PublicationRequest
    ) throws -> PublicationReceipt {
        guard observation.isDraft else { throw PublisherError.nonDraftPullRequest(observation.number) }
        guard observation.headRefOID == request.headSHA else {
            throw PublisherError.pullRequestHeadMismatch(expected: request.headSHA, observed: observation.headRefOID)
        }
        let ciStatus = observeCI(repository: request.repository, number: observation.number)
        return PublicationReceipt(
            pushedSHA: request.headSHA,
            prNumber: observation.number,
            prURL: observation.url,
            isDraft: true,
            ciStatus: ciStatus
        )
    }

    private func observeCI(repository: String, number: Int) -> String {
        guard let gh = try? ghExecutable() else { return "unknown" }
        let result = processes.execute(ProcessRequest(
            executable: gh,
            arguments: ["pr", "checks", String(number), "--repo", repository, "--json", "state"],
            environment: supervisorEnvironment,
            timeoutSeconds: 60
        ))
        if result.timedOut || result.exitCode == -1 {
            return "unknown"
        }
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return result.stderrString.range(of: "no checks reported", options: .caseInsensitive) != nil
                ? "none"
                : "unknown"
        }
        guard let checks = try? JSONDecoder().decode([CICheckObservation].self, from: result.stdout) else {
            return "unknown"
        }
        return classifyCI(checks.map { $0.state.uppercased() })
    }

    private func classifyCI(_ states: [String]) -> String {
        if states.isEmpty { return "none" }
        let failing: Set<String> = [
            "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE",
        ]
        let passing: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]
        if states.contains(where: failing.contains) { return "failing" }
        if states.allSatisfy(passing.contains) { return "passing" }
        return "pending"
    }

    private func ghExecutable() throws -> String {
        guard let gh = processes.resolveExecutable("gh", environment: supervisorEnvironment) else {
            throw PublisherError.ghUnavailable
        }
        return gh
    }

    private func sanitizedTitle(_ title: String) -> String {
        let singleLine = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(160))
    }
}

private struct PullRequestObservation: Decodable {
    let number: Int
    let url: String
    let isDraft: Bool
    let headRefOID: String

    enum CodingKeys: String, CodingKey {
        case number, url, isDraft
        case headRefOID = "headRefOid"
    }
}

private struct CICheckObservation: Decodable {
    let state: String

    enum CodingKeys: String, CodingKey { case state }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? container.decode(String.self, forKey: .state)) ?? ""
    }
}

private struct ValidationCommand: Sendable {
    let executable: String
    let arguments: [String]
    let timeoutSeconds: Int
}

private enum ValidationProfileRegistry {
    static func commands(named name: String) throws -> [ValidationCommand] {
        switch name {
        case "default", "spike":
            return [ValidationCommand(executable: "/usr/bin/git", arguments: ["diff", "--cached", "--check"], timeoutSeconds: 300)]
        default:
            throw PublisherError.validationFailed("unknown validation profile \(name)")
        }
    }
}
