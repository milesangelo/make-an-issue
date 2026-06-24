import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var statusText: String
    @Published var launchCWD: String?
    @Published var boundRepo: RepoBinding?
    @Published var boundRepoDisplayText: String

    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound"
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
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
