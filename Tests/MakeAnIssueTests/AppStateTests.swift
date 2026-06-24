import XCTest
@testable import MakeAnIssue

@MainActor
final class AppStateTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testInitialStateShowsRunningStatus() {
        let state = AppState()

        XCTAssertEqual(state.statusText, "Ready")
    }

    func testInitialStateHasNoBoundRepository() {
        let state = AppState()

        XCTAssertNil(state.launchCWD)
        XCTAssertEqual(state.boundRepoDisplayText, "No repository bound")
    }

    func testLaunchRequestInsideRepoUpdatesBoundRepo() throws {
        let repo = try makeRepo(named: "first repo")
        let nested = repo.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let state = AppState()

        state.handleLaunchRequest(LaunchRequest(cwd: nested.path, createdAtUnixSeconds: 1))

        XCTAssertEqual(state.launchCWD, nested.path)
        XCTAssertEqual(state.boundRepo?.rootURL.standardizedFileURL, repo.standardizedFileURL)
        XCTAssertEqual(state.boundRepoDisplayText, repo.path)
        XCTAssertEqual(state.statusText, "Bound to first repo")
    }

    func testSecondValidLaunchRequestReplacesBoundRepo() throws {
        let firstRepo = try makeRepo(named: "first")
        let secondRepo = try makeRepo(named: "second")
        let state = AppState()

        state.handleLaunchRequest(LaunchRequest(cwd: firstRepo.path, createdAtUnixSeconds: 1))
        state.handleLaunchRequest(LaunchRequest(cwd: secondRepo.path, createdAtUnixSeconds: 2))

        XCTAssertEqual(state.boundRepo?.rootURL.standardizedFileURL, secondRepo.standardizedFileURL)
        XCTAssertEqual(state.boundRepo?.displayName, "second")
    }

    func testNonRepoLaunchRequestKeepsPreviousBindingAndUpdatesStatus() throws {
        let repo = try makeRepo(named: "repo")
        let nonRepo = temporaryDirectory.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        let state = AppState()

        state.handleLaunchRequest(LaunchRequest(cwd: repo.path, createdAtUnixSeconds: 1))
        state.handleLaunchRequest(LaunchRequest(cwd: nonRepo.path, createdAtUnixSeconds: 2))

        XCTAssertEqual(state.launchCWD, nonRepo.path)
        XCTAssertEqual(state.boundRepo?.rootURL.standardizedFileURL, repo.standardizedFileURL)
        XCTAssertEqual(state.statusText, "No git repository found")
    }

    func testInitialCaptureStateIsIdle() {
        let state = AppState()

        XCTAssertEqual(state.captureState, .idle)
    }

    func testStartRecordingTransitionsToRecording() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()

        XCTAssertEqual(state.captureState, .recording)
    }

    func testSecondStartRecordingWhileRecordingIsIgnored() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()
        state.startRecording()

        XCTAssertEqual(state.captureState, .recording)
    }

    func testStopRecordingTransitionsToTranscribing() {
        // stopRecording() now enters .transcribing before the async Task runs.
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Immediate synchronous check — Task has not yet dispatched.
        XCTAssertEqual(state.captureState, .transcribing)
    }

    func testStopRecordingWhileIdleIsNoOp() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.stopRecording()

        XCTAssertEqual(state.captureState, .idle)
    }

    func testStartRecordingAfterFinishedStartsNewRecording() async {
        // Use a stub that returns a transcript so state reaches .finished.
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello world" }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for the transcription Task to settle.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.captureState, .finished)

        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)
    }

    func testStartRecordingAfterFinishedInvokesStartSeamAgain() async {
        var startCount = 0
        let state = AppState(
            onStartRecording: { startCount += 1; return true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello" }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()
        // Wait for transcription to settle to .finished before the second startRecording.
        try? await Task.sleep(for: .milliseconds(100))
        state.startRecording()

        XCTAssertEqual(startCount, 2)
    }

    func testStartRecordingInvokesStartSeam() {
        var startCalled = false
        let state = AppState(onStartRecording: { startCalled = true; return true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()

        XCTAssertEqual(startCalled, true)
    }

    func testStopRecordingInvokesStopSeam() {
        var stopCalled = false
        let state = AppState(onStartRecording: { true }, onStopRecording: { stopCalled = true })
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        XCTAssertEqual(stopCalled, true)
    }

    func testStartRecordingWithoutMicPermissionStaysIdleAndSurfacesStatus() {
        var startCalled = false
        let state = AppState(onStartRecording: { startCalled = true; return true }, onStopRecording: {})
        state.micPermissionGranted = false
        state.startRecording()

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertFalse(startCalled)
        XCTAssertEqual(state.statusText, "Microphone access denied — enable in System Settings")
    }

    func testRecordingDidTimeoutStopsRecorderAndFinishes() {
        var stopCalled = false
        let state = AppState(onStartRecording: { true }, onStopRecording: { stopCalled = true })
        state.micPermissionGranted = true
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)

        state.recordingDidTimeout()

        XCTAssertEqual(state.captureState, .finished)
        XCTAssertTrue(stopCalled)
        XCTAssertEqual(state.statusText, "Recording stopped — maximum duration reached")
    }

    func testRecordingDidTimeoutWhileIdleIsNoOp() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true

        state.recordingDidTimeout()

        XCTAssertEqual(state.captureState, .idle)
    }

    func testRecordingAutoStopsAfterMaxDuration() async {
        var stopCalled = false
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: { stopCalled = true },
            maxRecordingDuration: .milliseconds(50)
        )
        state.micPermissionGranted = true
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.captureState, .finished)
        XCTAssertTrue(stopCalled)
    }

    func testRecordingErrorResetsStateAndStopsRecorder() {
        var stopCalled = false
        let state = AppState(onStartRecording: { true }, onStopRecording: { stopCalled = true })
        state.micPermissionGranted = true
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)

        state.handleRecordingError(nil)

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertTrue(stopCalled)
        XCTAssertTrue(state.statusText.hasPrefix("Recording failed"))
    }

    func testFailedStartKeepsStateIdleAndSurfacesStatus() {
        let state = AppState(onStartRecording: { false }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertEqual(state.statusText, "Recording failed — check microphone permission")
    }

    // MARK: - Transcription state-machine tests (Phase 03 Wave 2)

    func testStopRecordingTransitionsToTranscribingViaSeam() async {
        // stopRecording() must enter .transcribing before the transcription Task settles.
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in
                // Small delay ensures we can observe .transcribing before .finished.
                try? await Task.sleep(for: .milliseconds(200))
                return "Hello"
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Immediately after stopRecording, before the Task runs, state must be .transcribing.
        XCTAssertEqual(state.captureState, .transcribing)
    }

    func testTranscriptionInvokesSeamWithWavURL() async {
        var receivedURL: URL?
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { url in
                receivedURL = url
                return "transcript text"
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(100))

        // The seam must be called with the recorder's latestWavURL.
        XCTAssertNotNil(receivedURL, "onRunTranscription must be invoked with the WAV URL")
        XCTAssertTrue(
            receivedURL?.lastPathComponent == "latest.wav",
            "WAV URL last component must be 'latest.wav', got: \(receivedURL?.lastPathComponent ?? "nil")"
        )
    }

    func testSuccessfulTranscriptionStoresText() async {
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello world" }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.transcript, "Hello world")
        XCTAssertEqual(state.captureState, .finished)
        XCTAssertNil(state.transcriptError)
    }

    func testTimeoutResetsState() async {
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in throw TranscriberError.asrTimedOut }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.captureState, .idle, "Timeout must reset state to .idle so next PTT works")
        XCTAssertTrue(
            state.statusText.lowercased().contains("timed out") || state.statusText.lowercased().contains("timeout"),
            "Status must mention timeout, got: '\(state.statusText)'"
        )
        XCTAssertNil(state.transcript, "Transcript must not be set on timeout")
    }

    func testEmptyCommandShowsError() async {
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in throw TranscriberError.emptyCommand }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.captureState, .idle, "Empty command must reset state to .idle")
        XCTAssertTrue(
            state.statusText.lowercased().contains("asr command") || state.statusText.lowercased().contains("set your"),
            "Status must mention ASR command setup, got: '\(state.statusText)'"
        )
        XCTAssertNil(state.transcript, "Transcript must not be set when command is empty")
    }

    func testFailureThrowingResetsStateToIdle() async {
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in throw TranscriberError.asrFailed(exitCode: 1, stderr: "model not found") }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.captureState, .idle, "ASR failure must reset state to .idle (D-11)")
        XCTAssertNotNil(state.transcriptError)
    }

    private func makeRepo(named name: String) throws -> URL {
        let repo = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return repo
    }
}
