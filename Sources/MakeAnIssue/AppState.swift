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
}

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option]))
}

@MainActor
final class AppState: ObservableObject {
    /// Shared UserDefaults key for the ASR command — must match @AppStorage in MenuView (Pitfall 5).
    static let asrCommandKey = "asrCommand"

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
        }
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
                guard let self, self.captureState != .recording else { return }
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
        // Allow starting from .idle or .finished (a new press after a completed
        // recording). Only an in-progress recording suppresses a fresh start —
        // this also enforces D-04 (ignore key repeats while already recording).
        guard captureState != .recording else { return }
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
                    self.captureState = .finished
                    NSLog("MakeAnIssue transcript: \(text)")   // D-09
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
