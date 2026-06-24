import AVFoundation
import XCTest
@testable import MakeAnIssue

final class AudioRecorderTests: XCTestCase {
    func testLatestWavURLEndsWithWavExtension() throws {
        let recorder = AudioRecorder()

        let url = try XCTUnwrap(recorder.latestWavURL)
        XCTAssertEqual(url.pathExtension, "wav")
    }

    func testLatestWavURLLastComponentIsLatestWav() throws {
        let recorder = AudioRecorder()

        let url = try XCTUnwrap(recorder.latestWavURL)
        XCTAssertEqual(url.lastPathComponent, "latest.wav")
    }

    func testLatestWavURLIsUnderApplicationSupportMakeAnIssue() throws {
        let recorder = AudioRecorder()

        let url = try XCTUnwrap(recorder.latestWavURL)
        XCTAssertTrue(url.path.contains("Application Support/MakeAnIssue"))
    }

    func testWavSettingsHaveCorrectSampleRate() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16_000.0)
    }

    func testWavSettingsHaveMonoChannel() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
    }

    func testWavSettingsHaveLinearPCMFormat() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
    }

    func testWavSettingsHave16BitDepth() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }

    func testStopWithoutStartIsSafe() {
        let recorder = AudioRecorder()

        // Calling stop() before any start() must not crash.
        recorder.stop()
    }

    func testReadingURLsHasNoFilesystemSideEffect() throws {
        let recorder = AudioRecorder()
        let directory = try XCTUnwrap(recorder.outputDirectory)

        // Reading the path properties must be pure (WR-03): merely asking for the
        // URL must not create the directory on disk.
        try? FileManager.default.removeItem(at: directory)
        _ = recorder.latestWavURL
        _ = recorder.outputDirectory

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
