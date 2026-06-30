import SwiftUI

@main
struct MakeAnIssueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // NSStatusItem owned by AppDelegate replaces MenuBarExtra.
        // Settings scene is a required protocol-conformance placeholder;
        // the real window is the self-owned NSWindowController in AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
