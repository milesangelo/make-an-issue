import SwiftUI

@main
struct MakeAnIssueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        let appState = AppState()
        AppDelegate.sharedAppState = appState
        _appState = StateObject(wrappedValue: appState)
    }

    var body: some Scene {
        MenuBarExtra("Make an Issue", systemImage: "exclamationmark.bubble") {
            MenuView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
