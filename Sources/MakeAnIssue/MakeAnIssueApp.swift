import SwiftUI

@main
struct MakeAnIssueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Make an Issue", systemImage: "exclamationmark.bubble") {
            MenuView()
                .environmentObject(appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}
