import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var statusText: String
    @Published var launchCWD: String?
    @Published var boundRepoDisplayText: String

    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepoDisplayText: String = "No repository bound"
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepoDisplayText = boundRepoDisplayText
    }

    func handleLaunchRequest(_ request: LaunchRequest) {
        launchCWD = request.cwd
        statusText = "Launch request received"
        boundRepoDisplayText = request.cwd
    }
}
