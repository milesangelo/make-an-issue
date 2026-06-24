import AVFoundation
import Foundation

// Not @MainActor — AVAudioRecorder callbacks fire on a background audio thread.
// AppState owns this and calls start()/stop() from MainActor; state updates route
// back to AppState via the injectable closure seam rather than direct @Published mutation.
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?

    // Stable output path: Application Support/MakeAnIssue/latest.wav (D-06, D-09)
    var latestWavURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MakeAnIssue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("latest.wav")
    }

    // WAV settings — URL extension (.wav) selects container; LinearPCM selects codec (D-08)
    static let wavSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,  // little-endian; standard WAV
    ]

    @discardableResult
    func start() -> Bool {
        let url = latestWavURL
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
            self.recorder = recorder
            return recorder.record()
        } catch {
            NSLog("AudioRecorder.start failed: \(error)")
            recorder = nil
            return false
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}
