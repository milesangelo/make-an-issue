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

    func testStopRecordingTransitionsToFinished() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        XCTAssertEqual(state.captureState, .finished)
    }

    func testStopRecordingWhileIdleIsNoOp() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.stopRecording()

        XCTAssertEqual(state.captureState, .idle)
    }

    func testStartRecordingAfterFinishedStartsNewRecording() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        XCTAssertEqual(state.captureState, .finished)

        state.startRecording()

        XCTAssertEqual(state.captureState, .recording)
    }

    func testStartRecordingAfterFinishedInvokesStartSeamAgain() {
        var startCount = 0
        let state = AppState(onStartRecording: { startCount += 1; return true }, onStopRecording: {})
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()
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

    private func makeRepo(named name: String) throws -> URL {
        let repo = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return repo
    }
}
