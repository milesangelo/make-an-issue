import AVFoundation
import Combine
import Foundation
import KeyboardShortcuts

enum CaptureState: Equatable {
    case idle
    case recording
    case finished
}

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option]))
}

@MainActor
final class AppState: ObservableObject {
    @Published var statusText: String
    @Published var launchCWD: String?
    @Published var boundRepo: RepoBinding?
    @Published var boundRepoDisplayText: String
    @Published var captureState: CaptureState = .idle
    @Published var micPermissionGranted: Bool = false

    private let audioRecorder: AudioRecorder
    private let onStartRecording: () -> Bool
    private let onStopRecording: () -> Void

    /// Maximum recording duration. If a key-up event is missed (focus change while
    /// held, dropped system event, menu-mode flapping), this caps the stuck
    /// "Recording…" state and auto-stops so the feature can recover. (WR-04)
    private let maxRecordingDuration: Duration
    private var recordingTimeoutTask: Task<Void, Never>?

    /// Convenience init for the running app: wires a real AudioRecorder into the seam.
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
    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound",
        onStartRecording: @escaping () -> Bool,
        onStopRecording: @escaping () -> Void,
        audioRecorder: AudioRecorder = AudioRecorder(),
        maxRecordingDuration: Duration = .seconds(120)
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
        self.audioRecorder = audioRecorder
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording
        self.maxRecordingDuration = maxRecordingDuration

        // Route encode/IO errors that occur after recording starts back into the
        // state machine. The delegate fires on a background audio thread, so hop
        // to the main actor before mutating @Published state.
        audioRecorder.onRecordingError = { [weak self] error in
            Task { @MainActor in
                self?.handleRecordingError(error)
            }
        }

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [self] in
            MainActor.assumeIsolated {
                guard captureState != .recording else { return }
                startRecording()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [self] in
            MainActor.assumeIsolated {
                guard captureState == .recording else { return }
                stopRecording()
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
        captureState = .finished
    }

    /// Recovery path for a stuck recording (missed key-up). Auto-stops and returns
    /// to .finished so a fresh push-to-talk can begin. (WR-04)
    func recordingDidTimeout() {
        guard captureState == .recording else { return }
        recordingTimeoutTask = nil
        onStopRecording()
        captureState = .finished
        statusText = "Recording stopped — maximum duration reached"
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
