import SwiftUI

@main
struct MakeAnIssueApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Make an Issue", systemImage: "exclamationmark.bubble") {
            MenuView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
