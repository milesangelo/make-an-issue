import CryptoKit
import Darwin
import Foundation
import TOML

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case codexOSS = "codex-oss"

    public var hasRuntimeAdapter: Bool {
        switch self {
        case .claudeCode: return true
        case .codex, .codexOSS: return false
        }
    }
}

public enum WorkspaceBackend: String, Codable, Sendable {
    case treehouse
    case builtin
}

public enum PublisherBackend: String, Codable, Sendable {
    case auto
    case noMistakes = "no-mistakes"
    case builtin
}

public struct WorkerLimits: Equatable, Sendable {
    public let maxLogBytes: Int
    public let maxWorkspaceBytes: Int
    public let maxChangedFiles: Int
    public let maxDiffBytes: Int
    public let maxSingleFileBytes: Int
    public let allowBinaryFiles: Bool
}

public struct WorkerSettings: Equatable, Sendable {
    public let pollIntervalSeconds: Int
    public let maxConcurrentRuns: Int
    public let runTimeoutSeconds: Int
    public let providerGraceSeconds: Int
    public let stateRoot: URL
    public let workspaceBackend: WorkspaceBackend
    public let publisherBackend: PublisherBackend
    public let limits: WorkerLimits
}

public struct ExecutableIdentity: Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modificationTime: Int64
    public let codeSignatureVerified: Bool
}

public struct ProviderConfig: Equatable, Sendable {
    public let id: String
    public let kind: ProviderKind
    public let executable: URL
    public let argv: [String]
    public let timeoutSeconds: Int
    public let executableIdentity: ExecutableIdentity
}

public struct AgentConfig: Equatable, Sendable {
    public let id: String
    public let provider: String
    public let instructionsFile: URL
    public let instructions: String
    public let instructionsSHA256: String
    public let validationProfile: String
}

public struct RouteConfig: Equatable, Sendable {
    public let id: String
    public let priority: Int
    public let labelsAll: [String]
    public let labelsAny: [String]
    public let agent: String

    public func matches(labels: Set<String>) -> Bool {
        Set(labelsAll).isSubset(of: labels)
            && (labelsAny.isEmpty || !Set(labelsAny).isDisjoint(with: labels))
    }
}

public struct RepositoryConfig: Equatable, Sendable {
    public let repository: String
    public let enabled: Bool
    public let defaultBranch: String
    public let remote: String
    public let routeIDs: [String]
}

public struct WorkerConfigSnapshot: Sendable {
    public static let supportedSchemaVersion = 1

    public let sourceURL: URL
    public let schemaVersion: Int
    public let revision: String
    public let worker: WorkerSettings
    public let providers: [ProviderConfig]
    public let agents: [AgentConfig]
    public let routes: [RouteConfig]
    public let repositories: [RepositoryConfig]
    public let redactedSnapshot: String

    public func provider(id: String) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    public func agent(id: String) -> AgentConfig? {
        agents.first { $0.id == id }
    }

    public func route(id: String) -> RouteConfig? {
        routes.first { $0.id == id }
    }

    public func repository(slug: String) -> RepositoryConfig? {
        repositories.first { $0.repository == slug }
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    public let file: String
    public let key: String
    public let reason: String

    public init(file: String, key: String, reason: String) {
        self.file = file
        self.key = key
        self.reason = reason
    }

    public var description: String {
        "\(file): \(key): \(reason)"
    }
}

private struct SchemaDecodeError: Error, CustomStringConvertible {
    let key: String
    let reason: String

    var description: String { "\(key): \(reason)" }
}

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct StrictTable {
    private let container: KeyedDecodingContainer<AnyCodingKey>
    private let path: String

    init(_ decoder: Decoder, path: String, allowed: Set<String>) throws {
        container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.path = path
        if let unknown = container.allKeys.map(\.stringValue).first(where: { !allowed.contains($0) }) {
            throw SchemaDecodeError(key: path.isEmpty ? unknown : "\(path).\(unknown)", reason: "unknown key")
        }
    }

    func required<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        do {
            return try container.decode(type, forKey: AnyCodingKey(key))
        } catch let error as SchemaDecodeError {
            throw error
        } catch DecodingError.keyNotFound {
            throw SchemaDecodeError(key: qualified(key), reason: "required key is missing")
        } catch {
            throw SchemaDecodeError(key: qualified(key), reason: "invalid value: \(error)")
        }
    }

    func optional<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        do {
            return try container.decodeIfPresent(type, forKey: AnyCodingKey(key))
        } catch let error as SchemaDecodeError {
            throw error
        } catch {
            throw SchemaDecodeError(key: qualified(key), reason: "invalid value: \(error)")
        }
    }

    private func qualified(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}

private struct RawConfig: Decodable {
    let schemaVersion: Int
    let worker: RawWorker
    let providers: [RawProvider]
    let agents: [RawAgent]
    let routes: [RawRoute]
    let repositories: [RawRepository]

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "",
            allowed: ["schema_version", "worker", "providers", "agents", "routes", "repositories"]
        )
        schemaVersion = try table.required(Int.self, "schema_version")
        worker = try table.required(RawWorker.self, "worker")
        providers = try table.required([RawProvider].self, "providers")
        agents = try table.required([RawAgent].self, "agents")
        routes = try table.required([RawRoute].self, "routes")
        repositories = try table.required([RawRepository].self, "repositories")
    }
}

private struct RawWorker: Decodable {
    let pollIntervalSeconds: Int
    let maxConcurrentRuns: Int
    let runTimeoutSeconds: Int
    let providerGraceSeconds: Int
    let stateRoot: String
    let workspaceBackend: String
    let publisherBackend: String
    let limits: RawLimits

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "worker",
            allowed: [
                "poll_interval_seconds", "max_concurrent_runs", "run_timeout_seconds",
                "provider_grace_seconds", "state_root", "workspace_backend", "publisher_backend", "limits",
            ]
        )
        pollIntervalSeconds = try table.required(Int.self, "poll_interval_seconds")
        maxConcurrentRuns = try table.required(Int.self, "max_concurrent_runs")
        runTimeoutSeconds = try table.required(Int.self, "run_timeout_seconds")
        providerGraceSeconds = try table.required(Int.self, "provider_grace_seconds")
        stateRoot = try table.required(String.self, "state_root")
        workspaceBackend = try table.required(String.self, "workspace_backend")
        publisherBackend = try table.required(String.self, "publisher_backend")
        limits = try table.required(RawLimits.self, "limits")
    }
}

private struct RawLimits: Decodable {
    let maxLogBytes: Int
    let maxWorkspaceBytes: Int
    let maxChangedFiles: Int
    let maxDiffBytes: Int
    let maxSingleFileBytes: Int
    let allowBinaryFiles: Bool

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "worker.limits",
            allowed: [
                "max_log_bytes", "max_workspace_bytes", "max_changed_files", "max_diff_bytes",
                "max_single_file_bytes", "allow_binary_files",
            ]
        )
        maxLogBytes = try table.required(Int.self, "max_log_bytes")
        maxWorkspaceBytes = try table.required(Int.self, "max_workspace_bytes")
        maxChangedFiles = try table.required(Int.self, "max_changed_files")
        maxDiffBytes = try table.required(Int.self, "max_diff_bytes")
        maxSingleFileBytes = try table.required(Int.self, "max_single_file_bytes")
        allowBinaryFiles = try table.optional(Bool.self, "allow_binary_files") ?? false
    }
}

private struct RawProvider: Decodable {
    let id: String
    let kind: String
    let executable: String
    let argv: [String]
    let timeoutSeconds: Int

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "providers[]",
            allowed: ["id", "kind", "executable", "argv", "timeout_seconds"]
        )
        id = try table.required(String.self, "id")
        kind = try table.required(String.self, "kind")
        executable = try table.required(String.self, "executable")
        argv = try table.required([String].self, "argv")
        timeoutSeconds = try table.required(Int.self, "timeout_seconds")
    }
}

private struct RawAgent: Decodable {
    let id: String
    let provider: String
    let instructionsFile: String
    let validationProfile: String

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "agents[]",
            allowed: ["id", "provider", "instructions_file", "validation_profile"]
        )
        id = try table.required(String.self, "id")
        provider = try table.required(String.self, "provider")
        instructionsFile = try table.required(String.self, "instructions_file")
        validationProfile = try table.required(String.self, "validation_profile")
    }
}

private struct RawRoute: Decodable {
    let id: String
    let priority: Int
    let labelsAll: [String]
    let labelsAny: [String]
    let agent: String

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "routes[]",
            allowed: ["id", "priority", "labels_all", "labels_any", "agent"]
        )
        id = try table.required(String.self, "id")
        priority = try table.required(Int.self, "priority")
        labelsAll = try table.required([String].self, "labels_all")
        labelsAny = try table.required([String].self, "labels_any")
        agent = try table.required(String.self, "agent")
    }
}

private struct RawRepository: Decodable {
    let repository: String
    let enabled: Bool
    let defaultBranch: String
    let remote: String
    let routeIDs: [String]

    init(from decoder: Decoder) throws {
        let table = try StrictTable(
            decoder,
            path: "repositories[]",
            allowed: ["repository", "enabled", "default_branch", "remote", "route_ids"]
        )
        repository = try table.required(String.self, "repository")
        enabled = try table.required(Bool.self, "enabled")
        defaultBranch = try table.required(String.self, "default_branch")
        remote = try table.required(String.self, "remote")
        routeIDs = try table.required([String].self, "route_ids")
    }
}

public struct ConfigLoader: Sendable {
    public static let maximumConfigBytes = 1024 * 1024
    public static let maximumInstructionsBytes = 256 * 1024

    public init() {}

    public static func defaultConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/MakeAnIssue", isDirectory: true)
            .appendingPathComponent("agents.toml", isDirectory: false)
    }

    public func load(from url: URL) throws -> WorkerConfigSnapshot {
        let data = try SecureFileReader.read(
            url: url,
            maximumBytes: Self.maximumConfigBytes,
            kind: "configuration"
        )
        let raw: RawConfig
        do {
            let decoder = TOMLDecoder()
            decoder.limits.maxInputSize = Self.maximumConfigBytes
            raw = try decoder.decode(RawConfig.self, from: data)
        } catch let error as SchemaDecodeError {
            throw ConfigError(file: url.path, key: error.key, reason: error.reason)
        } catch {
            throw ConfigError(file: url.path, key: "<syntax>", reason: String(describing: error))
        }

        guard raw.schemaVersion == WorkerConfigSnapshot.supportedSchemaVersion else {
            throw ConfigError(
                file: url.path,
                key: "schema_version",
                reason: "unsupported schema version \(raw.schemaVersion); expected 1. Update agents.toml to schema_version = 1 or install a compatible worker."
            )
        }

        let revision = Self.sha256(data)
        let worker = try validateWorker(raw.worker, file: url.path)
        let providers = try validateProviders(raw.providers, file: url.path)
        let agents = try validateAgents(raw.agents, providers: providers, file: url.path)
        let routes = try validateRoutes(raw.routes, agents: agents, file: url.path)
        let repositories = try validateRepositories(raw.repositories, routes: routes, file: url.path)
        let redactedSnapshot = try makeRedactedSnapshot(
            schemaVersion: raw.schemaVersion,
            revision: revision,
            worker: worker,
            providers: providers,
            agents: agents,
            routes: routes,
            repositories: repositories
        )

        return WorkerConfigSnapshot(
            sourceURL: url,
            schemaVersion: raw.schemaVersion,
            revision: revision,
            worker: worker,
            providers: providers,
            agents: agents,
            routes: routes,
            repositories: repositories,
            redactedSnapshot: redactedSnapshot
        )
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateWorker(_ raw: RawWorker, file: String) throws -> WorkerSettings {
        try require(raw.pollIntervalSeconds == 60, file, "worker.poll_interval_seconds", "must equal 60 in schema version 1")
        try require(raw.maxConcurrentRuns == 1, file, "worker.max_concurrent_runs", "must equal 1 in schema version 1")
        try require((60...14_400).contains(raw.runTimeoutSeconds), file, "worker.run_timeout_seconds", "must be between 60 and 14400")
        try require((1...60).contains(raw.providerGraceSeconds), file, "worker.provider_grace_seconds", "must be between 1 and 60")

        guard let workspace = WorkspaceBackend(rawValue: raw.workspaceBackend) else {
            throw ConfigError(file: file, key: "worker.workspace_backend", reason: "must be treehouse or builtin; auto is forbidden")
        }
        guard let publisher = PublisherBackend(rawValue: raw.publisherBackend) else {
            throw ConfigError(file: file, key: "worker.publisher_backend", reason: "must be auto, no-mistakes, or builtin")
        }

        let stateRoot = try expandUserPath(raw.stateRoot, file: file, key: "worker.state_root")
        try validateExistingDirectory(stateRoot, file: file, key: "worker.state_root")
        let numericLimits: [(String, Int)] = [
            ("max_log_bytes", raw.limits.maxLogBytes),
            ("max_workspace_bytes", raw.limits.maxWorkspaceBytes),
            ("max_changed_files", raw.limits.maxChangedFiles),
            ("max_diff_bytes", raw.limits.maxDiffBytes),
            ("max_single_file_bytes", raw.limits.maxSingleFileBytes),
        ]
        for (key, value) in numericLimits {
            try require(value > 0, file, "worker.limits.\(key)", "must be a positive integer")
        }

        return WorkerSettings(
            pollIntervalSeconds: raw.pollIntervalSeconds,
            maxConcurrentRuns: raw.maxConcurrentRuns,
            runTimeoutSeconds: raw.runTimeoutSeconds,
            providerGraceSeconds: raw.providerGraceSeconds,
            stateRoot: stateRoot,
            workspaceBackend: workspace,
            publisherBackend: publisher,
            limits: WorkerLimits(
                maxLogBytes: raw.limits.maxLogBytes,
                maxWorkspaceBytes: raw.limits.maxWorkspaceBytes,
                maxChangedFiles: raw.limits.maxChangedFiles,
                maxDiffBytes: raw.limits.maxDiffBytes,
                maxSingleFileBytes: raw.limits.maxSingleFileBytes,
                allowBinaryFiles: raw.limits.allowBinaryFiles
            )
        )
    }

    private func validateProviders(_ raw: [RawProvider], file: String) throws -> [ProviderConfig] {
        try require(!raw.isEmpty, file, "providers", "must contain at least one provider")
        try requireUnique(raw.map(\.id), file: file, key: "providers[].id")
        return try raw.map { provider in
            try requireID(provider.id, file: file, key: "providers[].id")
            guard let kind = ProviderKind(rawValue: provider.kind) else {
                throw ConfigError(
                    file: file,
                    key: "providers[\(provider.id)].kind",
                    reason: "unknown provider kind \(provider.kind); expected claude-code, codex, or codex-oss"
                )
            }
            try require(provider.timeoutSeconds > 0, file, "providers[\(provider.id)].timeout_seconds", "must be a positive integer")
            for (index, argument) in provider.argv.enumerated() {
                try require(!argument.contains("\0"), file, "providers[\(provider.id)].argv[\(index)]", "must not contain a NUL byte")
                try require(!looksLikeEnvironmentAssignment(argument), file, "providers[\(provider.id)].argv[\(index)]", "environment assignments are forbidden")
            }
            try require(provider.executable.hasPrefix("/"), file, "providers[\(provider.id)].executable", "must be an absolute path")
            let executableURL = URL(fileURLWithPath: provider.executable)
            let identity = try executableIdentity(at: executableURL, file: file, key: "providers[\(provider.id)].executable")
            return ProviderConfig(
                id: provider.id,
                kind: kind,
                executable: URL(fileURLWithPath: identity.path),
                argv: provider.argv,
                timeoutSeconds: provider.timeoutSeconds,
                executableIdentity: identity
            )
        }
    }

    private func validateAgents(
        _ raw: [RawAgent],
        providers: [ProviderConfig],
        file: String
    ) throws -> [AgentConfig] {
        try require(!raw.isEmpty, file, "agents", "must contain at least one agent")
        try requireUnique(raw.map(\.id), file: file, key: "agents[].id")
        let providerIDs = Set(providers.map(\.id))
        return try raw.map { agent in
            try requireID(agent.id, file: file, key: "agents[].id")
            try require(providerIDs.contains(agent.provider), file, "agents[\(agent.id)].provider", "references missing provider \(agent.provider)")
            try require(["default", "spike"].contains(agent.validationProfile), file, "agents[\(agent.id)].validation_profile", "unknown worker-defined validation profile")
            let instructionsURL = try expandUserPath(agent.instructionsFile, file: file, key: "agents[\(agent.id)].instructions_file")
            let data = try SecureFileReader.read(
                url: instructionsURL,
                maximumBytes: Self.maximumInstructionsBytes,
                kind: "instructions"
            )
            guard let instructions = String(data: data, encoding: .utf8) else {
                throw ConfigError(file: instructionsURL.path, key: "agents[\(agent.id)].instructions_file", reason: "must contain valid UTF-8")
            }
            return AgentConfig(
                id: agent.id,
                provider: agent.provider,
                instructionsFile: instructionsURL,
                instructions: instructions,
                instructionsSHA256: Self.sha256(data),
                validationProfile: agent.validationProfile
            )
        }
    }

    private func validateRoutes(
        _ raw: [RawRoute],
        agents: [AgentConfig],
        file: String
    ) throws -> [RouteConfig] {
        try require(!raw.isEmpty, file, "routes", "must contain at least one route")
        try requireUnique(raw.map(\.id), file: file, key: "routes[].id")
        let duplicatePriorities = Dictionary(grouping: raw, by: \.priority).filter { $0.value.count > 1 }
        if let duplicate = duplicatePriorities.sorted(by: { $0.key > $1.key }).first {
            let ids = duplicate.value.map(\.id).joined(separator: ", ")
            throw ConfigError(file: file, key: "routes[].priority", reason: "priority \(duplicate.key) is shared by \(ids); route priorities must be unique")
        }
        let agentIDs = Set(agents.map(\.id))
        return try raw.map { route in
            try requireID(route.id, file: file, key: "routes[].id")
            try require(agentIDs.contains(route.agent), file, "routes[\(route.id)].agent", "references missing agent \(route.agent)")
            try require(route.labelsAll.contains("agent:run"), file, "routes[\(route.id)].labels_all", "must include agent:run")
            try require(!route.labelsAll.contains(where: \.isEmpty), file, "routes[\(route.id)].labels_all", "labels must not be empty")
            try require(!route.labelsAny.contains(where: \.isEmpty), file, "routes[\(route.id)].labels_any", "labels must not be empty")
            return RouteConfig(
                id: route.id,
                priority: route.priority,
                labelsAll: route.labelsAll,
                labelsAny: route.labelsAny,
                agent: route.agent
            )
        }
    }

    private func validateRepositories(
        _ raw: [RawRepository],
        routes: [RouteConfig],
        file: String
    ) throws -> [RepositoryConfig] {
        try require(!raw.isEmpty, file, "repositories", "must contain at least one repository")
        try requireUnique(raw.map(\.repository), file: file, key: "repositories[].repository")
        let routeIDs = Set(routes.map(\.id))
        return try raw.map { repository in
            try require(
                repository.repository.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?/[a-z0-9_.](?:[a-z0-9_.-]*[a-z0-9_.])?$"#, options: .regularExpression) != nil,
                file,
                "repositories[\(repository.repository)].repository",
                "must be a lowercase canonical owner/name GitHub slug"
            )
            try require(!repository.defaultBranch.isEmpty, file, "repositories[\(repository.repository)].default_branch", "must not be empty")
            try require(!repository.routeIDs.isEmpty, file, "repositories[\(repository.repository)].route_ids", "must contain at least one route")
            for routeID in repository.routeIDs {
                try require(routeIDs.contains(routeID), file, "repositories[\(repository.repository)].route_ids", "references missing route \(routeID)")
            }
            let remoteSlug = Self.githubRemoteSlug(repository.remote)
            try require(
                remoteSlug?.lowercased() == repository.repository,
                file,
                "repositories[\(repository.repository)].remote",
                "must be an HTTPS or SSH GitHub remote matching \(repository.repository)"
            )
            return RepositoryConfig(
                repository: repository.repository,
                enabled: repository.enabled,
                defaultBranch: repository.defaultBranch,
                remote: repository.remote,
                routeIDs: repository.routeIDs
            )
        }
    }

    public static func githubRemoteSlug(_ remote: String) -> String? {
        let patterns = [
            #"^https://github\.com/([^/]+/[^/]+?)(?:\.git)?$"#,
            #"^ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$"#,
            #"^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
                  let range = Range(match.range(at: 1), in: remote) else { continue }
            return String(remote[range])
        }
        return nil
    }

    private func makeRedactedSnapshot(
        schemaVersion: Int,
        revision: String,
        worker: WorkerSettings,
        providers: [ProviderConfig],
        agents: [AgentConfig],
        routes: [RouteConfig],
        repositories: [RepositoryConfig]
    ) throws -> String {
        let object: [String: Any] = [
            "schema_version": schemaVersion,
            "revision": revision,
            "worker": [
                "poll_interval_seconds": worker.pollIntervalSeconds,
                "max_concurrent_runs": worker.maxConcurrentRuns,
                "run_timeout_seconds": worker.runTimeoutSeconds,
                "provider_grace_seconds": worker.providerGraceSeconds,
                "state_root": worker.stateRoot.path,
                "workspace_backend": worker.workspaceBackend.rawValue,
                "publisher_backend": worker.publisherBackend.rawValue,
            ],
            "providers": providers.map { ["id": $0.id, "kind": $0.kind.rawValue, "executable": $0.executable.path] },
            "agents": agents.map {
                [
                    "id": $0.id,
                    "provider": $0.provider,
                    "instructions_sha256": $0.instructionsSHA256,
                    "validation_profile": $0.validationProfile,
                ]
            },
            "routes": routes.map {
                [
                    "id": $0.id,
                    "priority": $0.priority,
                    "labels_all": $0.labelsAll,
                    "labels_any": $0.labelsAny,
                    "agent": $0.agent,
                ] as [String: Any]
            },
            "repositories": repositories.map {
                [
                    "repository": $0.repository,
                    "enabled": $0.enabled,
                    "default_branch": $0.defaultBranch,
                    "remote": $0.remote,
                    "route_ids": $0.routeIDs,
                ] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func expandUserPath(_ path: String, file: String, key: String) throws -> URL {
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }
        guard expanded.hasPrefix("/") else {
            throw ConfigError(file: file, key: key, reason: "must be absolute after ~ expansion")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func validateExistingDirectory(_ url: URL, file: String, key: String) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw ConfigError(file: file, key: key, reason: "cannot inspect path: \(String(cString: strerror(errno)))")
        }
        try require((metadata.st_mode & S_IFMT) == S_IFDIR, file, key, "must be a directory")
        try require(metadata.st_uid == getuid(), file, key, "must be owned by the current user")
        try require((metadata.st_mode & S_IFMT) != S_IFLNK, file, key, "must not be a symlink")
    }

    private func executableIdentity(at configuredURL: URL, file: String, key: String) throws -> ExecutableIdentity {
        let resolved = configuredURL.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard stat(resolved.path, &metadata) == 0 else {
            throw ConfigError(file: file, key: key, reason: "executable does not exist: \(configuredURL.path)")
        }
        try require((metadata.st_mode & S_IFMT) == S_IFREG, file, key, "must resolve to a regular file")
        try require(access(resolved.path, X_OK) == 0, file, key, "must be executable by the current user")
        return ExecutableIdentity(
            path: resolved.path,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: metadata.st_size,
            modificationTime: Int64(metadata.st_mtimespec.tv_sec),
            codeSignatureVerified: Self.verifyCodeSignature(resolved)
        )
    }

    private static func verifyCodeSignature(_ executable: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", executable.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ file: String, _ key: String, _ reason: String) throws {
        if !condition() { throw ConfigError(file: file, key: key, reason: reason) }
    }

    private func requireUnique(_ values: [String], file: String, key: String) throws {
        if let duplicate = Dictionary(grouping: values, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw ConfigError(file: file, key: key, reason: "duplicate value \(duplicate)")
        }
    }

    private func requireID(_ id: String, file: String, key: String) throws {
        try require(
            id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
            file,
            key,
            "must use 1-64 lowercase letters, digits, or hyphens"
        )
    }

    private func looksLikeEnvironmentAssignment(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }
}

private enum SecureFileReader {
    static func read(url: URL, maximumBytes: Int, kind: String) throws -> Data {
        let path = url.path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let reason = errno == ELOOP ? "must not be a symlink" : "cannot open: \(String(cString: strerror(errno)))"
            throw ConfigError(file: path, key: "<file>", reason: reason)
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ConfigError(file: path, key: "<file>", reason: "cannot inspect open file: \(String(cString: strerror(errno)))")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ConfigError(file: path, key: "<file>", reason: "\(kind) must be a regular file")
        }
        guard metadata.st_uid == getuid() else {
            throw ConfigError(file: path, key: "<file>", reason: "\(kind) must be owned by the current user")
        }
        guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ConfigError(file: path, key: "<file>", reason: "\(kind) must not be group- or world-writable")
        }
        guard metadata.st_size <= maximumBytes else {
            throw ConfigError(file: path, key: "<file>", reason: "\(kind) exceeds \(maximumBytes) bytes")
        }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfigError(file: path, key: "<file>", reason: "read failed: \(String(cString: strerror(errno)))")
            }
            result.append(buffer, count: count)
            if result.count > maximumBytes {
                throw ConfigError(file: path, key: "<file>", reason: "\(kind) exceeds \(maximumBytes) bytes")
            }
        }
        return result
    }
}
