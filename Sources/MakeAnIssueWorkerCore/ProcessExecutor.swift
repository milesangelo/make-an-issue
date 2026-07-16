import Darwin
import Foundation

public struct ProcessRequest: Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environment: [String: String]
    public let timeoutSeconds: Int
    public let terminationGraceSeconds: Int
    public let maximumOutputBytes: Int

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Int = 300,
        terminationGraceSeconds: Int = 5,
        maximumOutputBytes: Int = 1_048_576
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct ProcessExecution: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    public let stdoutTruncated: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool, stdoutTruncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public protocol ProcessExecuting: Sendable {
    func resolveExecutable(_ name: String, environment: [String: String]) -> String?
    func execute(_ request: ProcessRequest) -> ProcessExecution
}

public struct FoundationProcessExecutor: ProcessExecuting {
    public init() {}

    public func resolveExecutable(_ name: String, environment: [String: String]) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func execute(_ request: ProcessRequest) -> ProcessExecution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = request.environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessExecution(
                exitCode: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8),
                timedOut: false
            )
        }

        let processID = process.processIdentifier
        _ = setpgid(processID, processID)
        let cap = max(0, request.maximumOutputBytes)
        let outputGroup = DispatchGroup()
        nonisolated(unsafe) var stdout = Data()
        nonisolated(unsafe) var stderr = Data()
        outputGroup.enter()
        DispatchQueue.global().async {
            stdout = Self.drain(stdoutPipe.fileHandleForReading, cap: cap)
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global().async {
            stderr = Self.drain(stderrPipe.fileHandleForReading, cap: cap)
            outputGroup.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + .seconds(request.timeoutSeconds)) == .timedOut {
            timedOut = true
            Self.signalChild(processID, signal: SIGTERM)
            if exited.wait(timeout: .now() + .seconds(request.terminationGraceSeconds)) == .timedOut {
                Self.signalChild(processID, signal: SIGKILL)
                _ = exited.wait(timeout: .now() + .seconds(5))
            }
        }
        outputGroup.wait()
        return ProcessExecution(
            exitCode: timedOut ? -SIGKILL : process.terminationStatus,
            stdout: Data(stdout.prefix(cap)),
            stderr: Data(stderr.prefix(cap)),
            timedOut: timedOut,
            stdoutTruncated: stdout.count > cap
        )
    }

    private static func drain(_ handle: FileHandle, cap: Int) -> Data {
        var collected = Data()
        while true {
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            if collected.count <= cap { collected.append(chunk) }
        }
        return collected
    }

    private static func signalChild(_ pid: pid_t, signal: Int32) {
        _ = kill(-pid, signal)
        _ = kill(pid, signal)
    }
}

enum WorkerEnvironment {
    static func minimal(home: URL, path: String? = nil, extra: [String: String] = [:]) -> [String: String] {
        var result = [
            "HOME": home.path,
            "PATH": path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "GIT_TERMINAL_PROMPT": "0",
        ]
        for (key, value) in extra { result[key] = value }
        return result
    }
}
