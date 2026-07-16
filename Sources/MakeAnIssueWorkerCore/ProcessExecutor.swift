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
    public let standardInputFile: URL?
    public let cancellation: ProcessCancellation?

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Int = 300,
        terminationGraceSeconds: Int = 5,
        maximumOutputBytes: Int = 1_048_576,
        standardInputFile: URL? = nil,
        cancellation: ProcessCancellation? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        self.maximumOutputBytes = maximumOutputBytes
        self.standardInputFile = standardInputFile
        self.cancellation = cancellation
    }
}

public final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        requested = true
    }

    public var isCancellationRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }
}

public struct ProcessExecution: Equatable, Sendable {
    public let processID: Int32?
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    public let cancelled: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let durationMilliseconds: Int64

    public init(
        processID: Int32? = nil,
        exitCode: Int32,
        stdout: Data,
        stderr: Data,
        timedOut: Bool,
        cancelled: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        durationMilliseconds: Int64 = 0
    ) {
        self.processID = processID
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.durationMilliseconds = durationMilliseconds
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
        let startedAt = DispatchTime.now()
        if request.cancellation?.isCancellationRequested == true {
            return ProcessExecution(
                exitCode: -SIGTERM,
                stdout: Data(),
                stderr: Data(),
                timedOut: false,
                cancelled: true,
                durationMilliseconds: 0
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = request.environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var inputHandle: FileHandle?

        if let inputFile = request.standardInputFile {
            do {
                inputHandle = try FileHandle(forReadingFrom: inputFile)
                process.standardInput = inputHandle
            } catch {
                return ProcessExecution(
                    exitCode: -1,
                    stdout: Data(),
                    stderr: Data(error.localizedDescription.utf8),
                    timedOut: false,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                )
            }
        }
        defer { try? inputHandle?.close() }

        do {
            try process.run()
        } catch {
            return ProcessExecution(
                exitCode: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8),
                timedOut: false,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt)
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
        // Dedicated threads rather than DispatchQueue.global(): these closures block for the whole
        // command lifetime, and the shared concurrent pool can be saturated by unrelated blocked
        // work elsewhere in the process. If the exit-wait closure can't get scheduled, the semaphore
        // never signals and a fast command is spuriously declared timed out and killed. A detached
        // thread is guaranteed to run immediately, so completion detection cannot be starved.
        let outputGroup = DispatchGroup()
        nonisolated(unsafe) var stdout = Data()
        nonisolated(unsafe) var stderr = Data()
        outputGroup.enter()
        Thread.detachNewThread {
            stdout = Self.drain(stdoutPipe.fileHandleForReading, cap: cap, deadline: drainDeadline)
            outputGroup.leave()
        }
        outputGroup.enter()
        Thread.detachNewThread {
            stderr = Self.drain(stderrPipe.fileHandleForReading, cap: cap, deadline: drainDeadline)
            outputGroup.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            process.waitUntilExit()
            exited.signal()
        }
        var timedOut = false
        var cancelled = false
        let timeoutDeadline = startedAt + .seconds(request.timeoutSeconds)
        while true {
            if exited.wait(timeout: .now()) == .success { break }
            if request.cancellation?.isCancellationRequested == true {
                cancelled = true
                Self.terminateProcessGroup(
                    processID,
                    exited: exited,
                    graceSeconds: request.terminationGraceSeconds
                )
                break
            }
            let now = DispatchTime.now()
            if now >= timeoutDeadline {
                timedOut = true
                Self.terminateProcessGroup(
                    processID,
                    exited: exited,
                    graceSeconds: request.terminationGraceSeconds
                )
                break
            }
            let nextPoll = min(timeoutDeadline, now + .milliseconds(50))
            if exited.wait(timeout: nextPoll) == .success { break }
        }
        // The child is gone (or unreachable). Give the drains a bounded grace to flush buffered
        // output, then force them to stop so a descendant that escaped the process group and still
        // holds the write-end can neither deadlock outputGroup.wait nor stretch the call to the
        // absolute ceiling above.
        drainDeadline.reduce(to: .now() + .seconds(request.terminationGraceSeconds))
        outputGroup.wait()
        return ProcessExecution(
            processID: processID,
            exitCode: timedOut ? -SIGKILL : (cancelled ? -SIGTERM : process.terminationStatus),
            stdout: Data(stdout.prefix(cap)),
            stderr: Data(stderr.prefix(cap)),
            timedOut: timedOut,
            cancelled: cancelled,
            stdoutTruncated: stdout.count > cap,
            stderrTruncated: stderr.count > cap,
            durationMilliseconds: Self.elapsedMilliseconds(since: startedAt)
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

    private static func terminateProcessGroup(
        _ pid: pid_t,
        exited: DispatchSemaphore,
        graceSeconds: Int
    ) {
        signalChild(pid, signal: SIGTERM)
        if exited.wait(timeout: .now() + .seconds(graceSeconds)) == .timedOut {
            signalChild(pid, signal: SIGKILL)
            _ = exited.wait(timeout: .now() + .seconds(5))
        }
    }

    private static func elapsedMilliseconds(since start: DispatchTime) -> Int64 {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Int64(elapsed / 1_000_000)
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

    static func provider(
        home: URL,
        temporaryDirectory: URL,
        workspace: URL,
        supervisorEnvironment: [String: String]
    ) -> [String: String] {
        var result = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workspace.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": temporaryDirectory.path,
        ]
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] {
            if let value = supervisorEnvironment[key] { result[key] = value }
        }
        return result
    }
}
