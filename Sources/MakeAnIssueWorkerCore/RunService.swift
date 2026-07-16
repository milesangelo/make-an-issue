import Foundation

public struct IssueFacts: Equatable, Sendable {
    public let labels: Set<String>
    public let callerHasWriteAccess: Bool
    public let defaultBranch: String
    public let title: String

    public init(labels: Set<String>, callerHasWriteAccess: Bool, defaultBranch: String, title: String = "Issue") {
        self.labels = labels
        self.callerHasWriteAccess = callerHasWriteAccess
        self.defaultBranch = defaultBranch
        self.title = title
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
            arguments: ["issue", "view", issue.url.absoluteString, "--json", "labels,title"]
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
            defaultBranch: repository.defaultBranch,
            title: labels.title
        )
    }

    private func concise(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown gh error"
    }
}

private struct IssueLabelsResponse: Decodable {
    struct Label: Decodable { let name: String }
    let labels: [Label]
    let title: String
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

public struct RunOutcome: Equatable, Sendable {
    public let runID: String
    public let stateReached: RunState
    public let message: String

    public var exitCode: Int32 { stateReached == .prOpened ? 0 : 1 }
}

public struct RunExecutionContext: Sendable {
    public let config: WorkerConfigSnapshot
    public let ledger: RunLedger
    public let run: RunRecord
    public let issue: IssueReference
    public let issueFacts: IssueFacts
    public let repository: RepositoryConfig
    public let agent: AgentConfig
}

public protocol RunExecutionDriving: Sendable {
    func execute(_ context: RunExecutionContext) throws -> RunOutcome
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
    private let executionDriver: (any RunExecutionDriving)?
    private let environment: [String: String]

    public init(
        config: WorkerConfigSnapshot,
        ledger: RunLedger,
        inspector: any IssueInspecting = GHIdentityInspector(),
        routeResolver: RouteResolver = RouteResolver(),
        ownerPID: Int32 = getpid(),
        executionDriver: (any RunExecutionDriving)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.config = config
        self.ledger = ledger
        self.inspector = inspector
        self.routeResolver = routeResolver
        self.ownerPID = ownerPID
        self.executionDriver = executionDriver
        self.environment = environment
    }

    public func run(issueURL: String, agentOverride: String? = nil) throws -> RunOutcome {
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
            let context = RunExecutionContext(
                config: config,
                ledger: ledger,
                run: try ledger.run(id: run.id),
                issue: issue,
                issueFacts: facts,
                repository: repository,
                agent: route.agent
            )
            let driver = executionDriver ?? WorkerRunPipeline(environment: environment)
            return try driver.execute(context)
        } catch {
            if let current = try? ledger.run(id: run.id), !current.state.isTerminal {
                _ = try? ledger.transition(
                    runID: run.id,
                    to: .failed,
                    failureCode: "worker_internal_error_retained",
                    detail: String(describing: error)
                )
            }
            if (try? ledger.currentHostClaim())?.runID == run.id { try? ledger.releaseHostClaim(runID: run.id) }
            throw RunServiceError.ledger(String(describing: error))
        }
    }

    public func reconcilePublishingRuns() throws {
        let publisher = BuiltinPublisher(stateRoot: config.worker.stateRoot, environment: environment)
        for run in try ledger.publishingReconciliationCandidates() {
            do {
                try reconcile(run: run, publisher: publisher)
            } catch {
                try? failReconciliation(run, detail: String(describing: error))
            }
        }
    }

    private func reconcile(run: RunRecord, publisher: BuiltinPublisher) throws {
        if let claim = try ledger.currentHostClaim(), claim.runID == run.id,
           claim.ownerPID != getpid(), kill(claim.ownerPID, 0) == 0 {
            return
        }
        guard let baseSHA = run.baseSHA, let branch = run.branchName,
                  let workspacePath = run.workspacePath, let workspaceID = run.workspaceID,
                  let validatedSHA = run.validatedSHA,
                  let patchPath = run.patchPath else {
                try failReconciliation(run, detail: "publication intent artifacts are incomplete")
                return
            }
            let events = try ledger.events(runID: run.id)
            let frozenConfig: ReconciliationSnapshot
            do {
                frozenConfig = try JSONDecoder().decode(
                    ReconciliationSnapshot.self,
                    from: Data(try ledger.configSnapshot(runID: run.id).utf8)
                )
            } catch {
                try failReconciliation(run, detail: "frozen config snapshot is unavailable: \(error)")
                return
            }
            guard let digest = events.reversed().compactMap({ event -> String? in
                guard event.kind == "diff_inspected", let detail = event.detail,
                      let range = detail.range(of: "digest=") else { return nil }
                return detail[range.upperBound...].split(separator: " ").first.map(String.init)
            }).first,
            let repository = frozenConfig.repositories.first(where: { $0.repository == run.repository }),
            let agent = frozenConfig.agents.first(where: { $0.id == run.agentID }) else {
                try failReconciliation(run, detail: "frozen repository, agent, or diff receipt is unavailable")
                return
            }
            guard frozenConfig.worker.publisherBackend != PublisherBackend.noMistakes.rawValue else {
                try failReconciliation(run, detail: "frozen publisher backend is not capability-compatible")
                return
            }
            let source = config.worker.stateRoot.appendingPathComponent(
                "repositories/\(run.repository.replacingOccurrences(of: "/", with: "--"))"
            )
            let lease = WorkspaceLease(
                id: workspaceID,
                path: URL(fileURLWithPath: workspacePath),
                sourceStorePath: source,
                proofPath: config.worker.stateRoot.appendingPathComponent("leases/\(workspaceID).json")
            )
            let git = GitSupervisor(
                workspace: lease.path,
                branch: branch,
                defaultBranch: repository.defaultBranch,
                environment: environment
            )
            let request = PublicationRequest(
                repository: run.repository,
                issueNumber: run.issueNumber,
                issueTitle: "Issue #\(run.issueNumber)",
                configRevision: run.configRevision,
                validationProfile: agent.validationProfile,
                defaultBranch: repository.defaultBranch,
                branchName: branch,
                baseSHA: baseSHA,
                headSHA: validatedSHA,
                diffDigest: digest,
                git: git
            )
            let receipt = ValidationReceipt(
                id: "reconciled-\(run.id)",
                repository: run.repository,
                configRevision: run.configRevision,
                baseSHA: baseSHA,
                headSHA: validatedSHA,
                diffDigest: digest,
                validationProfile: agent.validationProfile,
                toolVersion: "builtin-v1",
                createdAt: run.updatedAt
            )
            do {
                guard case .opened(let publication) = try publisher.reconcile(
                    PublicationIntent(request: request, validationReceipt: receipt)
                ) else { throw PublisherError.commandFailed("reconciliation did not produce a draft PR") }
                try ledger.recordRemoteBranch(runID: run.id, sha: publication.pushedSHA)
                try ledger.recordPullRequest(
                    runID: run.id,
                    number: publication.prNumber,
                    url: publication.prURL,
                    isDraft: publication.isDraft
                )
                try? ledger.appendObservation(runID: run.id, kind: "ci_status_recorded", detail: publication.ciStatus)
                try? ledger.appendObservation(runID: run.id, kind: "workspace_disposition", detail: "clean_published_release_pending")
                _ = try ledger.transition(runID: run.id, to: .prOpened, detail: "publication reconciled")
                do {
                    guard let backend = WorkspaceBackend(rawValue: frozenConfig.worker.workspaceBackend) else {
                        throw WorkspaceError.commandFailed("frozen workspace backend is invalid")
                    }
                    let manager = try workspaceManager(
                        backend: backend,
                        stateRoot: config.worker.stateRoot,
                        environment: environment
                    )
                    try manager.releaseCleanPublished(lease: lease, publicationReceipt: publication)
                    try? ledger.appendObservation(runID: run.id, kind: "workspace_disposition", detail: "clean_published_released")
                } catch {
                    try? ledger.appendObservation(runID: run.id, kind: "workspace_disposition", detail: "clean_published_release_deferred:\(error)")
                }
                if (try? ledger.currentHostClaim())??.runID == run.id {
                    do { try ledger.releaseHostClaim(runID: run.id) }
                    catch { try? ledger.appendObservation(runID: run.id, kind: "host_release_deferred", detail: String(describing: error)) }
                }
                _ = patchPath
            } catch {
                let backend = WorkspaceBackend(rawValue: frozenConfig.worker.workspaceBackend) ?? .builtin
                _ = try? workspaceManager(
                    backend: backend,
                    stateRoot: config.worker.stateRoot,
                    environment: environment
                ).retain(
                    lease: lease,
                    reason: "publication_reconciliation_failed_retained",
                    artifacts: [URL(fileURLWithPath: patchPath)]
                )
                try failReconciliation(run, detail: String(describing: error))
            }
    }

    private func failReconciliation(_ run: RunRecord, detail: String) throws {
        try ledger.appendObservation(runID: run.id, kind: "workspace_retained", detail: "publication_reconciliation_failed_retained")
        _ = try ledger.transition(
            runID: run.id,
            to: .failed,
            failureCode: "publication_reconciliation_failed_retained",
            detail: detail
        )
        if try ledger.currentHostClaim()?.runID == run.id { try ledger.releaseHostClaim(runID: run.id) }
    }
}

public struct WorkerRunPipeline: RunExecutionDriving {
    private let environment: [String: String]
    private let processes: any ProcessExecuting

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processes: any ProcessExecuting = FoundationProcessExecutor()
    ) {
        self.environment = environment
        self.processes = processes
    }

    public func execute(_ context: RunExecutionContext) throws -> RunOutcome {
        let ledger = context.ledger
        var lease: WorkspaceLease?
        var artifacts: ArtifactStore?
        var manager: (any WorkspaceManaging)?
        do {
            if context.config.worker.publisherBackend == .noMistakes {
                throw PipelineFailure(
                    code: "publisher_capability_unavailable_retained",
                    detail: "no-mistakes publisher remains fail-closed because draft and credential-isolation capabilities are unproven"
                )
            }
            let fixtureEnabled = environment["MAKE_AN_ISSUE_WORKER_ALLOW_TEST_FIXTURES"] == "1"
            let remoteOverride = fixtureEnabled ? environment["MAKE_AN_ISSUE_WORKER_TEST_REMOTE"] : nil
            let store = try WorkerRepositoryStore(
                stateRoot: context.config.worker.stateRoot,
                processes: processes,
                environment: environment
            ).fetch(context.repository, remoteOverride: remoteOverride)
            let branch = BranchPolicy.make(
                issueNumber: context.issue.issueNumber,
                title: context.issueFacts.title,
                runID: context.run.id
            )
            let selectedManager = try workspaceManager(
                config: context.config,
                processes: processes,
                environment: environment
            )
            manager = selectedManager
            let acquired = try selectedManager.acquire(repositoryStore: store, baseSHA: store.baseSHA, runID: context.run.id)
            lease = acquired
            let prepared = try selectedManager.prepare(lease: acquired, branchName: branch, baseSHA: store.baseSHA)
            let artifactStore = try ArtifactStore(stateRoot: context.config.worker.stateRoot, runID: context.run.id)
            artifacts = artifactStore
            try ledger.recordPreparation(
                runID: context.run.id,
                baseSHA: store.baseSHA,
                branchName: branch,
                workspace: acquired,
                artifacts: artifactStore
            )
            _ = try ledger.transition(runID: context.run.id, to: .running)

            let git = GitSupervisor(
                workspace: prepared.lease.path,
                branch: branch,
                defaultBranch: context.repository.defaultBranch,
                processes: processes,
                environment: environment
            )
            let metadata = try git.snapshotMetadata()
            let provider = try runFixtureProvider(
                context: context,
                workspace: prepared.lease.path,
                artifactStore: artifactStore,
                fixtureEnabled: fixtureEnabled
            )
            try ledger.recordProviderExit(runID: context.run.id, pid: nil, exit: provider.exitCode)
            guard provider.exitCode == 0, !provider.timedOut else {
                throw PipelineFailure(code: "provider_failed_retained", detail: concise(provider.stderrString))
            }
            do {
                try git.verifyMetadataUnchanged(from: metadata)
            } catch let error as GitSafetyError {
                throw PipelineFailure(code: "provider_tampered_protected_git_surface_retained", detail: error.description)
            }
            _ = try ledger.transition(runID: context.run.id, to: .validating)

            let inspection: DiffInspection
            do {
                inspection = try DiffInspector(limits: context.config.worker.limits).inspect(git: git, baseSHA: store.baseSHA)
            } catch let error as DiffInspectionError {
                throw PipelineFailure(code: error.failureCode, detail: error.description)
            }
            try artifactStore.archive(inspection)
            try ledger.recordInspection(runID: context.run.id, inspection: inspection)
            let publisher = BuiltinPublisher(
                stateRoot: context.config.worker.stateRoot,
                processes: processes,
                environment: environment
            )
            let validation: ValidationReceipt
            do {
                validation = try publisher.validate(ValidationRequest(
                    repository: context.repository.repository,
                    issueNumber: context.issue.issueNumber,
                    configRevision: context.config.revision,
                    validationProfile: context.agent.validationProfile,
                    baseSHA: store.baseSHA,
                    inspection: inspection,
                    git: git,
                    limits: context.config.worker.limits,
                    artifactStore: artifactStore,
                    timeoutSeconds: context.config.worker.runTimeoutSeconds
                ))
            } catch let error as PublisherError {
                throw PipelineFailure(code: "validation_failed_retained", detail: error.description)
            }
            try ledger.recordValidatedSHA(runID: context.run.id, sha: validation.headSHA, receiptID: validation.id)
            let publicationRequest = PublicationRequest(
                repository: context.repository.repository,
                issueNumber: context.issue.issueNumber,
                issueTitle: context.issueFacts.title,
                configRevision: context.config.revision,
                validationProfile: context.agent.validationProfile,
                defaultBranch: context.repository.defaultBranch,
                branchName: branch,
                baseSHA: store.baseSHA,
                headSHA: validation.headSHA,
                diffDigest: inspection.digest,
                git: git
            )
            try ledger.recordPublicationIntent(
                runID: context.run.id,
                branch: branch,
                baseSHA: store.baseSHA,
                headSHA: validation.headSHA
            )
            _ = try ledger.transition(runID: context.run.id, to: .publishing)
            let publication: PublicationReceipt
            do {
                publication = try publisher.publish(publicationRequest, receipt: validation, draft: true)
            } catch let error as PublisherError {
                throw PipelineFailure(code: "publication_failed_retained", detail: error.description)
            }
            try ledger.recordRemoteBranch(runID: context.run.id, sha: publication.pushedSHA)
            try ledger.recordPullRequest(
                runID: context.run.id,
                number: publication.prNumber,
                url: publication.prURL,
                isDraft: publication.isDraft
            )
            try? ledger.appendObservation(runID: context.run.id, kind: "ci_status_recorded", detail: publication.ciStatus)
            try? ledger.appendObservation(runID: context.run.id, kind: "workspace_disposition", detail: "clean_published_release_pending")
            _ = try ledger.transition(runID: context.run.id, to: .prOpened)
            do {
                try selectedManager.releaseCleanPublished(lease: acquired, publicationReceipt: publication)
                try? ledger.appendObservation(runID: context.run.id, kind: "workspace_disposition", detail: "clean_published_released")
            } catch {
                try? ledger.appendObservation(
                    runID: context.run.id,
                    kind: "workspace_disposition",
                    detail: "clean_published_release_deferred:\(error)"
                )
            }
            do { try ledger.releaseHostClaim(runID: context.run.id) }
            catch {
                try? ledger.appendObservation(
                    runID: context.run.id,
                    kind: "host_release_deferred",
                    detail: String(describing: error)
                )
            }
            return RunOutcome(
                runID: context.run.id,
                stateReached: .prOpened,
                message: "draft PR #\(publication.prNumber) opened: \(publication.prURL)"
            )
        } catch let failure as PipelineFailure {
            return try retainFailure(
                context: context,
                failure: failure,
                manager: manager,
                lease: lease,
                artifacts: artifacts
            )
        } catch {
            return try retainFailure(
                context: context,
                failure: PipelineFailure(code: "worker_internal_error_retained", detail: String(describing: error)),
                manager: manager,
                lease: lease,
                artifacts: artifacts
            )
        }
    }

    private func runFixtureProvider(
        context: RunExecutionContext,
        workspace: URL,
        artifactStore: ArtifactStore,
        fixtureEnabled: Bool
    ) throws -> ProcessExecution {
        guard fixtureEnabled, let executable = environment["MAKE_AN_ISSUE_WORKER_TEST_PROVIDER"] else {
            throw PipelineFailure(
                code: "provider_adapter_not_implemented_retained",
                detail: "real provider adapters land in the next slice; no test fixture provider was enabled"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw PipelineFailure(code: "provider_launch_failed_retained", detail: "fixture provider is not executable")
        }
        let home = context.config.worker.stateRoot.appendingPathComponent("provider-home/\(context.run.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let execution = processes.execute(ProcessRequest(
            executable: executable,
            arguments: [],
            workingDirectory: workspace,
            environment: WorkerEnvironment.minimal(
                home: home,
                extra: [
                    "MAI_WORKSPACE": workspace.path,
                    "MAI_ISSUE_NUMBER": String(context.issue.issueNumber),
                ]
            ),
            timeoutSeconds: min(context.config.worker.runTimeoutSeconds, context.config.provider(id: context.agent.provider)?.timeoutSeconds ?? 300),
            terminationGraceSeconds: context.config.worker.providerGraceSeconds,
            maximumOutputBytes: context.config.worker.limits.maxLogBytes
        ))
        try artifactStore.writeLog(name: "provider", execution: execution)
        return execution
    }

    private func retainFailure(
        context: RunExecutionContext,
        failure: PipelineFailure,
        manager: (any WorkspaceManaging)?,
        lease: WorkspaceLease?,
        artifacts: ArtifactStore?
    ) throws -> RunOutcome {
        if let manager, let lease {
            if let artifacts,
               let run = try? context.ledger.run(id: context.run.id),
               let base = run.baseSHA,
               let branch = run.branchName {
                let git = GitSupervisor(
                    workspace: lease.path,
                    branch: branch,
                    defaultBranch: context.repository.defaultBranch,
                    processes: processes,
                    environment: environment
                )
                if let inspection = try? DiffInspector(limits: context.config.worker.limits).inspect(git: git, baseSHA: base) {
                    try? artifacts.archive(inspection)
                    try? context.ledger.recordInspection(runID: context.run.id, inspection: inspection)
                }
            }
            _ = try? manager.retain(
                lease: lease,
                reason: failure.code,
                artifacts: [artifacts?.patchURL, artifacts?.logDirectory].compactMap { $0 }
            )
            try? context.ledger.appendObservation(
                runID: context.run.id,
                kind: "workspace_disposition",
                detail: "retained:\(failure.code)"
            )
        }
        let current = try context.ledger.run(id: context.run.id)
        if !current.state.isTerminal {
            _ = try context.ledger.transition(
                runID: context.run.id,
                to: .failed,
                failureCode: failure.code,
                detail: failure.detail
            )
        }
        if try context.ledger.currentHostClaim()?.runID == context.run.id {
            try context.ledger.releaseHostClaim(runID: context.run.id)
        }
        return RunOutcome(
            runID: context.run.id,
            stateReached: .failed,
            message: "run failed with \(failure.code); workspace retained"
        )
    }
}

private struct PipelineFailure: Error {
    let code: String
    let detail: String
}

private struct ReconciliationSnapshot: Decodable {
    struct Worker: Decodable {
        let workspaceBackend: String
        let publisherBackend: String

        enum CodingKeys: String, CodingKey {
            case workspaceBackend = "workspace_backend"
            case publisherBackend = "publisher_backend"
        }
    }

    struct Agent: Decodable {
        let id: String
        let validationProfile: String

        enum CodingKeys: String, CodingKey {
            case id
            case validationProfile = "validation_profile"
        }
    }

    struct Repository: Decodable {
        let repository: String
        let defaultBranch: String

        enum CodingKeys: String, CodingKey {
            case repository
            case defaultBranch = "default_branch"
        }
    }

    let worker: Worker
    let agents: [Agent]
    let repositories: [Repository]
}

private func workspaceManager(
    config: WorkerConfigSnapshot,
    processes: any ProcessExecuting = FoundationProcessExecutor(),
    environment: [String: String]
) throws -> any WorkspaceManaging {
    try workspaceManager(
        backend: config.worker.workspaceBackend,
        stateRoot: config.worker.stateRoot,
        processes: processes,
        environment: environment
    )
}

private func workspaceManager(
    backend: WorkspaceBackend,
    stateRoot: URL,
    processes: any ProcessExecuting = FoundationProcessExecutor(),
    environment: [String: String]
) throws -> any WorkspaceManaging {
    switch backend {
    case .builtin:
        return BuiltinWorkspaceManager(
            stateRoot: stateRoot,
            processes: processes,
            environment: environment
        )
    case .treehouse:
        guard let executable = processes.resolveExecutable("treehouse", environment: environment) else {
            throw WorkspaceError.commandFailed("treehouse is selected but unavailable")
        }
        return TreehouseWorkspaceManager(
            stateRoot: stateRoot,
            executable: executable,
            processes: processes,
            path: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        )
    }
}
