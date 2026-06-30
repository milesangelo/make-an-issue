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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.jobs.contains(where: { $0.state == .filing }) else {
            Self.sweepMCPTempFiles()
            return .terminateNow
        }
        appState.cancelAll()   // SIGTERM to all in-flight process groups immediately (D-04)
        Task { @MainActor in
            defer { NSApp.reply(toApplicationShouldTerminate: true) }   // guarantee reply on every exit path (SC-4)
            try? await Task.sleep(for: .seconds(2))   // 2s grace for docker --rm cleanup (D-04)
            appState.forceKillAllProcessTrees()        // SIGKILL any SIGTERM survivors
            Self.sweepMCPTempFiles()
        }
        return .terminateLater
    }

    /// Delete every `make-an-issue-mcp-*.json` file from `directory`.
    ///
    /// Scoped to the exact prefix + suffix to avoid touching unrelated tempfiles (T-6-06).
    /// Never throws — every file operation uses `try?`. Parameterised so tests can point
    /// it at a controlled directory instead of the real temp directory (CANCEL-03).
    static func sweepMCPTempFiles(in directory: URL = FileManager.default.temporaryDirectory) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents
            where url.lastPathComponent.hasPrefix("make-an-issue-mcp-")
               && url.lastPathComponent.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: url)
        }
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
