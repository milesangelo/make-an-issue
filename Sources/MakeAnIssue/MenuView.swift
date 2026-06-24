import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make an Issue")
                .font(.headline)

            Divider()

            LabeledContent("Status", value: appState.statusText)
            LabeledContent("Bound Repo", value: appState.boundRepoDisplayText)
        }
        .padding()
        .frame(width: 280, alignment: .leading)
    }
}
