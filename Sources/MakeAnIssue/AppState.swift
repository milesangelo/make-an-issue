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

    private let audioRecorder: AudioRecorder
    private let onStartRecording: () -> Bool
    private let onStopRecording: () -> Void

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
        audioRecorder: AudioRecorder = AudioRecorder()
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
        self.audioRecorder = audioRecorder
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording

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
        Task {
            await AppState.requestMicrophonePermission()
        }
    }

    private static func requestMicrophonePermission() async {
        if #available(macOS 14, *) {
            _ = await AVAudioApplication.requestRecordPermission()
        } else {
            // macOS 13: AVAudioSession is unavailable on macOS; use AVCaptureDevice
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func startRecording() {
        // Allow starting from .idle or .finished (a new press after a completed
        // recording). Only an in-progress recording suppresses a fresh start —
        // this also enforces D-04 (ignore key repeats while already recording).
        guard captureState != .recording else { return }
        guard onStartRecording() else {
            statusText = "Recording failed — check microphone permission"
            captureState = .idle
            return
        }
        captureState = .recording
    }

    func stopRecording() {
        guard captureState == .recording else { return }
        onStopRecording()
        captureState = .finished
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
