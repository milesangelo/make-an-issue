import Foundation

public struct RepositoryStore: Equatable, Sendable {
    public let repository: String
    public let path: URL
    public let remote: String
    public let defaultBranch: String
    public let baseSHA: String
}

public struct WorkspaceLease: Equatable, Sendable {
    public let id: String
    public let path: URL
    public let sourceStorePath: URL
    public let proofPath: URL
}

public struct PreparedWorkspace: Equatable, Sendable {
    public let lease: WorkspaceLease
    public let branchName: String
    public let baseSHA: String
}

public struct WorkspaceFacts: Equatable, Sendable {
    public let isClean: Bool
    public let headSHA: String
    public let branchName: String?
}

public struct RetainedWorkspace: Equatable, Sendable {
    public let lease: WorkspaceLease
    public let reason: String
}

public struct PublicationReceipt: Equatable, Sendable {
    public let pushedSHA: String
    public let prNumber: Int
    public let prURL: String
    public let isDraft: Bool
    public let ciStatus: String
}

public enum WorkspaceError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsafePath(String)
    case commandFailed(String)
    case branchExists(String)
    case dirty(String)
    case invalidLease(String)

    public var description: String {
        switch self {
        case .unsafePath(let value): return "unsafe workspace path: \(value)"
        case .commandFailed(let value): return value
        case .branchExists(let value): return "run branch already exists: \(value)"
        case .dirty(let value): return "workspace is dirty: \(value)"
        case .invalidLease(let value): return "invalid workspace lease: \(value)"
        }
    }
}

public protocol WorkspaceManaging: Sendable {
    func acquire(repositoryStore: RepositoryStore, baseSHA: String, runID: String) throws -> WorkspaceLease
    func prepare(lease: WorkspaceLease, branchName: String, baseSHA: String) throws -> PreparedWorkspace
    func inspect(lease: WorkspaceLease) throws -> WorkspaceFacts
    func retain(lease: WorkspaceLease, reason: String, artifacts: [URL]) throws -> RetainedWorkspace
    func releaseCleanPublished(lease: WorkspaceLease, publicationReceipt: PublicationReceipt) throws
    func recover() throws -> [WorkspaceLease]
}

public struct WorkerRepositoryStore: Sendable {
    private let stateRoot: URL
    private let processes: any ProcessExecuting
    private let environment: [String: String]

    public init(
        stateRoot: URL,
        processes: any ProcessExecuting = FoundationProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.processes = processes
        self.environment = environment
    }

    public func fetch(_ repository: RepositoryConfig, remoteOverride: String? = nil) throws -> RepositoryStore {
        let storesRoot = stateRoot.appendingPathComponent("repositories", isDirectory: true)
        try FileManager.default.createDirectory(at: storesRoot, withIntermediateDirectories: true)
        let storePath = storesRoot.appendingPathComponent(repository.repository.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        try requireContained(storePath, within: stateRoot)
        let remote = remoteOverride ?? repository.remote
        if !FileManager.default.fileExists(atPath: storePath.path) {
            try runGit(["clone", "--no-checkout", "--origin", "origin", remote, storePath.path], cwd: storesRoot)
        } else {
            guard FileManager.default.fileExists(atPath: storePath.appendingPathComponent(".git").path) else {
                throw WorkspaceError.invalidLease("managed repository store is not a git checkout")
            }
            let observed = try gitOutput(["remote", "get-url", "origin"], cwd: storePath)
            guard observed == remote else {
                throw WorkspaceError.invalidLease("managed origin changed from configured remote")
            }
        }
        try runGit(
            ["fetch", "--no-tags", "--prune", "origin", "refs/heads/\(repository.defaultBranch):refs/remotes/origin/\(repository.defaultBranch)"],
            cwd: storePath
        )
        let baseSHA = try gitOutput(["rev-parse", "--verify", "refs/remotes/origin/\(repository.defaultBranch)^{commit}"], cwd: storePath)
        return RepositoryStore(
            repository: repository.repository,
            path: storePath.resolvingSymlinksInPath().standardizedFileURL,
            remote: remote,
            defaultBranch: repository.defaultBranch,
            baseSHA: baseSHA
        )
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let result = processes.execute(ProcessRequest(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: cwd,
            environment: environment,
            timeoutSeconds: 300
        ))
        guard result.exitCode == 0 else {
            throw WorkspaceError.commandFailed("git \(arguments.first ?? "") failed: \(concise(result.stderrString))")
        }
    }

    private func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
        let result = processes.execute(ProcessRequest(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: cwd,
            environment: environment,
            timeoutSeconds: 60
        ))
        guard result.exitCode == 0 else {
            throw WorkspaceError.commandFailed("git \(arguments.first ?? "") failed: \(concise(result.stderrString))")
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BuiltinWorkspaceManager: WorkspaceManaging {
    private let stateRoot: URL
    private let processes: any ProcessExecuting
    private let environment: [String: String]

    public init(
        stateRoot: URL,
        processes: any ProcessExecuting = FoundationProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.processes = processes
        self.environment = environment
    }

    public func acquire(repositoryStore: RepositoryStore, baseSHA: String, runID: String) throws -> WorkspaceLease {
        try requireContained(repositoryStore.path, within: stateRoot)
        let workspaces = stateRoot.appendingPathComponent("workspaces", isDirectory: true)
        let path = workspaces.appendingPathComponent(runID, isDirectory: true)
        try requireContained(path, within: stateRoot)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw WorkspaceError.invalidLease("workspace path already exists")
        }
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        try runGit(["worktree", "add", "--detach", path.path, baseSHA], cwd: repositoryStore.path)
        let proof = try writeLeaseProof(runID: runID, path: path, source: repositoryStore.path)
        return WorkspaceLease(
            id: runID,
            path: path.resolvingSymlinksInPath().standardizedFileURL,
            sourceStorePath: repositoryStore.path,
            proofPath: proof
        )
    }

    public func prepare(lease: WorkspaceLease, branchName: String, baseSHA: String) throws -> PreparedWorkspace {
        try validate(lease)
        guard try inspect(lease: lease).isClean else { throw WorkspaceError.dirty(lease.path.path) }
        let local = executeGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"], cwd: lease.path)
        if local.exitCode == 0 { throw WorkspaceError.branchExists(branchName) }
        let remote = executeGit(["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/\(branchName)"], cwd: lease.path)
        if remote.exitCode == 0 { throw WorkspaceError.branchExists(branchName) }
        guard remote.exitCode == 2 else {
            throw WorkspaceError.commandFailed("remote branch probe failed: \(concise(remote.stderrString))")
        }
        try runGit(["switch", "--create", branchName, baseSHA], cwd: lease.path)
        return PreparedWorkspace(lease: lease, branchName: branchName, baseSHA: baseSHA)
    }

    public func inspect(lease: WorkspaceLease) throws -> WorkspaceFacts {
        try validate(lease)
        let status = try gitOutput(["status", "--porcelain=v1", "--untracked-files=all"], cwd: lease.path)
        let head = try gitOutput(["rev-parse", "HEAD"], cwd: lease.path)
        let branchResult = executeGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: lease.path)
        return WorkspaceFacts(
            isClean: status.isEmpty,
            headSHA: head,
            branchName: branchResult.exitCode == 0
                ? branchResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )
    }

    public func retain(lease: WorkspaceLease, reason: String, artifacts: [URL]) throws -> RetainedWorkspace {
        try validate(lease)
        let retainedRoot = stateRoot.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.createDirectory(at: retainedRoot, withIntermediateDirectories: true)
        let record = retainedRoot.appendingPathComponent("\(lease.id).json")
        let object: [String: Any] = [
            "run_id": lease.id,
            "workspace_path": lease.path.path,
            "reason": reason,
            "artifacts": artifacts.map(\.path),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: record, options: .atomic)
        return RetainedWorkspace(lease: lease, reason: reason)
    }

    public func releaseCleanPublished(lease: WorkspaceLease, publicationReceipt: PublicationReceipt) throws {
        try validate(lease)
        guard try inspect(lease: lease).isClean else { throw WorkspaceError.dirty(lease.path.path) }
        try runGit(["worktree", "remove", lease.path.path], cwd: lease.sourceStorePath)
        try? FileManager.default.removeItem(at: lease.proofPath)
    }

    public func recover() throws -> [WorkspaceLease] {
        try readLeaseProofs(stateRoot: stateRoot)
    }

    private func validate(_ lease: WorkspaceLease) throws {
        try requireContained(lease.path, within: stateRoot)
        try requireContained(lease.sourceStorePath, within: stateRoot)
        guard FileManager.default.fileExists(atPath: lease.proofPath.path) else {
            throw WorkspaceError.invalidLease("durable proof is missing")
        }
    }

    private func writeLeaseProof(runID: String, path: URL, source: URL) throws -> URL {
        try makeLeaseProof(stateRoot: stateRoot, runID: runID, path: path, source: source)
    }

    private func executeGit(_ arguments: [String], cwd: URL) -> ProcessExecution {
        processes.execute(ProcessRequest(executable: "/usr/bin/git", arguments: arguments, workingDirectory: cwd, environment: environment))
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let result = executeGit(arguments, cwd: cwd)
        guard result.exitCode == 0 else {
            throw WorkspaceError.commandFailed("git \(arguments.first ?? "") failed: \(concise(result.stderrString))")
        }
    }

    private func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
        let result = executeGit(arguments, cwd: cwd)
        guard result.exitCode == 0 else {
            throw WorkspaceError.commandFailed("git \(arguments.first ?? "") failed: \(concise(result.stderrString))")
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TreehouseWorkspaceManager: WorkspaceManaging {
    private let stateRoot: URL
    private let executable: String
    private let processes: any ProcessExecuting
    private let path: String
    private let supervisorEnvironment: [String: String]

    public init(
        stateRoot: URL,
        executable: String,
        processes: any ProcessExecuting = FoundationProcessExecutor(),
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        supervisorEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.executable = executable
        self.processes = processes
        self.path = path
        self.supervisorEnvironment = supervisorEnvironment
    }

    public func acquire(repositoryStore: RepositoryStore, baseSHA: String, runID: String) throws -> WorkspaceLease {
        try requireContained(repositoryStore.path, within: stateRoot)
        let home = stateRoot.appendingPathComponent("treehouse-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let result = processes.execute(ProcessRequest(
            executable: executable,
            arguments: ["get", "--lease", "--lease-holder", runID],
            workingDirectory: repositoryStore.path,
            environment: try treehouseGitEnvironment(home: home),
            timeoutSeconds: 120
        ))
        guard result.exitCode == 0 else {
            throw WorkspaceError.commandFailed("treehouse get failed: \(concise(result.stderrString))")
        }
        let path = URL(fileURLWithPath: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().standardizedFileURL
        try requireContained(path, within: stateRoot)
        let lease = WorkspaceLease(
            id: runID,
            path: path,
            sourceStorePath: repositoryStore.path,
            proofPath: try makeLeaseProof(stateRoot: stateRoot, runID: runID, path: path, source: repositoryStore.path)
        )
        let builtin = BuiltinWorkspaceManager(stateRoot: stateRoot, processes: processes)
        guard try builtin.inspect(lease: lease).isClean else { throw WorkspaceError.dirty(path.path) }
        let checkout = processes.execute(ProcessRequest(
            executable: "/usr/bin/git",
            arguments: ["checkout", "--detach", baseSHA],
            workingDirectory: path,
            environment: WorkerEnvironment.minimal(home: home, path: self.path)
        ))
        guard checkout.exitCode == 0 else {
            throw WorkspaceError.commandFailed("git checkout detached base failed: \(concise(checkout.stderrString))")
        }
        return lease
    }

    public func prepare(lease: WorkspaceLease, branchName: String, baseSHA: String) throws -> PreparedWorkspace {
        let home = stateRoot.appendingPathComponent("treehouse-home", isDirectory: true)
        return try BuiltinWorkspaceManager(
            stateRoot: stateRoot,
            processes: processes,
            environment: try treehouseGitEnvironment(home: home)
        ).prepare(lease: lease, branchName: branchName, baseSHA: baseSHA)
    }

    public func inspect(lease: WorkspaceLease) throws -> WorkspaceFacts {
        let home = stateRoot.appendingPathComponent("treehouse-home", isDirectory: true)
        return try BuiltinWorkspaceManager(
            stateRoot: stateRoot,
            processes: processes,
            environment: WorkerEnvironment.minimal(home: home, path: path)
        ).inspect(lease: lease)
    }

    public func retain(lease: WorkspaceLease, reason: String, artifacts: [URL]) throws -> RetainedWorkspace {
        try BuiltinWorkspaceManager(stateRoot: stateRoot, processes: processes).retain(lease: lease, reason: reason, artifacts: artifacts)
    }

    public func releaseCleanPublished(lease: WorkspaceLease, publicationReceipt: PublicationReceipt) throws {
        guard try inspect(lease: lease).isClean else { throw WorkspaceError.dirty(lease.path.path) }
        let home = stateRoot.appendingPathComponent("treehouse-home", isDirectory: true)
        let result = processes.execute(ProcessRequest(
            executable: executable,
            arguments: ["return", lease.path.path],
            workingDirectory: lease.sourceStorePath,
            environment: WorkerEnvironment.minimal(home: home, path: path),
            timeoutSeconds: 120
        ))
        guard result.exitCode == 0 else {
            throw WorkspaceError.commandFailed("treehouse return failed: \(concise(result.stderrString))")
        }
        try? FileManager.default.removeItem(at: lease.proofPath)
    }

    public func recover() throws -> [WorkspaceLease] { try readLeaseProofs(stateRoot: stateRoot) }

    /// Treehouse fetches from the worker-owned repository store. Its isolated HOME intentionally
    /// cannot read the user's git credential helper, so supply the GitHub CLI token only to this
    /// supervisor-owned process through Git's ephemeral configuration environment.
    private func treehouseGitEnvironment(home: URL) throws -> [String: String] {
        guard let gh = processes.resolveExecutable("gh", environment: supervisorEnvironment) else {
            throw WorkspaceError.commandFailed(
                "treehouse needs GitHub credentials for a private HTTPS repository; install and authenticate gh with 'gh auth login'"
            )
        }
        let tokenResult = processes.execute(ProcessRequest(
            executable: gh,
            arguments: ["auth", "token"],
            environment: supervisorEnvironment,
            timeoutSeconds: 30
        ))
        let token = tokenResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenResult.exitCode == 0, !token.isEmpty else {
            throw WorkspaceError.commandFailed(
                "treehouse needs GitHub credentials for a private HTTPS repository; run 'gh auth login' and retry"
            )
        }
        return WorkerEnvironment.minimal(home: home, path: path, extra: [
            "MAI_TREEHOUSE_GIT_TOKEN": token,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "credential.helper",
            "GIT_CONFIG_VALUE_0": "!f() { echo username=x-access-token; echo password=\"$MAI_TREEHOUSE_GIT_TOKEN\"; }; f",
        ])
    }
}

private func makeLeaseProof(stateRoot: URL, runID: String, path: URL, source: URL) throws -> URL {
    let leases = stateRoot.appendingPathComponent("leases", isDirectory: true)
    try FileManager.default.createDirectory(at: leases, withIntermediateDirectories: true)
    let proof = leases.appendingPathComponent("\(runID).json")
    let data = try JSONSerialization.data(
        withJSONObject: ["id": runID, "path": path.path, "source": source.path],
        options: [.sortedKeys]
    )
    try data.write(to: proof, options: .atomic)
    return proof
}

private func readLeaseProofs(stateRoot: URL) throws -> [WorkspaceLease] {
    let leases = stateRoot.appendingPathComponent("leases", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(at: leases, includingPropertiesForKeys: nil) else { return [] }
    return try files.filter { $0.pathExtension == "json" }.map { proof in
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: proof)) as? [String: String]
        guard let id = object?["id"], let path = object?["path"], let source = object?["source"] else {
            throw WorkspaceError.invalidLease("malformed proof \(proof.path)")
        }
        return WorkspaceLease(
            id: id,
            path: URL(fileURLWithPath: path).standardizedFileURL,
            sourceStorePath: URL(fileURLWithPath: source).standardizedFileURL,
            proofPath: proof
        )
    }
}

func requireContained(_ candidate: URL, within root: URL) throws {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
        throw WorkspaceError.unsafePath(candidatePath)
    }
}

func concise(_ value: String) -> String {
    value.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown command error"
}
