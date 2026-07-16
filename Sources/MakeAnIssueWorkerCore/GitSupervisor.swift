import CryptoKit
import Darwin
import Foundation

public enum GitSafetyError: Error, Equatable, CustomStringConvertible, Sendable {
    case forceOperation(String)
    case defaultBranchMutation(String)
    case unexpectedBranch(expected: String, observed: String)
    case branchExists(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .forceOperation(let value): return "force or ref-deletion operation rejected: \(value)"
        case .defaultBranchMutation(let value): return "default branch mutation rejected: \(value)"
        case .unexpectedBranch(let expected, let observed): return "expected branch \(expected), observed \(observed)"
        case .branchExists(let value): return "remote branch already exists: \(value)"
        case .commandFailed(let value): return value
        }
    }
}

public enum GitMutationPolicy {
    public static func validate(arguments: [String], branch: String, defaultBranch: String) throws {
        for argument in arguments {
            if argument == "-f" || argument == "--force" || argument.hasPrefix("--force=")
                || argument == "--force-with-lease" || argument.hasPrefix("--force-with-lease=")
                || argument.hasPrefix("+") {
                throw GitSafetyError.forceOperation(argument)
            }
        }
        if arguments.first == "push" {
            if arguments.contains("--delete") || arguments.contains(where: { $0.hasPrefix(":refs/") || $0.hasSuffix(":") }) {
                throw GitSafetyError.forceOperation(arguments.joined(separator: " "))
            }
        }
        guard branch != defaultBranch else {
            throw GitSafetyError.defaultBranchMutation(defaultBranch)
        }
    }
}

public struct GitMetadataSnapshot: Equatable, Sendable {
    public let headSHA: String
    public let refs: String
    public let config: String
    public let remotes: String
    public let protectedFilesDigest: String
}

public struct GitSupervisor: Sendable {
    public let workspace: URL
    public let branch: String
    public let defaultBranch: String
    private let processes: any ProcessExecuting
    private let environment: [String: String]

    public init(
        workspace: URL,
        branch: String,
        defaultBranch: String,
        processes: any ProcessExecuting = FoundationProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.workspace = workspace
        self.branch = branch
        self.defaultBranch = defaultBranch
        self.processes = processes
        self.environment = environment
    }

    public func currentHead() throws -> String { try text(["rev-parse", "HEAD"]) }

    public func currentBranch() throws -> String { try text(["symbolic-ref", "--quiet", "--short", "HEAD"]) }

    public func verifyOwnedBranch() throws {
        let observed = try currentBranch()
        guard observed == branch else { throw GitSafetyError.unexpectedBranch(expected: branch, observed: observed) }
        guard observed != defaultBranch else { throw GitSafetyError.defaultBranchMutation(defaultBranch) }
    }

    public func snapshotMetadata() throws -> GitMetadataSnapshot {
        GitMetadataSnapshot(
            headSHA: try currentHead(),
            refs: try text(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"]),
            config: try text(["config", "--local", "--list", "--show-origin"]),
            remotes: try text(["remote", "-v"]),
            protectedFilesDigest: try protectedGitFilesDigest()
        )
    }

    public func verifyMetadataUnchanged(from snapshot: GitMetadataSnapshot) throws {
        let observed = try snapshotMetadata()
        guard observed == snapshot else {
            throw GitSafetyError.commandFailed("provider modified git metadata, refs, HEAD, or remotes")
        }
    }

    public func stageAll() throws {
        try mutate(["add", "--all", "--", "."])
    }

    public func commit(issueNumber: Int) throws -> String {
        try mutate([
            "-c", "user.name=make-an-issue-worker",
            "-c", "user.email=make-an-issue-worker@localhost",
            "-c", "core.hooksPath=/dev/null",
            "commit", "--no-gpg-sign", "-m", "Address issue #\(issueNumber)",
        ])
        return try currentHead()
    }

    public func remoteBranchSHA() throws -> String? {
        let result = run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], timeout: 120)
        guard result.exitCode == 0 else {
            throw GitSafetyError.commandFailed("remote ref probe failed: \(concise(result.stderrString))")
        }
        let fields = result.stdoutString.split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == " " })
        return fields.first.map(String.init)
    }

    public func pushFreshBranch(expectedSHA: String) throws -> String {
        try verifyOwnedBranch()
        guard try currentHead() == expectedSHA else {
            throw GitSafetyError.commandFailed("local HEAD no longer matches validated SHA")
        }
        guard try remoteBranchSHA() == nil else { throw GitSafetyError.branchExists(branch) }
        let refspec = "refs/heads/\(branch):refs/heads/\(branch)"
        try GitMutationPolicy.validate(arguments: ["push", "origin", refspec], branch: branch, defaultBranch: defaultBranch)
        let result = run(["push", "origin", refspec], timeout: 300)
        guard result.exitCode == 0 else {
            throw GitSafetyError.commandFailed("normal branch push failed: \(concise(result.stderrString))")
        }
        guard try remoteBranchSHA() == expectedSHA else {
            throw GitSafetyError.commandFailed("remote branch SHA does not match pushed SHA")
        }
        return expectedSHA
    }

    public func read(
        _ arguments: [String],
        timeout: Int = 60,
        maximumOutputBytes: Int = 1_048_576
    ) throws -> ProcessExecution {
        let result = run(arguments, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
        guard result.exitCode == 0 else {
            throw GitSafetyError.commandFailed("git \(arguments.first ?? "") failed: \(concise(result.stderrString))")
        }
        return result
    }

    private func mutate(_ arguments: [String]) throws {
        try verifyOwnedBranch()
        let command = arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? ""
        try GitMutationPolicy.validate(arguments: [command] + arguments, branch: branch, defaultBranch: defaultBranch)
        let result = run(arguments, timeout: 300)
        guard result.exitCode == 0 else {
            throw GitSafetyError.commandFailed("git \(command) failed: \(concise(result.stderrString))")
        }
    }

    private func text(_ arguments: [String]) throws -> String {
        let result = try read(arguments)
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func protectedGitFilesDigest() throws -> String {
        let gitDirectory = URL(fileURLWithPath: try text(["rev-parse", "--absolute-git-dir"]))
        let commonValue = try text(["rev-parse", "--git-common-dir"])
        let commonDirectory = commonValue.hasPrefix("/")
            ? URL(fileURLWithPath: commonValue)
            : workspace.appendingPathComponent(commonValue).standardizedFileURL
        var candidates = [
            gitDirectory.appendingPathComponent("HEAD"),
            gitDirectory.appendingPathComponent("index"),
            commonDirectory.appendingPathComponent("config"),
            commonDirectory.appendingPathComponent("packed-refs"),
        ]
        let hooks = commonDirectory.appendingPathComponent("hooks", isDirectory: true)
        if let hookFiles = try? FileManager.default.contentsOfDirectory(at: hooks, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: hookFiles.sorted { $0.path < $1.path })
        }
        var fingerprint = Data()
        for candidate in candidates {
            fingerprint.append(Data(candidate.path.utf8))
            var metadata = stat()
            if lstat(candidate.path, &metadata) == 0 {
                fingerprint.append(Data("|\(metadata.st_mode)|\(metadata.st_size)|".utf8))
                if (metadata.st_mode & S_IFMT) == S_IFREG,
                   let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]) {
                    fingerprint.append(Data(SHA256.hash(data: data)))
                }
            } else {
                fingerprint.append(Data("|missing|".utf8))
            }
        }
        return SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    }

    private func run(
        _ arguments: [String],
        timeout: Int,
        maximumOutputBytes: Int = 1_048_576
    ) -> ProcessExecution {
        processes.execute(ProcessRequest(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: workspace,
            environment: environment,
            timeoutSeconds: timeout,
            maximumOutputBytes: maximumOutputBytes
        ))
    }
}

public enum BranchPolicy {
    public static func make(issueNumber: Int, title: String, runID: String) -> String {
        let slug = asciiSlug(title)
        let shortID = runID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12)
        let prefix = "mai/issue-\(issueNumber)-"
        let suffix = "-\(shortID)"
        let maximumSlugBytes = max(1, 120 - prefix.utf8.count - suffix.utf8.count)
        let boundedSlug = String(slug.prefix(maximumSlugBytes)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return prefix + (boundedSlug.isEmpty ? "change" : boundedSlug) + suffix
    }

    private static func asciiSlug(_ value: String) -> String {
        var result = ""
        var needsHyphen = false
        for scalar in value.lowercased().unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                if needsHyphen && !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                needsHyphen = false
            } else {
                needsHyphen = true
            }
        }
        return result.isEmpty ? "change" : result
    }
}
