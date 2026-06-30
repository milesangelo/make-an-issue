import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
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
        .frame(width: 360)
        .padding()
    }
}
