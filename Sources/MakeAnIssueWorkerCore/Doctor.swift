import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let timeoutSeconds: Int?

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false,
        timeoutSeconds: Int? = nil
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.timeoutSeconds = timeoutSeconds
    }
}

public protocol CommandRunning: Sendable {
    func resolveExecutable(_ name: String) -> String?
    func run(executable: String, arguments: [String]) -> CommandResult
    func run(executable: String, arguments: [String], environment: [String: String]) -> CommandResult
    func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL?) -> CommandResult
}

public extension CommandRunning {
    func run(executable: String, arguments: [String], environment: [String: String]) -> CommandResult {
        run(executable: executable, arguments: arguments)
    }

    func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL?) -> CommandResult {
        run(executable: executable, arguments: arguments, environment: environment)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    private let environment: [String: String]
    private let processes: any ProcessExecuting
    private let probeTimeoutSeconds: Int

    /// Every doctor subprocess gets a 20-second wall-clock budget so capability probes cannot stall the CLI.
    public static let probeTimeoutSeconds = 20

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processes: any ProcessExecuting = FoundationProcessExecutor(),
        probeTimeoutSeconds: Int = Self.probeTimeoutSeconds
    ) {
        self.environment = environment
        self.processes = processes
        self.probeTimeoutSeconds = probeTimeoutSeconds
    }

    public func resolveExecutable(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func run(executable: String, arguments: [String]) -> CommandResult {
        run(executable: executable, arguments: arguments, environment: environment)
    }

    public func run(executable: String, arguments: [String], environment: [String: String]) -> CommandResult {
        run(executable: executable, arguments: arguments, environment: environment, workingDirectory: nil)
    }

    public func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL?) -> CommandResult {
        let execution = processes.execute(ProcessRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: probeTimeoutSeconds
        ))
        return CommandResult(
            exitCode: execution.exitCode,
            stdout: execution.stdoutString,
            stderr: execution.stderrString,
            timedOut: execution.timedOut,
            timeoutSeconds: execution.timedOut ? probeTimeoutSeconds : nil
        )
    }
}

public protocol StateRootProbing: Sendable {
    func probe(_ url: URL) -> Result<String, Error>
}

public struct StateRootProbe: StateRootProbing {
    public init() {}

    public func probe(_ url: URL) -> Result<String, Error> {
        do {
            try StateDirectory.ensure(url)
            let probe = url.appendingPathComponent(".doctor-write-probe-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: probe.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                return .failure(DoctorProbeError("cannot create a write probe"))
            }
            try FileManager.default.removeItem(at: probe)
            return .success(url.path)
        } catch {
            return .failure(error)
        }
    }
}

public struct DoctorProbeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum DoctorCheckStatus: String, Sendable {
    case pass
    case warning
    case blocking
}

public struct DoctorCheck: Equatable, Sendable {
    public let name: String
    public let status: DoctorCheckStatus
    public let detail: String

    public init(name: String, status: DoctorCheckStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct DoctorReport: Sendable {
    public let checks: [DoctorCheck]
    public let config: WorkerConfigSnapshot?

    public var hasBlockingIssues: Bool { checks.contains { $0.status == .blocking } }

    public func humanReadable() -> String {
        checks.map(Self.humanReadable).joined(separator: "\n")
    }

    public static func humanReadable(_ check: DoctorCheck) -> String {
        let marker: String
        switch check.status {
        case .pass: marker = "✓"
        case .warning: marker = "!"
        case .blocking: marker = "✗"
        }
        return "\(marker) \(check.name): \(check.detail)"
    }
}

private struct DoctorPublisherCapabilities: Decodable {
    let draftPR: Bool
    let prePushValidation: Bool
    let tokenIsolation: Bool
    let noForce: Bool
    let artifactExport: Bool
    let startupReconciliation: Bool

    var satisfiesContract: Bool {
        draftPR && prePushValidation && tokenIsolation && noForce && artifactExport && startupReconciliation
    }

    enum CodingKeys: String, CodingKey {
        case draftPR = "draft_pr"
        case prePushValidation = "pre_push_validation"
        case tokenIsolation = "token_isolation"
        case noForce = "no_force"
        case artifactExport = "artifact_export"
        case startupReconciliation = "startup_reconciliation"
    }
}

public struct Doctor: Sendable {
    private let configLoader: ConfigLoader
    private let commands: any CommandRunning
    private let stateRoot: any StateRootProbing
    private let supervisorEnvironment: [String: String]

    public init(
        configLoader: ConfigLoader = ConfigLoader(),
        commands: any CommandRunning = ProcessCommandRunner(),
        stateRoot: any StateRootProbing = StateRootProbe(),
        supervisorEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configLoader = configLoader
        self.commands = commands
        self.stateRoot = stateRoot
        self.supervisorEnvironment = supervisorEnvironment
    }

    public func run(configURL: URL, onCheck: (DoctorCheck) -> Void = { _ in }) -> DoctorReport {
        let config: WorkerConfigSnapshot
        do {
            config = try configLoader.load(from: configURL)
        } catch {
            let check = DoctorCheck(name: "config", status: .blocking, detail: String(describing: error))
            onCheck(check)
            return DoctorReport(checks: [check], config: nil)
        }

        var checks = [DoctorCheck]()
        func append(_ check: DoctorCheck) {
            checks.append(check)
            onCheck(check)
        }

        append(DoctorCheck(
            name: "config",
            status: .pass,
            detail: "schema v\(config.schemaVersion), revision \(config.revision.prefix(12))"
        ))
        for provider in config.providers {
            providerChecks(provider, append: append)
        }
        append(workspaceCheck(config.worker.workspaceBackend))
        publisherChecks(config.worker.publisherBackend, append: append)
        append(ghCheck())
        append(stateRootCheck(config.worker.stateRoot))
        return DoctorReport(checks: checks, config: config)
    }

    private func providerChecks(_ provider: ProviderConfig, append: (DoctorCheck) -> Void) {
        append(DoctorCheck(
            name: "provider \(provider.id) executable",
            status: FileManager.default.isExecutableFile(atPath: provider.executable.path) ? .pass : .blocking,
            detail: provider.executable.path
        ))
        let authArguments: [String]?
        switch provider.kind {
        case .claudeCode: authArguments = ["auth", "status"]
        case .codex: authArguments = ["login", "status"]
        case .codexOSS: authArguments = nil
        }
        if let authArguments {
            let result = providerAuthProbe(provider, arguments: authArguments)
            let auth = providerAuthResult(provider.kind, result: result)
            append(DoctorCheck(
                name: "provider \(provider.id) auth",
                status: auth.authenticated ? .pass : .blocking,
                detail: auth.detail
            ))
        } else {
            append(DoctorCheck(
                name: "provider \(provider.id) auth",
                status: .pass,
                detail: "not required by the codex-oss adapter; endpoint credentials are adapter configuration"
            ))
        }
    }

    private func providerAuthProbe(_ provider: ProviderConfig, arguments: [String]) -> CommandResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("make-an-issue-doctor-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("provider-home", isDirectory: true)
        let temporary = root.appendingPathComponent("provider-tmp", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            chmod(home.path, 0o700)
            chmod(temporary.path, 0o700)
        } catch {
            return CommandResult(exitCode: -1, stderr: error.localizedDescription)
        }
        return commands.run(
            executable: provider.executable.path,
            arguments: arguments,
            environment: WorkerEnvironment.provider(
                home: home,
                temporaryDirectory: temporary,
                workspace: workspace,
                supervisorEnvironment: supervisorEnvironment
            ),
            workingDirectory: workspace
        )
    }

    private func workspaceCheck(_ backend: WorkspaceBackend) -> DoctorCheck {
        guard backend == .treehouse else {
            return DoctorCheck(name: "workspace backend", status: .pass, detail: "builtin selected")
        }
        guard let executable = commands.resolveExecutable("treehouse") else {
            return DoctorCheck(name: "workspace backend", status: .blocking, detail: "treehouse is selected but not found on PATH")
        }
        let result = commands.run(executable: executable, arguments: ["--version"])
        return DoctorCheck(
            name: "workspace backend",
            status: result.exitCode == 0 ? .pass : .blocking,
            detail: result.timedOut ? timeoutDetail(result) : (result.exitCode == 0 ? concise(result.stdout, fallback: executable) : concise(result.stderr, fallback: "treehouse version probe failed"))
        )
    }

    private func publisherChecks(_ backend: PublisherBackend, append: (DoctorCheck) -> Void) {
        if backend == .builtin {
            let capabilities = BuiltinPublisher(stateRoot: FileManager.default.temporaryDirectory).capabilities()
            append(DoctorCheck(
                name: "publisher backend",
                status: capabilities.satisfiesContract ? .pass : .blocking,
                detail: capabilities.satisfiesContract
                    ? "builtin selected; executable capability probe proves validation, no-force, artifact, draft, and reconciliation support"
                    : "builtin capability probe failed"
            ))
            return
        }
        guard let executable = commands.resolveExecutable("no-mistakes") else {
            if backend == .auto {
                append(DoctorCheck(name: "publisher backend", status: .pass, detail: "builtin selected under auto; no-mistakes is not installed"))
                return
            }
            append(DoctorCheck(name: "publisher backend", status: .blocking, detail: "no-mistakes is selected but not found on PATH"))
            return
        }

        let version = commands.run(executable: executable, arguments: ["--version"])
        let capability = commands.run(executable: executable, arguments: ["publisher-capabilities", "--json"])
        if version.timedOut || capability.timedOut {
            let check = DoctorCheck(
                name: "publisher backend",
                status: backend == .auto ? .warning : .blocking,
                detail: "no-mistakes probe \(timeoutDetail(version.timedOut ? version : capability))"
                    + (backend == .auto ? "; builtin selected under auto" : "; explicit no-mistakes selection fails closed")
            )
            append(check)
            return
        }
        let capabilities = capability.exitCode == 0
            ? try? JSONDecoder().decode(DoctorPublisherCapabilities.self, from: Data(capability.stdout.utf8))
            : nil
        let versionText = concise(version.stdout, fallback: executable)
        let versionLabel = versionText.lowercased().hasPrefix("no-mistakes")
            ? versionText
            : "no-mistakes \(versionText)"
        if capabilities?.satisfiesContract == true {
            append(DoctorCheck(name: "publisher backend", status: .pass, detail: "\(versionLabel) proved all required capabilities including draft PR creation"))
            return
        }
        let missing = "\(versionLabel) did not prove draft PR creation, token isolation, no-force publication, artifact export, and startup reconciliation"
        if backend == .auto {
            append(DoctorCheck(name: "publisher backend", status: .warning, detail: "\(missing); builtin selected under auto"))
            return
        }
        append(DoctorCheck(name: "publisher backend", status: .blocking, detail: "\(missing); explicit no-mistakes selection fails closed"))
    }

    private func ghCheck() -> DoctorCheck {
        guard let executable = commands.resolveExecutable("gh") else {
            return DoctorCheck(name: "gh auth", status: .blocking, detail: "gh is not found on PATH")
        }
        let result = commands.run(executable: executable, arguments: ["auth", "status"])
        return DoctorCheck(
            name: "gh auth",
            status: result.exitCode == 0 ? .pass : .blocking,
            detail: result.timedOut ? timeoutDetail(result) : (result.exitCode == 0 ? "authenticated" : concise(result.stderr, fallback: "gh auth status failed"))
        )
    }

    private func stateRootCheck(_ url: URL) -> DoctorCheck {
        switch stateRoot.probe(url) {
        case .success(let detail): return DoctorCheck(name: "state root", status: .pass, detail: detail)
        case .failure(let error): return DoctorCheck(name: "state root", status: .blocking, detail: String(describing: error))
        }
    }

    private func providerAuthResult(
        _ kind: ProviderKind,
        result: CommandResult
    ) -> (authenticated: Bool, detail: String) {
        if result.timedOut { return (false, timeoutDetail(result)) }
        guard result.exitCode == 0 else {
            if kind == .claudeCode {
                let status = concise(result.stderr, fallback: "Claude Code is not authenticated in the worker sandbox")
                return (false, "\(status); export CLAUDE_CODE_OAUTH_TOKEN (for example: `claude setup-token`)")
            }
            return (false, concise(result.stderr, fallback: "authentication check failed"))
        }
        if kind == .claudeCode,
           let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(result.stdout.utf8)) {
            return (
                status.loggedIn,
                status.loggedIn
                    ? "authenticated\(status.authMethod.map { " via \($0)" } ?? "")"
                    : "Claude Code is not authenticated in the worker sandbox; export CLAUDE_CODE_OAUTH_TOKEN (for example: `claude setup-token`)"
            )
        }
        return (true, concise(result.stdout, fallback: "authenticated"))
    }

    private func concise(_ value: String, fallback: String) -> String {
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line! : fallback
    }

    private func timeoutDetail(_ result: CommandResult) -> String {
        "timed out after \(result.timeoutSeconds ?? ProcessCommandRunner.probeTimeoutSeconds)s"
    }
}

private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String?
}
