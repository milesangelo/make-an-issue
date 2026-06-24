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

    private let onStartRecording: () -> Void
    private let onStopRecording: () -> Void

    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound",
        onStartRecording: @escaping () -> Void = {},
        onStopRecording: @escaping () -> Void = {}
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [self] in
            MainActor.assumeIsolated {
                guard captureState == .idle else { return }
                startRecording()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [self] in
            MainActor.assumeIsolated {
                guard captureState == .recording else { return }
                stopRecording()
            }
        }
    }

    func startRecording() {
        guard captureState == .idle else { return }
        captureState = .recording
        onStartRecording()
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
