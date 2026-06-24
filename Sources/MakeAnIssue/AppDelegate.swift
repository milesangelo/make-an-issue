import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedAppState: AppState?

    private let launchRequestStore = LaunchRequestStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        consumeLatestLaunchRequest()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        consumeLatestLaunchRequest()
        sender.activate(ignoringOtherApps: true)
        return true
    }

    private func consumeLatestLaunchRequest() {
        guard let request = try? launchRequestStore.consumeLatest() else {
            return
        }

        Self.sharedAppState?.handleLaunchRequest(request)
    }
}
