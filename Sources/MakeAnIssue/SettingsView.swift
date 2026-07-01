import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    /// Persisted drafting-instructions guidance (D-05), defaulting to the single canonical
    /// shipped constant (D-06). Must match AppState.instructionsKey.
    @AppStorage(AppState.instructionsKey) private var instructions: String = IssueFilingConfig.defaultInstructions

    var body: some View {
        // D-09: TabView split — Shortcut tab (unchanged) + new Instructions tab.
        TabView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Push-to-Talk Shortcut")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        KeyboardShortcuts.Recorder("", name: .pushToTalk)
                            .labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Text("Shortcut") }

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drafting Instructions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        // D-10: fixed min-height, scrolls internally — window stays fixed-size.
                        TextEditor(text: $instructions)
                            .frame(minHeight: 160)
                        // D-07: Reset visibly refills the field with the shipped default and persists it.
                        Button("Reset to Default") {
                            instructions = IssueFilingConfig.defaultInstructions
                        }
                    }

                    // D-04: read-only display of the always-appended enforced contract, sourced
                    // directly from the real constants so it cannot drift from what the app appends.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(IssueFilingRunner.enforcedTrailer)
                        Text("Always-applied tool grant: \(IssueFilingConfig.claudeGitHub.allowedToolsArgument)")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Text("Instructions") }
        }
        .frame(width: 360)
        .padding()
    }
}
