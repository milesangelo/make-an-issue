import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var appState: AppState

    // Persisted via the shared key so MenuView's @AppStorage and AppState's
    // UserDefaults.standard.string(forKey:) read and write the same value (Pitfall 5).
    @AppStorage(AppState.asrCommandKey) private var asrCommand: String = ""

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

            if appState.captureState == .recording {
                // Click-to-stop recovery affordance in case a push-to-talk key-up
                // event is missed and recording would otherwise stay stuck. (WR-04)
                Button("Stop Recording") {
                    appState.stopRecording()
                }
            }

            // Transcript display — selectable text block shown after successful transcription (D-09, TRANSCRIBE-02).
            if let transcript = appState.transcript {
                LabeledContent("Transcript") {
                    Text(transcript)
                        .textSelection(.enabled)
                }
            }

            KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)

            // ASR command field — persisted via @AppStorage using the shared key (D-01, Pitfall 5).
            // The {wav} placeholder is where the app inserts the absolute path to latest.wav (D-04).
            LabeledContent("ASR Command") {
                TextField("e.g. whisper {wav} --model base", text: $asrCommand)
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
        .onDisappear {
            // KeyboardShortcuts pauses the global Carbon hotkey and falls back to a
            // focus-only local key monitor whenever it believes a menu is open
            // (HotKey `.menuOpen` mode). Opening this MenuBarExtra window fires
            // NSMenu.didBeginTracking but no balanced didEndTracking on close, so
            // `isMenuOpen` sticks true and push-to-talk stops firing while another
            // app is focused. Post the end-tracking notification on close to restore
            // global (.normal) mode.
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        }
    }

    private var captureStateLabel: String {
        switch appState.captureState {
        case .idle:          return "Idle"
        case .recording:     return "Recording…"
        case .transcribing:  return "Transcribing…"
        case .finished:      return "Done"
        }
    }
}
