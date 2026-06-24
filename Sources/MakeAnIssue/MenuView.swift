import KeyboardShortcuts
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make an Issue")
                .font(.headline)

            Divider()

            LabeledContent("Status", value: appState.statusText)

            if let boundRepo = appState.boundRepo {
                LabeledContent("Repository", value: boundRepo.displayName)
                Text(boundRepo.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                LabeledContent("Repository", value: appState.boundRepoDisplayText)
            }

            LabeledContent("Recording", value: captureStateLabel)

            KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }

    private var captureStateLabel: String {
        switch appState.captureState {
        case .idle:      return "Idle"
        case .recording: return "Recording…"
        case .finished:  return "Done"
        }
    }
}
