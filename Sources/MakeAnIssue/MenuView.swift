import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var appState: AppState

    @AppStorage(AppState.cliCommandKey) private var cliCommand: String = "claude"

    @State private var isSettingsExpanded = false
    @State private var shortcutText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Section
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Make an Issue")
                        .font(.headline)
                    Text("Voice Issue Tracker")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                StateBadge(state: appState.captureState)
            }
            
            Divider()
            
            // Repository Card
            RepositoryCard(boundRepo: appState.boundRepo, fallbackText: appState.boundRepoDisplayText)
            
            // Active Action/State Card
            ActionCard(appState: appState, shortcutText: shortcutText)
            
            // Status/Notification Banner
            if shouldShowStatusBanner {
                StatusBanner(text: appState.statusText)
            }
            
            // Transcript Display Card
            if let transcript = appState.transcript {
                TranscriptCard(transcript: transcript)
            }
            
            // Collapsible configuration/settings area
            Divider()
            
            DisclosureGroup(isExpanded: $isSettingsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Push-to-Talk Shortcut")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        KeyboardShortcuts.Recorder("", name: .pushToTalk)
                            .labelsHidden()
                    }
                    .padding(.top, 4)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLI Command")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        TextField("e.g. claude", text: $cliCommand)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.bottom, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            updateShortcutText()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            updateShortcutText()
        }
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
    
    private func updateShortcutText() {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk) {
            shortcutText = shortcut.description
        } else {
            shortcutText = "Not Set"
        }
    }
    
    private var shouldShowStatusBanner: Bool {
        let text = appState.statusText
        return !text.isEmpty && text != "Ready" && !text.hasPrefix("Bound to")
    }
}

// MARK: - Subviews

struct StateBadge: View {
    let state: CaptureState
    
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundColor(backgroundColor)
            .cornerRadius(6)
    }
    
    private var label: String {
        switch state {
        case .idle:          return "IDLE"
        case .recording:     return "RECORDING"
        case .transcribing:  return "ASR"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .idle:          return .secondary
        case .recording:     return .red
        case .transcribing:  return .orange
        }
    }
}

struct RepositoryCard: View {
    let boundRepo: RepoBinding?
    let fallbackText: String
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((boundRepo != nil ? Color.blue : Color.secondary).opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: boundRepo != nil ? "folder.fill.badge.gearshape" : "folder.badge.questionmark")
                    .font(.system(size: 16))
                    .foregroundColor(boundRepo != nil ? .blue : .secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(boundRepo?.displayName ?? "No Repository Bound")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(boundRepo != nil ? .primary : .secondary)
                
                Text(boundRepo?.displayPath ?? fallbackText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct ActionCard: View {
    @ObservedObject var appState: AppState
    let shortcutText: String
    
    var body: some View {
        VStack(spacing: 12) {
            switch appState.captureState {
            case .idle:
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 32, height: 32)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready to Capture")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Hold shortcut to speak")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    ShortcutPillView(shortcutText: shortcutText)
                }
                .padding(.vertical, 4)
                
            case .recording:
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        PulsingRecordButton()
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording Voice")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.red)
                            Text("Release shortcut to finish")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        WaveformView()
                    }
                    
                    // Click-to-stop recovery affordance (WR-04)
                    Button(action: {
                        appState.stopRecording()
                    }) {
                        Text("Stop Recording")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(
                                    colors: [.red, .init(red: 0.8, green: 0.1, blue: 0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .cornerRadius(6)
                            .shadow(color: .red.opacity(0.3), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                }
                
            case .transcribing:
                HStack(spacing: 14) {
                    ActivitySpinner(color: .orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcribing Audio")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Converting speech to text...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct PulsingRecordButton: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.15))
                .frame(width: 44, height: 44)
                .scaleEffect(animate ? 1.4 : 1.0)
                .opacity(animate ? 0.0 : 1.0)
            
            Circle()
                .fill(Color.red.opacity(0.25))
                .frame(width: 36, height: 36)
                .scaleEffect(animate ? 1.2 : 1.0)
                .opacity(animate ? 0.0 : 1.0)

            Circle()
                .fill(Color.red)
                .frame(width: 28, height: 28)
                .shadow(color: .red.opacity(0.4), radius: 4, y: 1)

            Image(systemName: "mic.fill")
                .foregroundColor(.white)
                .font(.system(size: 12, weight: .semibold))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

struct WaveformView: View {
    @State private var isAnimating = false
    private let barCount = 7
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(colors: [.red, .pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: isAnimating ? randomHeight(for: index) : 8)
            }
        }
        .frame(height: 28)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
    
    private func randomHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [12, 24, 28, 16, 26, 14, 20]
        return heights[index % heights.count]
    }
}

struct ActivitySpinner: View {
    @State private var degree: Double = 0
    let color: Color
    
    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.7)
            .stroke(
                AngularGradient(colors: [color.opacity(0.1), color], center: .center),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 28, height: 28)
            .rotationEffect(.degrees(degree))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    degree = 360
                }
            }
    }
}

struct ShortcutPillView: View {
    let shortcutText: String
    
    var body: some View {
        HStack(spacing: 2) {
            if shortcutText.isEmpty || shortcutText == "Not Set" {
                Text("Not Set")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundColor(.secondary)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(4)
            } else {
                ForEach(parseShortcut(text: shortcutText), id: \.self) { symbol in
                    KeyCapView(symbol: symbol)
                }
            }
        }
    }
    
    private func parseShortcut(text: String) -> [String] {
        var parts: [String] = []
        var currentKey = ""
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        
        for char in text {
            if modifiers.contains(char) {
                parts.append(String(char))
            } else {
                currentKey.append(char)
            }
        }
        
        if !currentKey.isEmpty {
            parts.append(currentKey)
        }
        
        return parts
    }
}

struct KeyCapView: View {
    let symbol: String
    
    var body: some View {
        Text(symbol)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

struct StatusBanner: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.amberStyle)
                .font(.system(size: 13))
                .padding(.top, 1)
            
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.06))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.12), lineWidth: 1)
        )
    }
}

extension Color {
    static var amberStyle: Color {
        Color(nsColor: NSColor(red: 0.8, green: 0.5, blue: 0.0, alpha: 1.0))
    }
}

struct TranscriptCard: View {
    let transcript: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                CopyButton(text: transcript)
            }
            
            ScrollView {
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 100)
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct CopyButton: View {
    let text: String
    @State private var isCopied = false

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation {
                isCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    isCopied = false
                }
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                Text(isCopied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(isCopied ? 0.12 : 0.04))
            .foregroundColor(isCopied ? .green : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

