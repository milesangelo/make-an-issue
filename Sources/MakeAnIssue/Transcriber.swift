import Foundation

/// Errors that the Transcriber can throw.
enum TranscriberError: Error, Equatable {
    /// The bundled whisper-cli binary or ggml model was not found in Contents/Resources (D-09).
    case bundledResourcesMissing(detail: String)
    /// The ASR process exited with a non-zero status.
    case asrFailed(exitCode: Int32, stderr: String)
    /// The ASR process did not finish within the 120s timeout.
    case asrTimedOut
    /// The ASR process exited 0 but produced no output after trimming (D-07).
    case emptyTranscript
}

/// Resolves the bundled whisper-cli binary and model, builds the invocation command,
/// and runs it via the generic CLIRunner, returning the trimmed transcript.
struct Transcriber {

    // MARK: - Resource Resolution

    /// Resolve the bundled whisper-cli binary URL.
    ///
    /// - Parameter resourceBase: Override the resource base directory.
    ///   Defaults to `nil`, which resolves via `Bundle.main.resourceURL` (the production path).
    ///   Pass a temporary directory in unit tests to avoid needing the real bundle.
    /// - Throws: `TranscriberError.bundledResourcesMissing` when the base is nil or the file is absent.
    static func bundledBinaryURL(resourceBase: URL? = nil) throws -> URL {
        guard let base = resourceBase ?? Bundle.main.resourceURL else {
            throw TranscriberError.bundledResourcesMissing(detail: "Bundle.main.resourceURL is nil")
        }
        let url = base.appendingPathComponent("whisper-cli")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriberError.bundledResourcesMissing(detail: "whisper-cli not found in bundle Resources")
        }
        return url
    }

    /// Resolve the bundled ggml-small.en.bin model URL.
    ///
    /// - Parameter resourceBase: Override the resource base directory.
    ///   Defaults to `nil`, which resolves via `Bundle.main.resourceURL`.
    /// - Throws: `TranscriberError.bundledResourcesMissing` when the base is nil or the file is absent.
    static func bundledModelURL(resourceBase: URL? = nil) throws -> URL {
        guard let base = resourceBase ?? Bundle.main.resourceURL else {
            throw TranscriberError.bundledResourcesMissing(detail: "Bundle.main.resourceURL is nil")
        }
        let url = base.appendingPathComponent("ggml-small.en.bin")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriberError.bundledResourcesMissing(detail: "ggml-small.en.bin not found in bundle Resources")
        }
        return url
    }

    // MARK: - run

    /// Resolve the bundled binary and model, build the whisper-cli argv, run via CLIRunner,
    /// and return the trimmed transcript.
    ///
    /// - Parameters:
    ///   - wavURL: Absolute URL to the WAV file to transcribe.
    ///   - resourceBase: Override the resource directory (nil → Bundle.main.resourceURL).
    ///     Pass a temporary directory in tests to avoid the real ~466 MB bundle resources.
    /// - Returns: The trimmed stdout of the whisper-cli process.
    /// - Throws: `TranscriberError` for every failure mode.
    static func run(wavURL: URL, resourceBase: URL? = nil) async throws -> String {
        let binaryURL = try bundledBinaryURL(resourceBase: resourceBase)
        let modelURL  = try bundledModelURL(resourceBase: resourceBase)

        // POSIX single-quote escape all three paths so spaces and shell metacharacters
        // cannot break out of their argument (T-03-13, ASVS V5).
        let escapedBin   = binaryURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedModel = modelURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedWav   = wavURL.path.replacingOccurrences(of: "'", with: "'\\''")

        // D-07: -nt suppresses timestamps so stdout is the clean transcript.
        // -l en: English (matches the .en model, D-02). -t 4: explicit thread count.
        let command = "'\(escapedBin)' -m '\(escapedModel)' -f '\(escapedWav)' -l en -nt -t 4"

        let result = await CLIRunner().run(command: command)

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
