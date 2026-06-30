import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private let launchRequestStore = LaunchRequestStore()

    // Phase 7 additions — AppKit status-item shell
    private var statusItem: NSStatusItem!           // must be stored property; local var = released + icon vanishes
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        consumeLatestLaunchRequest()
        setUpStatusItem()                       // NEW
        observeCaptureStateForIndicator()       // NEW — after setUpStatusItem so contentView hierarchy exists
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
        // Sweep synchronously here too — the async teardown Task below may not finish its
        // sweep before the process is reaped on .terminateLater quit (the MCP config is
        // already loaded by the spawned process, so deleting it during teardown is safe).
        Self.sweepMCPTempFiles()
        Task { @MainActor in
            defer { NSApp.reply(toApplicationShouldTerminate: true) }   // guarantee reply on every exit path (SC-4)
            try? await Task.sleep(for: .seconds(2))   // 2s grace for docker --rm cleanup (D-04)
            appState.forceKillAllProcessTrees()        // SIGKILL any SIGTERM survivors
            Self.sweepMCPTempFiles()                   // backstop for any file written after the synchronous sweep
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

    // MARK: - Status Item Shell (Phase 7)

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.bubble",
                                           accessibilityDescription: "Make an Issue")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuView().environmentObject(appState))
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            showRightClickMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func showRightClickMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings\u{2026}",
                                      action: #selector(showSettingsWindow),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)
        // assign-popUp-clear: positions menu correctly; clears so button.action fires next left-click
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showSettingsWindow() {
        if let controller = settingsWindowController, controller.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingController = NSHostingController(
            rootView: SettingsView().environmentObject(appState))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)   // BEFORE makeKeyAndOrderFront (Pitfall 8/9)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Recording Indicator (Phase 7, FEEDBACK-02)

    private func observeCaptureStateForIndicator() {
        appState.$captureState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.updateRecordingIndicator(state == .recording)
            }
            .store(in: &cancellables)
    }

    private func updateRecordingIndicator(_ isRecording: Bool) {
        let contentView = statusItem.button?.superview?.window?.contentView
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = isRecording
            ? NSColor.systemRed.withAlphaComponent(0.3).cgColor
            : NSColor.clear.cgColor
        contentView?.layer?.cornerRadius = 4
    }
}
