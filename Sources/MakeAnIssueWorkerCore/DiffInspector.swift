import CryptoKit
import Darwin
import Foundation

public struct DiffInspection: Equatable, Sendable {
    public let id: String
    public let baseSHA: String
    public let digest: String
    public let changedFiles: [String]
    public let patch: Data
}

public enum DiffInspectionError: Error, Equatable, CustomStringConvertible, Sendable {
    case empty
    case tooManyFiles(Int)
    case diffTooLarge(Int)
    case fileTooLarge(String, Int)
    case workspaceTooLarge(Int)
    case binary(String)
    case unsafePath(String)
    case unsafeSymlink(String)
    case unsupportedNode(String)
    case submodule(String)
    case caseCollision(String, String)
    case git(String)

    public var failureCode: String {
        switch self {
        case .empty: return "empty_diff_retained"
        case .tooManyFiles, .diffTooLarge, .fileTooLarge, .workspaceTooLarge: return "oversized_diff_retained"
        case .binary: return "binary_diff_retained"
        case .unsafePath, .unsafeSymlink, .unsupportedNode, .caseCollision: return "unsafe_path_retained"
        case .submodule: return "submodule_change_retained"
        case .git: return "diff_inspection_failed_retained"
        }
    }

    public var description: String {
        switch self {
        case .empty: return "empty diff cannot be published"
        case .tooManyFiles(let count): return "changed file count \(count) exceeds policy"
        case .diffTooLarge(let size): return "diff size \(size) exceeds policy"
        case .fileTooLarge(let path, let size): return "changed file \(path) size \(size) exceeds policy"
        case .workspaceTooLarge(let size): return "workspace size \(size) exceeds policy"
        case .binary(let path): return "binary change rejected: \(path)"
        case .unsafePath(let path): return "unsafe changed path: \(path)"
        case .unsafeSymlink(let path): return "symlink escapes workspace: \(path)"
        case .unsupportedNode(let path): return "unsupported filesystem node: \(path)"
        case .submodule(let path): return "submodule or .gitmodules change rejected: \(path)"
        case .caseCollision(let first, let second): return "case-colliding paths rejected: \(first), \(second)"
        case .git(let detail): return detail
        }
    }
}

public struct DiffInspector: Sendable {
    private let limits: WorkerLimits
    private static let maxPathRecordBytes = 4160
    private static let caseCollisionScanCap = 64 * 1024 * 1024

    public init(limits: WorkerLimits) { self.limits = limits }

    private var changedPathListCap: Int {
        (max(1, limits.maxChangedFiles) + 1) * Self.maxPathRecordBytes
    }

    private func readNULBounded(_ git: GitSupervisor, _ arguments: [String], cap: Int) throws -> ProcessExecution {
        let result = try git.read(arguments, maximumOutputBytes: cap)
        guard !result.stdoutTruncated else {
            throw DiffInspectionError.git("git \(arguments.first ?? "read") output exceeded the \(cap)-byte inspection bound")
        }
        return result
    }

    public func inspect(git: GitSupervisor, baseSHA: String) throws -> DiffInspection {
        do {
            try git.stageAll()
            let nameResult = try readNULBounded(git, ["diff", "--cached", "--name-only", "-z", baseSHA, "--", "."], cap: changedPathListCap)
            let paths = nameResult.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            guard !paths.isEmpty else { throw DiffInspectionError.empty }
            guard paths.count <= limits.maxChangedFiles else { throw DiffInspectionError.tooManyFiles(paths.count) }
            try inspectCaseCollisions(git: git)
            try inspectPaths(paths, workspace: git.workspace, git: git, baseSHA: baseSHA)
            let workspaceSize = try directorySize(git.workspace, excludingGit: true, stopAfter: limits.maxWorkspaceBytes)
            guard workspaceSize <= limits.maxWorkspaceBytes else { throw DiffInspectionError.workspaceTooLarge(workspaceSize) }

            let patchResult = try git.read(
                ["diff", "--cached", "--binary", "--no-ext-diff", baseSHA, "--", "."],
                maximumOutputBytes: limits.maxDiffBytes + 1
            )
            guard patchResult.stdout.count <= limits.maxDiffBytes else {
                throw DiffInspectionError.diffTooLarge(patchResult.stdout.count)
            }
            if !limits.allowBinaryFiles {
                let numstat = try readNULBounded(git, ["diff", "--cached", "--numstat", "-z", baseSHA, "--", "."], cap: changedPathListCap)
                for record in numstat.stdout.split(separator: 0) {
                    let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3, fields[0] == Data([45]), fields[1] == Data([45]) {
                        throw DiffInspectionError.binary(String(decoding: fields[2], as: UTF8.self))
                    }
                }
            }
            let digest = SHA256.hash(data: patchResult.stdout).map { String(format: "%02x", $0) }.joined()
            return DiffInspection(
                id: UUID().uuidString.lowercased(),
                baseSHA: baseSHA,
                digest: digest,
                changedFiles: paths,
                patch: patchResult.stdout
            )
        } catch let error as DiffInspectionError {
            throw error
        } catch {
            throw DiffInspectionError.git(String(describing: error))
        }
    }

    private func inspectPaths(_ paths: [String], workspace: URL, git: GitSupervisor, baseSHA: String) throws {
        for path in paths {
            guard !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  path != ".git", !path.hasPrefix(".git/") else {
                throw DiffInspectionError.unsafePath(path)
            }
            if path == ".gitmodules" { throw DiffInspectionError.submodule(path) }

            let staged = try git.read(["ls-files", "--stage", "--", path]).stdoutString
            if staged.hasPrefix("160000 ") { throw DiffInspectionError.submodule(path) }
            let url = workspace.appendingPathComponent(path)
            var metadata = stat()
            if lstat(url.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw DiffInspectionError.unsafePath(path)
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFREG:
                let size = Int(metadata.st_size)
                if size > limits.maxSingleFileBytes { throw DiffInspectionError.fileTooLarge(path, size) }
            case S_IFLNK:
                try inspectSymlink(url, relativePath: path, workspace: workspace)
            default:
                throw DiffInspectionError.unsupportedNode(path)
            }
        }
    }

    private func inspectCaseCollisions(git: GitSupervisor) throws {
        let allPaths = try readNULBounded(git, ["ls-files", "-z"], cap: Self.caseCollisionScanCap).stdout
            .split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        var folded: [String: String] = [:]
        for path in allPaths {
            let lower = path.lowercased()
            if let existing = folded[lower], existing != path {
                throw DiffInspectionError.caseCollision(existing, path)
            }
            folded[lower] = path
        }
    }

    private func inspectSymlink(_ url: URL, relativePath: String, workspace: URL) throws {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        guard !target.hasPrefix("/") else { throw DiffInspectionError.unsafeSymlink(relativePath) }
        let parent = url.deletingLastPathComponent()
        let lexical = parent.appendingPathComponent(target).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        guard lexical.path == root || lexical.path.hasPrefix(root + "/") else {
            throw DiffInspectionError.unsafeSymlink(relativePath)
        }
        let resolved = lexical.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw DiffInspectionError.unsafeSymlink(relativePath)
        }
    }

    private func directorySize(_ root: URL, excludingGit: Bool, stopAfter limit: Int) throws -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if excludingGit && (relative == ".git" || relative.hasPrefix(".git/")) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            if total > limit { return total }
        }
        return total
    }
}

public struct ArtifactStore: Sendable {
    public let runRoot: URL
    public let logDirectory: URL
    public let patchURL: URL

    public init(stateRoot: URL, runID: String) throws {
        runRoot = stateRoot.appendingPathComponent("artifacts/\(runID)", isDirectory: true)
        logDirectory = runRoot.appendingPathComponent("logs", isDirectory: true)
        patchURL = runRoot.appendingPathComponent("change.patch")
        try requireContained(runRoot, within: stateRoot)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    public func archive(_ inspection: DiffInspection) throws {
        try inspection.patch.write(to: patchURL, options: .atomic)
    }

    public func writeLog(name: String, execution: ProcessExecution) throws {
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        var data = Data(
            "exit=\(execution.exitCode) timed_out=\(execution.timedOut) cancelled=\(execution.cancelled) duration_ms=\(execution.durationMilliseconds)\n--- stdout ---\n".utf8
        )
        data.append(execution.stdout)
        data.append(Data("\n--- stderr ---\n".utf8))
        data.append(execution.stderr)
        try data.write(to: logDirectory.appendingPathComponent("\(safe).log"), options: .atomic)
    }

    public func writeProviderLog(
        name: String,
        outcome: ProviderExecutionOutcome,
        maximumBytes: Int
    ) throws {
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let metadata: [String: Any] = [
            "status": outcome.status.rawValue,
            "process_id": outcome.processID.map { $0 as Any } ?? NSNull(),
            "exit_code": outcome.exitCode,
            "duration_ms": outcome.durationMilliseconds,
            "stdout_truncated": outcome.stdoutTruncated,
            "stderr_truncated": outcome.stderrTruncated,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        var data = encoded
        data.append(Data("\n--- stdout ---\n".utf8))
        data.append(SecretRedactor.redact(outcome.stdout))
        data.append(Data("\n--- stderr ---\n".utf8))
        data.append(SecretRedactor.redact(outcome.stderr))
        let cap = max(0, maximumBytes)
        if data.count > cap {
            let marker = Data("\n[output truncated]\n".utf8)
            if cap >= marker.count {
                data = Data(data.prefix(cap - marker.count)) + marker
            } else {
                data = Data(marker.prefix(cap))
            }
        }
        try data.write(to: logDirectory.appendingPathComponent("\(safe).log"), options: .atomic)
    }
}
