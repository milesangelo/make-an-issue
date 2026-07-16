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

        // Absolute ceiling so a drain can never outlive the command budget even if a descendant
        // that escaped the process group keeps the pipe write-end open past the child's exit.
        let drainDeadline = DeadlineBox(
            .now() + .seconds(request.timeoutSeconds + request.terminationGraceSeconds + 5)
        )
        let outputGroup = DispatchGroup()
        nonisolated(unsafe) var stdout = Data()
        nonisolated(unsafe) var stderr = Data()
        outputGroup.enter()
        DispatchQueue.global().async {
            stdout = Self.drain(stdoutPipe.fileHandleForReading, cap: cap, deadline: drainDeadline)
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global().async {
            stderr = Self.drain(stderrPipe.fileHandleForReading, cap: cap, deadline: drainDeadline)
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
        // The child is gone (or unreachable). Give the drains a bounded grace to flush buffered
        // output, then force them to stop so a descendant that escaped the process group and still
        // holds the write-end can neither deadlock outputGroup.wait nor stretch the call to the
        // absolute ceiling above.
        drainDeadline.reduce(to: .now() + .seconds(request.terminationGraceSeconds))
        outputGroup.wait()
        return ProcessExecution(
            exitCode: timedOut ? -SIGKILL : process.terminationStatus,
            stdout: Data(stdout.prefix(cap)),
            stderr: Data(stderr.prefix(cap)),
            timedOut: timedOut,
            stdoutTruncated: stdout.count > cap
        )
    }

    private static func drain(_ handle: FileHandle, cap: Int, deadline: DeadlineBox) -> Data {
        let descriptor = handle.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL, 0)
        if currentFlags >= 0 { _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let now = DispatchTime.now()
            let limit = deadline.value
            guard now < limit else { break }
            let remainingMillis = (limit.uptimeNanoseconds &- now.uptimeNanoseconds) / 1_000_000
            let sliceMillis = Int32(min(remainingMillis, 100))
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, max(sliceMillis, 0))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            if pollDescriptor.revents & Int16(POLLNVAL | POLLERR) != 0 { break }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break }
            if collected.count <= cap { collected.append(contentsOf: buffer[0..<count]) }
        }
        return collected
    }

    private static func signalChild(_ pid: pid_t, signal: Int32) {
        _ = kill(-pid, signal)
        _ = kill(pid, signal)
    }
}

private final class DeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: DispatchTime

    init(_ deadline: DispatchTime) { self.deadline = deadline }

    var value: DispatchTime {
        lock.lock(); defer { lock.unlock() }
        return deadline
    }

    func reduce(to candidate: DispatchTime) {
        lock.lock(); defer { lock.unlock() }
        if candidate < deadline { deadline = candidate }
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
