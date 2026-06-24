import AVFoundation
import Foundation

// Not @MainActor — AVAudioRecorder callbacks fire on a background audio thread.
// AppState owns this and calls start()/stop() from MainActor; state updates route
// back to AppState via the injectable closure seam rather than direct @Published mutation.
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?

    /// Invoked when an encode/IO error occurs after recording has begun (disk full,
    /// interruption, etc.). Fires on a background audio thread; the consumer is
    /// responsible for hopping to the main actor. Set by the owner (AppState).
    var onRecordingError: ((Error?) -> Void)?

    // Stable output directory: Application Support/MakeAnIssue (D-06, D-09).
    // Pure path computation — no filesystem side effects. Directory creation
    // happens explicitly in start() so reading these properties stays side-effect free.
    // Optional because the application-support lookup can (in principle) return an
    // empty array; we surface that as a failed start rather than crashing on [0].
    var outputDirectory: URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("MakeAnIssue", isDirectory: true)
    }

    // Stable output path: Application Support/MakeAnIssue/latest.wav (D-06, D-09).
    // Pure — does not touch the filesystem. nil when the output directory cannot
    // be resolved.
    var latestWavURL: URL? {
        outputDirectory?.appendingPathComponent("latest.wav")
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
        guard let directory = outputDirectory, let url = latestWavURL else {
            NSLog("AudioRecorder.start failed: could not resolve application support directory")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
            recorder.delegate = self
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

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        NSLog("AudioRecorder encode error: \(error.map { "\($0)" } ?? "unknown")")
        onRecordingError?(error)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            NSLog("AudioRecorder finished unsuccessfully")
            onRecordingError?(nil)
        }
    }
}
