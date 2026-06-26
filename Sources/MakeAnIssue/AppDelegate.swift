import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

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
        NSLog("MakeAnIssue: consumeLatestLaunchRequest called!")
        do {
            if let request = try launchRequestStore.consumeLatest() {
                NSLog("MakeAnIssue: consumed request: CWD=\(request.cwd), time=\(request.createdAtUnixSeconds)")
                appState.handleLaunchRequest(request)
            } else {
                NSLog("MakeAnIssue: no launch request file found or it was empty.")
            }
        } catch {
            NSLog("MakeAnIssue: failed to consume launch request: \(error.localizedDescription)")
        }
    }
}
