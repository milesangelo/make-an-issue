import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func resolveExecutable(_ name: String) -> String?
    func run(executable: String, arguments: [String]) -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let group = DispatchGroup()
            nonisolated(unsafe) var stdoutData = Data()
            nonisolated(unsafe) var stderrData = Data()
            DispatchQueue.global().async(group: group) {
                stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            }
            DispatchQueue.global().async(group: group) {
                stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            group.wait()
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData.prefix(1024 * 1024), as: UTF8.self),
                stderr: String(decoding: stderrData.prefix(1024 * 1024), as: UTF8.self)
            )
        } catch {
            return CommandResult(exitCode: -1, stderr: error.localizedDescription)
        }
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
        checks.map { check in
            let marker: String
            switch check.status {
            case .pass: marker = "✓"
            case .warning: marker = "!"
            case .blocking: marker = "✗"
            }
            return "\(marker) \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}

private struct PublisherCapabilities: Decodable {
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

    public init(
        configLoader: ConfigLoader = ConfigLoader(),
        commands: any CommandRunning = ProcessCommandRunner(),
        stateRoot: any StateRootProbing = StateRootProbe()
    ) {
        self.configLoader = configLoader
        self.commands = commands
        self.stateRoot = stateRoot
    }

    public func run(configURL: URL) -> DoctorReport {
        let config: WorkerConfigSnapshot
        do {
            config = try configLoader.load(from: configURL)
        } catch {
            return DoctorReport(
                checks: [DoctorCheck(name: "config", status: .blocking, detail: String(describing: error))],
                config: nil
            )
        }

        var checks = [
            DoctorCheck(
                name: "config",
                status: .pass,
                detail: "schema v\(config.schemaVersion), revision \(config.revision.prefix(12))"
            )
        ]
        checks.append(contentsOf: providerChecks(config.providers))
        checks.append(workspaceCheck(config.worker.workspaceBackend))
        checks.append(contentsOf: publisherChecks(config.worker.publisherBackend))
        checks.append(ghCheck())
        checks.append(stateRootCheck(config.worker.stateRoot))
        return DoctorReport(checks: checks, config: config)
    }

    private func providerChecks(_ providers: [ProviderConfig]) -> [DoctorCheck] {
        providers.flatMap { provider in
            var checks = [DoctorCheck(
                name: "provider \(provider.id) executable",
                status: FileManager.default.isExecutableFile(atPath: provider.executable.path) ? .pass : .blocking,
                detail: provider.executable.path
            )]
            let authArguments: [String]?
            switch provider.kind {
            case .claudeCode: authArguments = ["auth", "status"]
            case .codex: authArguments = ["login", "status"]
            case .codexOSS: authArguments = nil
            }
            if let authArguments {
                let result = commands.run(executable: provider.executable.path, arguments: authArguments)
                let auth = providerAuthResult(provider.kind, result: result)
                checks.append(
                    DoctorCheck(
                        name: "provider \(provider.id) auth",
                        status: auth.authenticated ? .pass : .blocking,
                        detail: auth.detail
                    )
                )
            } else {
                checks.append(
                    DoctorCheck(
                        name: "provider \(provider.id) auth",
                        status: .pass,
                        detail: "not required by the codex-oss adapter; endpoint credentials are adapter configuration"
                    )
                )
            }
            return checks
        }
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
            detail: result.exitCode == 0 ? concise(result.stdout, fallback: executable) : concise(result.stderr, fallback: "treehouse version probe failed")
        )
    }

    private func publisherChecks(_ backend: PublisherBackend) -> [DoctorCheck] {
        if backend == .builtin {
            return [DoctorCheck(name: "publisher backend", status: .pass, detail: "builtin selected; draft-only capability is available")]
        }
        guard let executable = commands.resolveExecutable("no-mistakes") else {
            if backend == .auto {
                return [DoctorCheck(name: "publisher backend", status: .pass, detail: "builtin selected under auto; no-mistakes is not installed")]
            }
            return [DoctorCheck(name: "publisher backend", status: .blocking, detail: "no-mistakes is selected but not found on PATH")]
        }

        let version = commands.run(executable: executable, arguments: ["--version"])
        let capability = commands.run(executable: executable, arguments: ["publisher-capabilities", "--json"])
        let capabilities = capability.exitCode == 0
            ? try? JSONDecoder().decode(PublisherCapabilities.self, from: Data(capability.stdout.utf8))
            : nil
        let versionText = concise(version.stdout, fallback: executable)
        let versionLabel = versionText.lowercased().hasPrefix("no-mistakes")
            ? versionText
            : "no-mistakes \(versionText)"
        if capabilities?.satisfiesContract == true {
            return [DoctorCheck(name: "publisher backend", status: .pass, detail: "\(versionLabel) proved all required capabilities including draft PR creation")]
        }
        let missing = "\(versionLabel) did not prove draft PR creation, token isolation, no-force publication, artifact export, and startup reconciliation"
        if backend == .auto {
            return [DoctorCheck(name: "publisher backend", status: .warning, detail: "\(missing); builtin selected under auto")]
        }
        return [DoctorCheck(name: "publisher backend", status: .blocking, detail: "\(missing); explicit no-mistakes selection fails closed")]
    }

    private func ghCheck() -> DoctorCheck {
        guard let executable = commands.resolveExecutable("gh") else {
            return DoctorCheck(name: "gh auth", status: .blocking, detail: "gh is not found on PATH")
        }
        let result = commands.run(executable: executable, arguments: ["auth", "status"])
        return DoctorCheck(
            name: "gh auth",
            status: result.exitCode == 0 ? .pass : .blocking,
            detail: result.exitCode == 0 ? "authenticated" : concise(result.stderr, fallback: "gh auth status failed")
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
        guard result.exitCode == 0 else {
            return (false, concise(result.stderr, fallback: "authentication check failed"))
        }
        if kind == .claudeCode,
           let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(result.stdout.utf8)) {
            return (
                status.loggedIn,
                status.loggedIn
                    ? "authenticated\(status.authMethod.map { " via \($0)" } ?? "")"
                    : "Claude Code reports loggedIn=false"
            )
        }
        return (true, concise(result.stdout, fallback: "authenticated"))
    }

    private func concise(_ value: String, fallback: String) -> String {
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line! : fallback
    }
}

private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String?
}
