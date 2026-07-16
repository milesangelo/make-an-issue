import Darwin
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class ConfigFixture {
    let root: URL
    let stateRoot: URL
    let configURL: URL
    let instructionsURL: URL
    let executableURL: URL

    init(
        publisherBackend: String = "auto",
        workspaceBackend: String = "treehouse",
        transform: (String) -> String = { $0 }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("make-an-issue-worker-tests-\(UUID().uuidString)", isDirectory: true)
        stateRoot = root.appendingPathComponent("state", isDirectory: true)
        configURL = root.appendingPathComponent("agents.toml")
        instructionsURL = root.appendingPathComponent("instructions.md")
        executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Fix only the requested issue.\n".utf8).write(to: instructionsURL)
        chmod(instructionsURL.path, 0o600)

        let templateURL = Bundle.module.url(
            forResource: "good-agents",
            withExtension: "toml",
            subdirectory: "Fixtures"
        )!
        var value = try String(contentsOf: templateURL, encoding: .utf8)
        value = value
            .replacingOccurrences(of: "__STATE_ROOT__", with: Self.toml(stateRoot.path))
            .replacingOccurrences(of: "__WORKSPACE_BACKEND__", with: workspaceBackend)
            .replacingOccurrences(of: "__PUBLISHER_BACKEND__", with: publisherBackend)
            .replacingOccurrences(of: "__EXECUTABLE__", with: Self.toml(executableURL.path))
            .replacingOccurrences(of: "__INSTRUCTIONS__", with: Self.toml(instructionsURL.path))
        try Data(transform(value).utf8).write(to: configURL)
        chmod(configURL.path, 0o600)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func snapshot() throws -> WorkerConfigSnapshot {
        try ConfigLoader().load(from: configURL)
    }

    private static func toml(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class FakeCommandRunner: @unchecked Sendable, CommandRunning {
    private let resolutions: [String: String]
    private let results: [String: CommandResult]

    init(resolutions: [String: String], results: [String: CommandResult]) {
        self.resolutions = resolutions
        self.results = results
    }

    func resolveExecutable(_ name: String) -> String? {
        if name.hasPrefix("/") { return name }
        return resolutions[name]
    }

    func run(executable: String, arguments: [String]) -> CommandResult {
        results[Self.key(executable, arguments)] ?? CommandResult(exitCode: 127, stderr: "unexpected command")
    }

    static func key(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: "\u{1f}")
    }
}

struct FakeStateRootProbe: StateRootProbing {
    let result: Result<String, Error>
    func probe(_ url: URL) -> Result<String, Error> { result }
}

struct FakeIssueInspector: IssueInspecting {
    let result: Result<IssueFacts, Error>
    func inspect(_ issue: IssueReference) throws -> IssueFacts { try result.get() }
}

struct TerminalTestDriver: RunExecutionDriving {
    let failureCode: String

    init(failureCode: String = "test_driver_terminal") {
        self.failureCode = failureCode
    }

    func execute(_ context: RunExecutionContext) throws -> RunOutcome {
        _ = try context.ledger.transition(
            runID: context.run.id,
            to: .failed,
            failureCode: failureCode
        )
        try context.ledger.releaseHostClaim(runID: context.run.id)
        return RunOutcome(runID: context.run.id, stateReached: .failed, message: failureCode)
    }
}

/// Per-process git timeout for the two known-heavy integration tests. These drive real git
/// setup and can be starved well past the 120s default when the whole suite contends for
/// CPU/IO under load; a generous ceiling keeps them deterministic without touching the
/// shared default other tests rely on.
let loadTolerantGitTimeoutSeconds = 600

@discardableResult
func runProcess(
    _ executable: String,
    _ arguments: [String],
    cwd: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeoutSeconds: Int = 120
) throws -> ProcessExecution {
    let result = FoundationProcessExecutor().execute(ProcessRequest(
        executable: executable,
        arguments: arguments,
        workingDirectory: cwd,
        environment: environment,
        timeoutSeconds: timeoutSeconds
    ))
    guard result.exitCode == 0 else {
        throw NSError(
            domain: "TestProcess",
            code: Int(result.exitCode),
            userInfo: [NSLocalizedDescriptionKey: result.stderrString]
        )
    }
    return result
}

func makeBareOrigin(root: URL, timeoutSeconds: Int = 120) throws -> (origin: URL, mainSHA: String) {
    let origin = root.appendingPathComponent("origin.git", isDirectory: true)
    let seed = root.appendingPathComponent("seed", isDirectory: true)
    try runProcess("/usr/bin/git", ["init", "--bare", origin.path], timeoutSeconds: timeoutSeconds)
    try runProcess("/usr/bin/git", ["init", "-b", "main", seed.path], timeoutSeconds: timeoutSeconds)
    try Data("seed\n".utf8).write(to: seed.appendingPathComponent("README.md"))
    try runProcess("/usr/bin/git", ["add", "README.md"], cwd: seed, timeoutSeconds: timeoutSeconds)
    try runProcess(
        "/usr/bin/git",
        ["-c", "user.name=Tests", "-c", "user.email=tests@localhost", "commit", "-m", "seed"],
        cwd: seed,
        timeoutSeconds: timeoutSeconds
    )
    try runProcess("/usr/bin/git", ["remote", "add", "origin", origin.path], cwd: seed, timeoutSeconds: timeoutSeconds)
    try runProcess(
        "/usr/bin/git",
        ["push", "origin", "refs/heads/main:refs/heads/main"],
        cwd: seed,
        timeoutSeconds: timeoutSeconds
    )
    let sha = try runProcess("/usr/bin/git", ["rev-parse", "HEAD"], cwd: seed, timeoutSeconds: timeoutSeconds)
        .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return (origin, sha)
}

func makeIssue(number: Int = 42) throws -> IssueReference {
    try IssueReference.parse("https://github.com/acme/widgets/issues/\(number)")
}

func makeNewRun(issue: IssueReference, id: String = UUID().uuidString.lowercased()) -> NewRun {
    NewRun(
        id: id,
        issue: issue,
        configRevision: String(repeating: "a", count: 64),
        redactedConfigSnapshot: "{}",
        routeID: "bug",
        agentID: "bugfix",
        triggerKind: .cli
    )
}
