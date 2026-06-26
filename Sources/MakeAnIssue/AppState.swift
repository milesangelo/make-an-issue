import AVFoundation
import Combine
import Foundation
import KeyboardShortcuts

enum CaptureState: Equatable {
    case idle
    case recording
    /// ASR command is executing; results are in-flight (D-10).
    case transcribing
    case finished
    /// AI CLI is filing the issue; result is in-flight.
    case filing
}

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option]))
}

@MainActor
final class AppState: ObservableObject {
    /// Shared UserDefaults key for the ASR command — must match @AppStorage in MenuView (Pitfall 5).
    static let asrCommandKey = "asrCommand"
    /// Shared UserDefaults key for the CLI command — must match @AppStorage in MenuView (Pitfall 5).
    static let cliCommandKey = "cliCommand"

    @Published var statusText: String
    @Published var launchCWD: String?
    @Published var boundRepo: RepoBinding?
    @Published var boundRepoDisplayText: String
    @Published var captureState: CaptureState = .idle
    @Published var micPermissionGranted: Bool = false
    /// Last successful transcript text (D-09, TRANSCRIBE-02).
    @Published var transcript: String?
    /// Last transcription failure reason; cleared when a new transcription starts.
    @Published var transcriptError: String?

    // Anchors the AudioRecorder's lifetime and is the integration point for its
    // delegate callbacks (onRecordingError, wired in init). The start/stop seam
    // closures route commands; this property routes errors back. (IN-01)
    private let audioRecorder: AudioRecorder
    private let onStartRecording: () -> Bool
    private let onStopRecording: () -> Void
    /// Seam for transcription — the default wires the real Transcriber; tests inject a stub.
    private let onRunTranscription: (URL) async throws -> String
    /// Seam for issue filing — the default wires the real IssueFilingRunner; tests inject a stub.
    private let onRunIssueFiling: (String, RepoBinding) async throws -> IssueFilingResult
    /// Stored AVSpeechSynthesizer — MUST be a stored property; a local variable is deallocated
    /// before speaking completes and produces no audio (Pitfall 1 in 04-RESEARCH.md).
    private let speechSynthesizer = AVSpeechSynthesizer()
    /// Seam for spoken confirmation — when nil the default `speak(_:)` method is used;
    /// tests inject a closure to capture the spoken string without producing audio.
    private let onSpeak: ((String) -> Void)?

    /// Maximum recording duration. If a key-up event is missed (focus change while
    /// held, dropped system event, menu-mode flapping), this caps the stuck
    /// "Recording…" state and auto-stops so the feature can recover. (WR-04)
    private let maxRecordingDuration: Duration
    private var recordingTimeoutTask: Task<Void, Never>?

    /// Convenience init for the running app: wires a real AudioRecorder and Transcriber into the seams.
    convenience init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound"
    ) {
        let recorder = AudioRecorder()
        self.init(
            statusText: statusText,
            launchCWD: launchCWD,
            boundRepo: boundRepo,
            boundRepoDisplayText: boundRepoDisplayText,
            onStartRecording: recorder.start,
            onStopRecording: recorder.stop,
            audioRecorder: recorder
        )
    }

    /// Designated init: accepts explicit seam closures for testing.
    ///
    /// - Parameters:
    ///   - onRunTranscription: Closure injected for testing — default wires the real Transcriber.
    ///     Signature: `(URL) async throws -> String` (wavURL → trimmed transcript or throws TranscriberError).
    ///   - onRunIssueFiling: Closure injected for testing — default wires the real IssueFilingRunner.
    ///     Signature: `(String, RepoBinding) async throws -> IssueFilingResult`.
    ///   - onSpeak: Closure injected for testing — default calls AVSpeechSynthesizer.speak().
    ///     Allows tests to capture the spoken string without producing audio.
    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound",
        onStartRecording: @escaping () -> Bool,
        onStopRecording: @escaping () -> Void,
        audioRecorder: AudioRecorder = AudioRecorder(),
        maxRecordingDuration: Duration = .seconds(120),
        onRunTranscription: @escaping (URL) async throws -> String = { url in
            let cmd = UserDefaults.standard.string(forKey: AppState.asrCommandKey) ?? ""
            return try await Transcriber.run(command: cmd, wavURL: url)
        },
        onRunIssueFiling: @escaping (String, RepoBinding) async throws -> IssueFilingResult = { transcript, repo in
            try await IssueFilingRunner.file(transcript: transcript, repo: repo, config: .claudeGitHub, ownerRepo: nil)
        },
        onSpeak: ((String) -> Void)? = nil
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
        self.audioRecorder = audioRecorder
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording
        self.maxRecordingDuration = maxRecordingDuration
        self.onRunTranscription = onRunTranscription
        self.onRunIssueFiling = onRunIssueFiling
        self.onSpeak = onSpeak

        // Route encode/IO errors that occur after recording starts back into the
        // state machine. The delegate fires on a background audio thread, so hop
        // to the main actor before mutating @Published state.
        audioRecorder.onRecordingError = { [weak self] error in
            Task { @MainActor in
                self?.handleRecordingError(error)
            }
        }

        // [weak self] mirrors the recorder/permission closures above and avoids a
        // retain cycle through the global KeyboardShortcuts handler registry, which
        // would otherwise pin every AppState instance for the process lifetime (WR-03).
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.captureState == .idle else { return }
                self.startRecording()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.captureState == .recording else { return }
                self.stopRecording()
            }
        }

        // Request microphone permission at startup so TCC dialog appears before first recording
        Task { [weak self] in
            let granted = await AppState.requestMicrophonePermission()
            self?.micPermissionGranted = granted
            if !granted {
                self?.statusText = "Microphone access denied — enable in System Settings"
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            // macOS 13: AVAudioSession is unavailable on macOS; use AVCaptureDevice
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func startRecording() {
        // Only allow starting from .idle. This blocks re-entry during .recording
        // (D-04: ignore key repeats), .transcribing, and .filing (CR-01: a PTT
        // press during the up-to-300 s filing window must not start a new capture
        // and corrupt the in-flight state machine). .finished is transient and
        // flows straight into .filing, so it is also correctly excluded here.
        guard captureState == .idle else { return }
        guard micPermissionGranted else {
            statusText = "Microphone access denied — enable in System Settings"
            captureState = .idle
            return
        }
        guard onStartRecording() else {
            statusText = "Recording failed — check microphone permission"
            captureState = .idle
            return
        }
        captureState = .recording
        scheduleRecordingTimeout()
    }

    func stopRecording() {
        guard captureState == .recording else { return }
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        onStopRecording()
        beginTranscription()
    }

    /// Shared transition into transcription, used by both the normal key-up stop
    /// and the max-duration cap. Centralizing it means a missed key-up that hits
    /// the cap still transcribes the captured audio instead of silently discarding
    /// it (WR-02). Enters `.transcribing` synchronously (D-10), then runs the ASR
    /// command off the main actor and routes the result back.
    private func beginTranscription() {
        captureState = .transcribing   // D-10: show transcribing state immediately
        transcriptError = nil           // clear stale error from prior attempt

        guard let wavURL = audioRecorder.latestWavURL else {
            captureState = .idle
            statusText = "Transcription failed — recording not found"
            return
        }

        Task {
            do {
                let text = try await onRunTranscription(wavURL)
                await MainActor.run {
                    self.transcript = text
                    NSLog("MakeAnIssue transcript: \(text)")   // D-09
                    // .finished is transient — immediately flow into filing (Open Q2 / accepted_v1_behavior).
                    self.captureState = .finished
                    self.beginFiling()
                }
            } catch let error as TranscriberError {
                let message = Self.message(for: error)
                await MainActor.run {
                    self.transcriptError = message
                    self.statusText = message
                    self.captureState = .idle   // D-11: reset so next push-to-talk works
                }
            } catch {
                let message = "Transcription failed — \(error.localizedDescription)"
                await MainActor.run {
                    self.transcriptError = message
                    self.statusText = message
                    self.captureState = .idle
                }
            }
        }
    }

    /// Transition into issue filing, mirroring the `beginTranscription` Task structure.
    ///
    /// Called on the MainActor immediately after `transcript` is set. Requires a bound repo —
    /// if none is bound, surfaces a status message and returns to `.idle` so the next
    /// push-to-talk works. On success, speaks "created issue #N" and returns to `.idle`.
    /// On failure, sets `statusText` and returns to `.idle`.
    private func beginFiling() {
        guard let repo = boundRepo else {
            statusText = "No repository bound — cannot file"
            captureState = .idle
            return
        }
        guard let transcript = transcript else {
            statusText = "No transcript available — cannot file"
            captureState = .idle
            return
        }
        captureState = .filing   // synchronous transition visible to callers

        Task {
            do {
                let result = try await onRunIssueFiling(transcript, repo)
                await MainActor.run {
                    let text = "created issue #\(result.number)"
                    if let onSpeak = self.onSpeak {
                        onSpeak(text)
                    } else {
                        self.speak(text)
                    }
                    self.captureState = .idle
                }
            } catch let error as IssueFilingError {
                let message = Self.message(for: error)
                await MainActor.run {
                    self.statusText = message
                    self.captureState = .idle
                }
            } catch {
                let message = "Filing failed — \(error.localizedDescription)"
                await MainActor.run {
                    self.statusText = message
                    self.captureState = .idle
                }
            }
        }
    }

    /// Speak a confirmation string via native macOS TTS (FEEDBACK-01).
    ///
    /// Uses the stored `speechSynthesizer` — must be a stored property, not a local variable,
    /// so it remains alive until speaking completes (Pitfall 1 in 04-RESEARCH.md).
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        speechSynthesizer.speak(utterance)
    }

    /// Map a `TranscriberError` to a short user-facing message (D-11).
    private static func message(for error: TranscriberError) -> String {
        switch error {
        case .emptyCommand:
            return "Set your ASR command in the menu to transcribe"
        case .missingWavToken:
            return "ASR command must include {wav} — add it where the audio path goes"
        case .asrFailed(let exitCode, let stderr):
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? stderr
            return "ASR failed (exit \(exitCode))\(tail.isEmpty ? "" : " — \(tail)")"
        case .asrTimedOut:
            return "ASR timed out after 120s"
        case .emptyTranscript:
            return "ASR produced no output — check your command"
        }
    }

    /// Map an `IssueFilingError` to a short user-facing message.
    ///
    /// Only the success path speaks (v1 contract); failures surface as status text only.
    private static func message(for error: IssueFilingError) -> String {
        switch error {
        case .tokenAcquisitionFailed:
            return "Sign in to GitHub first: gh auth login"
        case .timeout:
            return "AI CLI timed out — check your internet connection"
        case .cliFailed(let exitCode, _):
            return "AI CLI failed (exit \(exitCode)) — see log"
        case .permissionDenied:
            return "Issue tool not granted — check CLI Command config"
        case .parseFailed:
            return "Couldn't confirm an issue was filed — check GitHub (is Docker running?)"
        }
    }

    /// Recovery path for a stuck recording (missed key-up). Auto-stops at the
    /// max-duration cap and transcribes whatever was captured, so a dropped key-up
    /// never silently discards the user's speech (WR-02). The state machine then
    /// follows the normal transcription path back to .finished or .idle.
    func recordingDidTimeout() {
        guard captureState == .recording else { return }
        recordingTimeoutTask = nil
        onStopRecording()
        statusText = "Recording stopped — maximum duration reached; transcribing…"
        beginTranscription()
    }

    private func scheduleRecordingTimeout() {
        recordingTimeoutTask?.cancel()
        let duration = maxRecordingDuration
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.recordingDidTimeout()
        }
    }

    /// Called when the recorder reports an encode/IO failure after recording began.
    /// Resets the state machine and surfaces a message so the UI does not remain
    /// stuck on "Recording…" with a corrupt/empty capture.
    func handleRecordingError(_ error: Error?) {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        onStopRecording()
        captureState = .idle
        statusText = "Recording failed — \(error?.localizedDescription ?? "audio error")"
    }

    func handleLaunchRequest(_ request: LaunchRequest) {
        launchCWD = request.cwd
        if let binding = RepoBinding.resolve(from: URL(fileURLWithPath: request.cwd)) {
            boundRepo = binding
            statusText = "Bound to \(binding.displayName)"
            boundRepoDisplayText = binding.displayPath
        } else {
            statusText = "No git repository found"
        }
    }
}
