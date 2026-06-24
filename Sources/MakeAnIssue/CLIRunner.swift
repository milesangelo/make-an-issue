import Foundation

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
/// Single-resume guarantee: a `resumed` flag shared between `terminationHandler`
/// and the timeout `Task` ensures the `CheckedContinuation` is resumed exactly
/// once even when `process.terminate()` triggers both concurrently (Pitfall 2 /
/// T-03-03).
struct CLIRunner {

    /// Run `command` through `/bin/zsh -lc` with separate stdout/stderr capture and
    /// a hard timeout.
    ///
    /// - Parameters:
    ///   - command: Shell command string, passed verbatim as the `-lc` argument.
    ///   - workingDirectory: Optional directory to set as the subprocess's cwd.
    ///   - timeout: Hard wall-clock limit; the process is terminated and `.timeout`
    ///              is returned if this elapses. Default: 120 s (D-12).
    func run(
        command: String,
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(120)
    ) async -> CLIResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // Accumulators written by the readabilityHandler callbacks.
        // Foundation fires each handler on a private background Dispatch queue;
        // the handlers are detached (set to nil) before any resume so the
        // accumulated data is stable when we decode it.
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()

        // Attach handlers BEFORE process.run() — Pattern 1 (safe concurrent drain).
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Empty data == EOF sentinel (Pitfall 3) — do not append.
            if !chunk.isEmpty { stdoutData.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrData.append(chunk) }
        }

        // Single-resume guard: checked and set inside terminationHandler (which
        // Foundation serialises) and in the timeout Task (which checks before
        // setting). Only one path wins. (Pitfall 2 / Pattern 2)
        nonisolated(unsafe) var resumed = false

        return await withCheckedContinuation { continuation in

            process.terminationHandler = { p in
                // Detach handlers first so no stale chunk arrives after exit.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                guard !resumed else { return }
                resumed = true

                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""

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
                guard !resumed else { return }
                resumed = true
                continuation.resume(
                    returning: .failed(exitCode: -1, stderr: error.localizedDescription))
                return
            }

            // Timeout Task — mirrors AppState.scheduleRecordingTimeout (D-12).
            Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, !resumed else { return }
                resumed = true
                process.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: .timeout)
            }
        }
    }
}
