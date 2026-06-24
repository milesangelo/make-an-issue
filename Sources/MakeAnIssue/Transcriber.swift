import Foundation

/// Errors that the Transcriber can throw at prepare() or run() time.
enum TranscriberError: Error, Equatable {
    /// The configured ASR command is empty or whitespace-only (D-03).
    case emptyCommand
    /// The command does not contain the required `{wav}` token (D-05).
    case missingWavToken
    /// The ASR process exited with a non-zero status.
    case asrFailed(exitCode: Int32, stderr: String)
    /// The ASR process did not finish within the 120s timeout (D-12).
    case asrTimedOut
    /// The ASR process exited 0 but produced no output after trimming (D-07).
    case emptyTranscript
}

/// Validates the configured ASR command, substitutes the shell-safe `{wav}` path,
/// runs the command via `CLIRunner`, and trims the resulting stdout into a transcript.
struct Transcriber {

    // MARK: - prepare

    /// Validate `command` and substitute `{wav}` with a POSIX single-quoted absolute path.
    ///
    /// This is a pure function with no I/O — fully unit-testable without spawning a process.
    ///
    /// - Parameters:
    ///   - command: The user-configured ASR command string (e.g. `whisper {wav} --model base`).
    ///   - wavURL: Absolute URL to the WAV file (e.g. `…/Application Support/MakeAnIssue/latest.wav`).
    /// - Returns: The substituted command string ready to pass to `/bin/zsh -lc`.
    /// - Throws:
    ///   - `TranscriberError.emptyCommand` when `command` is empty or whitespace-only (D-03).
    ///   - `TranscriberError.missingWavToken` when `command` has no `{wav}` literal (D-05).
    static func prepare(command: String, wavURL: URL) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriberError.emptyCommand
        }
        guard command.contains("{wav}") else {
            throw TranscriberError.missingWavToken
        }
        // POSIX single-quote escaping: end quote, insert literal single-quote, reopen quote.
        // Result: path with spaces or quotes survives as a single shell word (Pattern 3, T-03-05).
        let escapedPath = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let quoted = "'\(escapedPath)'"
        return command.replacingOccurrences(of: "{wav}", with: quoted)
    }

    // MARK: - run

    /// Prepare the command, run it via `CLIRunner`, and return the trimmed transcript.
    ///
    /// - Parameters:
    ///   - command: The user-configured ASR command string.
    ///   - wavURL: Absolute URL to the WAV file to transcribe.
    /// - Returns: The trimmed stdout of the ASR process.
    /// - Throws: `TranscriberError` for every failure mode (emptyCommand, missingWavToken,
    ///   asrTimedOut, asrFailed, emptyTranscript).
    static func run(command: String, wavURL: URL) async throws -> String {
        let substituted = try prepare(command: command, wavURL: wavURL)

        let result = await CLIRunner().run(command: substituted)

        switch result {
        case .timeout:
            throw TranscriberError.asrTimedOut

        case .failed(let exitCode, let stderr):
            throw TranscriberError.asrFailed(exitCode: exitCode, stderr: stderr)

        case .success(let stdout, _, _):
            // D-07: trim leading/trailing whitespace only — verbatim otherwise.
            // D-08: never read or merge stderr into the transcript.
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw TranscriberError.emptyTranscript
            }
            return trimmed
        }
    }
}
