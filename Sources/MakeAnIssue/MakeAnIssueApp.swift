import SwiftUI

@main
struct MakeAnIssueApp: App {
    var body: some Scene {
        MenuBarExtra("Make an Issue", systemImage: "exclamationmark.bubble") {
            Text("Make an Issue")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
