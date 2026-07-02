import Foundation
import Darwin

/// The result of a CLI process execution.
enum CLIResult {
    /// Process exited 0 — stdout and stderr are both captured separately (D-08).
    case success(stdout: String, stderr: String, exitCode: Int32)
    /// Process exited non-zero.
    case failed(exitCode: Int32, stderr: String)
    /// Process was still running when the timeout fired; partial output is discarded.
    case timeout
}

/// Runs a command through `/bin/zsh -lc` and returns the result asynchronously.
///
/// Safe concurrent pipe drain: both stdout and stderr are attached to separate
/// `readabilityHandler` closures before `process.run()` so neither pipe fills the
/// OS pipe buffer (~64 KB) and deadlocks the writer (Pitfall 1 from research).
///
/// Single-resume guarantee: a lock-backed `RunState` shared between the
/// `readabilityHandler` callbacks, `terminationHandler`, the spawn-failure path,
/// and the timeout `Task` ensures the `CheckedContinuation` is resumed exactly
/// once even when `process.terminate()` and natural exit race (Pitfall 2 / T-03-03).
struct CLIRunner {

    /// Shared mutable state for one `run`. A single `NSLock` gives two guarantees the
    /// previous `nonisolated(unsafe)` flags could not (CR-01, WR-01):
    ///   1. `claim()` is an atomic check-then-act, so exactly one of the three
    ///      concurrent completion paths (terminationHandler, timeout Task,
    ///      spawn-failure) ever resumes the continuation — no double-resume trap.
    ///   2. Output appends and the final decode happen under the same lock, so the
    ///      decoded bytes have a happens-before edge and cannot tear or race.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var resumed = false

        func appendStdout(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            stdoutData.append(chunk)
        }

        func appendStderr(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            stderrData.append(chunk)
        }

        /// Atomically claims the single resume slot. The first caller receives the
        /// decoded `(stdout, stderr)` snapshot; every later caller receives `nil`
        /// and must not touch the continuation.
        func claim() -> (stdout: String, stderr: String)? {
            lock.lock(); defer { lock.unlock() }
            guard !resumed else { return nil }
            resumed = true
            let out = String(data: stdoutData, encoding: .utf8) ?? ""
            let err = String(data: stderrData, encoding: .utf8) ?? ""
            return (out, err)
        }
    }

    /// Run `command` through `/bin/zsh -lc` with separate stdout/stderr capture and
    /// a hard timeout.
    ///
    /// - Parameters:
    ///   - command: Shell command string, passed verbatim as the `-lc` argument.
    ///   - workingDirectory: Optional directory to set as the subprocess's cwd.
    ///   - environment: Optional dictionary of environment variables merged over the
    ///     inherited process environment. The caller's keys take precedence. Use this
    ///     to pass secrets (e.g. GitHub tokens) without embedding them in the command
    ///     string where they would be visible in `ps` output (T-04-01, Pitfall 2).
    ///     `nil` (default) leaves the inherited environment unchanged — all existing
    ///     call sites remain source-compatible and behaviorally unchanged.
    ///   - timeout: Hard wall-clock limit; the process is terminated and `.timeout`
    ///              is returned if this elapses. Default: 120 s (D-12).
    ///   - onSpawn: Optional callback fired immediately after the subprocess starts,
    ///              with its process group id (pid_t). The caller can store this pgid
    ///              for quit-time force-kill (CANCEL-03 prep). `@Sendable` because
    ///              `run` executes off the main actor and consumers (e.g. AppState in
    ///              06-03) hop to `@MainActor` when storing the pgid. Default: nil —
    ///              all existing call sites are source-compatible.
    func run(
        command: String,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120),
        onSpawn: (@Sendable (pid_t) -> Void)? = nil
    ) async -> CLIResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }
        if let extra = environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in extra { env[key] = value }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        let state = RunState()

        // Attach handlers BEFORE process.run() — Pattern 1 (safe concurrent drain).
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Empty data == EOF sentinel (Pitfall 3) — do not append.
            if !chunk.isEmpty { state.appendStdout(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { state.appendStderr(chunk) }
        }

        // Holds the timeout Task so it can be cancelled the instant the process
        // resolves normally. Without this the Task lingers sleeping the full
        // timeout (120 s default) after every run, pinning the process and pipes
        // until it wakes (WR-04).
        var timeoutTask: Task<Void, Never>?

        // Written once after process.run() succeeds; read in the onCancel closure.
        // The race where onCancel fires before pgid is written is benign: the guard
        // `capturedPGID > 0` skips the kill, and the post-run Task.isCancelled check
        // handles the case where the task was already cancelled at launch time (A5 /
        // Pitfall 5 from RESEARCH.md).
        nonisolated(unsafe) var pgid: pid_t = 0

        let result: CLIResult = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in

                    process.terminationHandler = { p in
                        // Detach handlers first so no stale chunk arrives after exit.
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        // GCD does not guarantee every readabilityHandler callback for
                        // buffered pipe data has run before terminationHandler fires.
                        // Synchronously drain whatever remained buffered at exit so the
                        // tail of the output (for this app, the end of the transcript)
                        // is never truncated (WR-01).
                        let restOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        if !restOut.isEmpty { state.appendStdout(restOut) }
                        let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        if !restErr.isEmpty { state.appendStderr(restErr) }

                        guard let (out, err) = state.claim() else { return }

                        if p.terminationStatus == 0 {
                            continuation.resume(
                                returning: .success(stdout: out, stderr: err, exitCode: 0))
                        } else {
                            continuation.resume(
                                returning: .failed(exitCode: p.terminationStatus, stderr: err))
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        // Spawn failure (executable not found, permission denied, etc.)
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        guard state.claim() != nil else { return }
                        continuation.resume(
                            returning: .failed(exitCode: -1, stderr: error.localizedDescription))
                        return
                    }

                    // Store the pgid and notify the caller immediately after launch.
                    pgid = process.processIdentifier
                    onSpawn?(pgid)

                    // Pre-launch cancel race (Pitfall 5): if the enclosing Task was
                    // already cancelled before process.run() completed, onCancel fired
                    // with pgid=0 and skipped the kill. Send SIGTERM now that the pgid
                    // is set, so the process is not left running in the cancelled state.
                    if Task.isCancelled && pgid > 0 {
                        kill(-pgid, SIGTERM)
                    }

                    // Timeout Task — mirrors AppState.scheduleRecordingTimeout (D-12).
                    timeoutTask = Task {
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        // Claim the resume slot BEFORE terminating, so we deterministically
                        // win the race against the terminationHandler that terminate() will
                        // fire. If the process already exited, claim() returns nil and we
                        // leave the already-delivered result untouched.
                        guard state.claim() != nil else { return }
                        // Send SIGTERM to the whole process tree (zsh → claude → docker run)
                        // via a group-directed signal (negative identifier). Using a single-PID
                        // kill would reach only zsh, orphaning claude and any docker container.
                        // Guard processIdentifier > 0 so a never-launched process (pid=0) cannot
                        // accidentally broadcast to the caller's own process group (T-6-01 /
                        // RESEARCH Discretion Item 1).
                        if process.processIdentifier > 0 {
                            kill(-process.processIdentifier, SIGTERM)
                        }
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(returning: .timeout)

                        // Escalate to SIGKILL if the child ignores SIGTERM (or is
                        // mid-exec of a wrapper that re-spawns) and is still running
                        // after a short grace period, so the whole tree (zsh → claude →
                        // docker run) is reaped rather than lingering after `run` returns.
                        // The negative identifier broadcasts to the entire process group.
                        // The continuation is already resolved with .timeout; this only
                        // force-reaps the process tree. (WR-05 / RESEARCH Discretion Item 1)
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            if process.isRunning && process.processIdentifier > 0 {
                                kill(-process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
            },
            onCancel: {
                // Fires synchronously when the enclosing Task is cancelled.
                // This closure sends signals ONLY — it must NOT call state.claim()
                // or resume the continuation. The terminationHandler (which fires
                // when the signalled process exits) is the sole claim+resume path,
                // preserving the single-resume invariant (SC-4 / T-6-04).
                let capturedPGID = pgid
                guard capturedPGID > 0 else { return }
                // SIGTERM first so docker run can stop the container and trigger
                // --rm cleanup before any force-kill (CANCEL-01 / Pitfall 1).
                kill(-capturedPGID, SIGTERM)
                // Schedule bounded SIGKILL escalation: if SIGTERM is ignored, the
                // whole process group is force-reaped after the 2s grace window.
                // Task.detached so the escalation outlives the cancelled calling task.
                Task.detached {
                    try? await Task.sleep(for: .seconds(2))
                    kill(-capturedPGID, SIGKILL)
                }
            }
        )

        // Normal completion path: cancel the still-sleeping timeout Task so it does
        // not linger (WR-04). A no-op if the timeout already fired.
        timeoutTask?.cancel()
        return result
    }
}
