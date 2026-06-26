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

    func testStartRecordingAfterFilingReturnsToIdleStartsNewRecording() async {
        // Use a stub that returns a transcript and completes filing so state reaches .idle.
        // (.finished is now transient — it flows into .filing then .idle)
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello world" }
            // No boundRepo → beginFiling() skips to .idle immediately
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for the transcription Task and filing fast-path to settle.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.captureState, .idle)

        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)
    }

    func testStartRecordingAfterIdleInvokesStartSeamAgain() async {
        var startCount = 0
        let state = AppState(
            onStartRecording: { startCount += 1; return true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello" }
            // No boundRepo → filing fast-path returns to .idle; startRecording allowed from .idle
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()
        // Wait for transcription + filing fast-path to settle to .idle before the second startRecording.
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

    func testRecordingDidTimeoutStopsRecorderAndTranscribes() async {
        // WR-02: hitting the max-duration cap must transcribe the captured audio,
        // not discard it. Enters .transcribing synchronously, then settles.
        var stopCalled = false
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: { stopCalled = true },
            onRunTranscription: { _ in "Capped transcript" }
            // No boundRepo → filing fast-path returns to .idle immediately after transcription
        )
        state.micPermissionGranted = true
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)

        state.recordingDidTimeout()

        XCTAssertEqual(state.captureState, .transcribing, "Cap must transcribe captured audio, not discard it")
        XCTAssertTrue(stopCalled)

        try? await Task.sleep(for: .milliseconds(100))
        // .finished is transient; no repo bound → filing fast-path → .idle
        XCTAssertEqual(state.captureState, .idle)
        XCTAssertEqual(state.transcript, "Capped transcript")
    }

    func testRecordingDidTimeoutWhileIdleIsNoOp() {
        let state = AppState(onStartRecording: { true }, onStopRecording: {})
        state.micPermissionGranted = true

        state.recordingDidTimeout()

        XCTAssertEqual(state.captureState, .idle)
    }

    func testRecordingAutoStopsAfterMaxDurationAndTranscribes() async {
        // WR-02: the auto-stop cap routes through transcription like a normal stop.
        var stopCalled = false
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: { stopCalled = true },
            maxRecordingDuration: .milliseconds(50),
            onRunTranscription: { _ in "Auto transcript" }
            // No boundRepo → filing fast-path returns to .idle immediately after transcription
        )
        state.micPermissionGranted = true
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)

        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(stopCalled)
        // .finished is transient; no repo bound → filing fast-path → .idle
        XCTAssertEqual(state.captureState, .idle)
        XCTAssertEqual(state.transcript, "Auto transcript")
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
        // Provide an onRunIssueFiling stub so .finished → .filing → .idle cycle completes cleanly.
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello world" },
            onRunIssueFiling: { _, _ in
                IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.boundRepo = RepoBinding(
            rootURL: URL(fileURLWithPath: "/tmp/test-repo"),
            displayName: "test-repo",
            displayPath: "/tmp/test-repo"
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.transcript, "Hello world")
        // .finished is transient; after filing completes state returns to .idle
        XCTAssertEqual(state.captureState, .idle)
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

    // MARK: - Issue filing (Phase 04 Wave 3)

    func testFilingSeamCalledWithTranscriptAndRepo() async throws {
        let repoURL = try makeRepo(named: "filing-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "filing-repo", displayPath: repoURL.path)
        var capturedTranscript: String?
        var capturedRepo: RepoBinding?
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "filing-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "file this bug" },
            onRunIssueFiling: { transcript, repo in
                capturedTranscript = transcript
                capturedRepo = repo
                return IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(capturedTranscript, "file this bug", "Filing seam must be called with the captured transcript")
        XCTAssertEqual(capturedRepo?.displayName, "filing-repo", "Filing seam must be called with the bound repo")
    }

    func testSuccessfulFilingSpeaksIssueNumber() async throws {
        let repoURL = try makeRepo(named: "speak-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "speak-repo", displayPath: repoURL.path)
        var spokenText: String?
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "speak-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _ in
                IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42")
            },
            onSpeak: { text in spokenText = text }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNotNil(spokenText, "speak seam must be called on successful filing")
        XCTAssertTrue(
            spokenText?.contains("42") == true,
            "Spoken text must contain the issue number, got: \(spokenText ?? "nil")"
        )
    }

    func testSuccessfulFilingReturnsToIdle() async throws {
        let repoURL = try makeRepo(named: "idle-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "idle-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "idle-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _ in
                IssueFilingResult(number: 7, url: "https://github.com/owner/repo/issues/7")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.captureState, .idle, "After successful filing state must return to .idle")
    }

    func testFilingErrorSetsStatusTextAndReturnsToIdle() async throws {
        let repoURL = try makeRepo(named: "error-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "error-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "error-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _ in throw IssueFilingError.timeout }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.captureState, .idle, "Filing error must reset to .idle so next PTT works")
        XCTAssertFalse(state.statusText.isEmpty, "Filing error must surface a non-empty status message")
    }

    func testFilingErrorTokenAcquisitionSetsStatus() async throws {
        let repoURL = try makeRepo(named: "token-error-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "token-error-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "token-error-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _ in throw IssueFilingError.tokenAcquisitionFailed }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertTrue(
            state.statusText.lowercased().contains("github") || state.statusText.lowercased().contains("sign in") || state.statusText.lowercased().contains("gh"),
            "Token error must mention GitHub auth, got: '\(state.statusText)'"
        )
    }

    func testParseFailedStatusMessageIsNotMisleading() async throws {
        // Regression: parseFailed must NOT say "Issue filed" — nothing was filed.
        // The message must accurately reflect that confirmation failed (not that an issue was created).
        let repoURL = try makeRepo(named: "parse-failed-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "parse-failed-repo", displayPath: repoURL.path)
        var speakCalled = false
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "parse-failed-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _ in throw IssueFilingError.parseFailed },
            onSpeak: { _ in speakCalled = true }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        // Status must show the corrected wording — not the old misleading "Issue filed" text.
        XCTAssertEqual(
            state.statusText,
            "Couldn't confirm an issue was filed — check GitHub (is Docker running?)",
            "parseFailed message must not imply an issue was filed; got: '\(state.statusText)'"
        )
        // Speak seam must NOT be called — no false success announcement.
        XCTAssertFalse(speakCalled, "speak seam must NOT be called on parseFailed (no false success)")
        // State machine must return to .idle so PTT is usable again.
        XCTAssertEqual(state.captureState, .idle, "parseFailed must reset captureState to .idle")
    }

    func testNoRepoBoundSkipsFilingAndReturnsToIdle() async throws {
        var filingCalled = false
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _ in
                filingCalled = true
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        // No boundRepo set — default nil
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(filingCalled, "Filing seam must NOT be called when no repo is bound")
        XCTAssertEqual(state.captureState, .idle, "Must return to .idle when no repo is bound")
        XCTAssertFalse(
            state.statusText.isEmpty,
            "Status must surface a 'no repo' message when no repo is bound"
        )
    }

    func testTranscriptRemainsSetAfterFilingReturnsToIdle() async throws {
        let repoURL = try makeRepo(named: "transcript-persist-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "transcript-persist-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "transcript-persist-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "persistent transcript" },
            onRunIssueFiling: { _, _ in
                IssueFilingResult(number: 5, url: "https://github.com/owner/repo/issues/5")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertEqual(state.transcript, "persistent transcript", "Transcript must remain readable after filing returns to .idle")
    }

    func testFilingEntersFilingState() async throws {
        // Verify that AppState enters .filing synchronously when filing begins.
        let repoURL = try makeRepo(named: "filing-state-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "filing-state-repo", displayPath: repoURL.path)
        var filingStateObserved = false
        let filingStarted = CheckedContinuation<Void, Never>.self
        _ = filingStarted  // silence unused warning

        // Use a slow filing seam to ensure we can observe .filing before it completes.
        let sem = DispatchSemaphore(value: 0)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "filing-state-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "file me" },
            onRunIssueFiling: { _, _ in
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 99, url: "https://github.com/owner/repo/issues/99")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for transcription to finish and filing to begin
        try? await Task.sleep(for: .milliseconds(150))
        filingStateObserved = state.captureState == .filing

        // Wait for filing to complete
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(filingStateObserved, "AppState must enter .filing state while the filing seam is in-flight")
        XCTAssertEqual(state.captureState, .idle, "After filing completes state must be .idle")
        sem.signal()
    }

    private func makeRepo(named name: String) throws -> URL {
        let repo = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return repo
    }
}
