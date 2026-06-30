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
        // Use a stub that returns a transcript so captureState reaches .idle.
        // No boundRepo → spawnFilingJob is never called; captureState = .idle right after transcription.
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello world" }
            // No boundRepo → spawnFilingJob skipped; captureState = .idle immediately
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for the transcription Task and filing fast-path to settle.
        await waitUntil { state.captureState == .idle }
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
        await waitUntil { state.captureState == .idle }
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
        // Inject a denied authorization re-check so the result is deterministic and
        // does not depend on the test host's TCC microphone grant (WR-03).
        let state = AppState(
            onStartRecording: { startCalled = true; return true },
            onStopRecording: {},
            onCheckMicAuthorization: { false }
        )
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

        await waitUntil { state.captureState == .idle && state.transcript == "Capped transcript" }
        // No repo bound → spawnFilingJob skipped; captureState = .idle immediately after transcription
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

        await waitUntil { state.captureState == .idle && state.transcript == "Auto transcript" }

        XCTAssertTrue(stopCalled)
        // No repo bound → spawnFilingJob skipped; captureState = .idle immediately after transcription
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
                // Small delay ensures we can observe .transcribing before .idle.
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

        await waitUntil { receivedURL != nil }

        // The seam must be called with the recorder's latestWavURL.
        XCTAssertNotNil(receivedURL, "onRunTranscription must be invoked with the WAV URL")
        XCTAssertTrue(
            receivedURL?.lastPathComponent == "latest.wav",
            "WAV URL last component must be 'latest.wav', got: \(receivedURL?.lastPathComponent ?? "nil")"
        )
    }

    func testSuccessfulTranscriptionStoresText() async {
        // Provide an onRunIssueFiling stub so the filing job completes cleanly.
        // Under the jobs model, captureState is .idle immediately after transcription;
        // filing runs concurrently in jobs[0].
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "Hello world" },
            onRunIssueFiling: { _, _, _ in
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

        await waitUntil { state.captureState == .idle && state.transcript == "Hello world" }

        XCTAssertEqual(state.transcript, "Hello world")
        // captureState = .idle immediately after transcription; filing runs in jobs[0]
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

        await waitUntil { state.captureState == .idle }

        XCTAssertEqual(state.captureState, .idle, "Timeout must reset state to .idle so next PTT works")
        XCTAssertTrue(
            state.statusText.lowercased().contains("timed out") || state.statusText.lowercased().contains("timeout"),
            "Status must mention timeout, got: '\(state.statusText)'"
        )
        XCTAssertNil(state.transcript, "Transcript must not be set on timeout")
    }

    func testBundledResourcesMissingResetsStateAndSurfacesStatus() async {
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in
                throw TranscriberError.bundledResourcesMissing(detail: "whisper-cli not found in bundle Resources")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.captureState == .idle }

        XCTAssertEqual(state.captureState, .idle, "bundledResourcesMissing must reset state to .idle")
        XCTAssertTrue(
            state.statusText.lowercased().contains("rebuild the app"),
            "Status must contain 'rebuild the app', got: '\(state.statusText)'"
        )
        XCTAssertNil(state.transcript, "Transcript must not be set when bundle resources are missing")
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

        await waitUntil { state.captureState == .idle }

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
            onRunIssueFiling: { transcript, repo, _ in
                capturedTranscript = transcript
                capturedRepo = repo
                return IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { capturedTranscript != nil }

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
            onRunIssueFiling: { _, _, _ in
                IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42")
            },
            onSpeak: { text in spokenText = text }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { spokenText != nil }

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
            onRunIssueFiling: { _, _, _ in
                IssueFilingResult(number: 7, url: "https://github.com/owner/repo/issues/7")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.captureState == .idle }

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
            onRunIssueFiling: { _, _, _ in throw IssueFilingError.timeout }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.captureState == .idle }

        XCTAssertEqual(state.captureState, .idle, "Filing error must reset to .idle so next PTT works")
        XCTAssertFalse(state.statusText.isEmpty, "Filing error must surface a non-empty status message")
    }

    func testFilingErrorTokenAcquisitionSetsStatus() async throws {
        // Under the jobs model, tokenAcquisitionFailed is stored in jobs[0].error (D-06).
        // captureState returns to .idle immediately on transcription completion (CONCUR-01).
        let repoURL = try makeRepo(named: "token-error-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "token-error-repo", displayPath: repoURL.path)
        var spokenText: String?
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "token-error-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _, _ in throw IssueFilingError.tokenAcquisitionFailed },
            onSpeak: { text in spokenText = text }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .failed }

        XCTAssertEqual(state.captureState, .idle, "captureState must be .idle (CONCUR-01)")
        XCTAssertEqual(state.jobs[0].state, .failed, "job must be .failed on tokenAcquisitionFailed")
        XCTAssertEqual(state.jobs[0].error, IssueFilingError.tokenAcquisitionFailed, "job error must be the specific IssueFilingError")
        XCTAssertEqual(spokenText, "issue filing failed", "failure announcement must be 'issue filing failed' (D-04)")
    }

    func testParseFailedStatusMessageIsNotMisleading() async throws {
        // Regression: parseFailed must NOT announce "created issue #N" — nothing was confirmed filed.
        // Under the jobs model: job is .failed, job.error == .parseFailed, and the spoken outcome
        // is "issue filing failed" (D-04/D-05) — a failure announcement, not a false success.
        let repoURL = try makeRepo(named: "parse-failed-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "parse-failed-repo", displayPath: repoURL.path)
        var spokenText: String?
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "parse-failed-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _, _ in throw IssueFilingError.parseFailed },
            onSpeak: { text in spokenText = text }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .failed }

        // Job must be .failed with the parseFailed error stored (D-06).
        XCTAssertEqual(state.jobs[0].state, .failed, "parseFailed must set job state to .failed")
        XCTAssertEqual(state.jobs[0].error, IssueFilingError.parseFailed, "parseFailed error must be stored in the job")
        // Spoken outcome must be "issue filing failed" — a failure announcement, not "created issue #N" (no false success).
        XCTAssertEqual(spokenText, "issue filing failed", "parseFailed must announce 'issue filing failed', not a success (D-04/T-5-05)")
        XCTAssertFalse(spokenText?.contains("created") == true, "parseFailed must never announce a creation (no false success)")
        // State machine must be .idle so PTT is usable again.
        XCTAssertEqual(state.captureState, .idle, "parseFailed must leave captureState .idle (CONCUR-01)")
    }

    func testNoRepoBoundSkipsFilingAndReturnsToIdle() async throws {
        var filingCalled = false
        let state = AppState(
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _, _ in
                filingCalled = true
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        // No boundRepo set — default nil
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.captureState == .idle }

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
            onRunIssueFiling: { _, _, _ in
                IssueFilingResult(number: 5, url: "https://github.com/owner/repo/issues/5")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.captureState == .idle && state.transcript == "persistent transcript" }

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertEqual(state.transcript, "persistent transcript", "Transcript must remain readable after filing returns to .idle")
    }

    func testFilingEntersFilingState() async throws {
        // CONCUR-01: captureState == .idle immediately after transcription.
        // The per-job filing state is tracked in jobs[0].state, not captureState.
        let repoURL = try makeRepo(named: "filing-state-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "filing-state-repo", displayPath: repoURL.path)

        // Slow seam keeps jobs[0].state == .filing long enough to observe it.
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "filing-state-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "file me" },
            onRunIssueFiling: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 99, url: "https://github.com/owner/repo/issues/99")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for a job to be spawned (transcription completed, spawnFilingJob called).
        await waitUntil { state.jobs.count == 1 }

        // CONCUR-01: captureState is .idle immediately; the filing runs in jobs[0].
        XCTAssertEqual(state.captureState, .idle, "captureState must be .idle while filing runs concurrently in jobs[0] (CONCUR-01)")
        XCTAssertEqual(state.jobs[0].state, .filing, "jobs[0].state must be .filing while the seam is in-flight")

        // Wait for filing to complete.
        await waitUntil { state.jobs[0].state == .done }
        XCTAssertEqual(state.jobs[0].state, .done, "jobs[0].state must be .done after filing completes")
        XCTAssertEqual(state.captureState, .idle, "captureState must remain .idle after filing completes")
    }

    func testPushToTalkDuringFilingIsAllowedUnderJobsModel() async throws {
        // D-09: under the jobs model, filings run concurrently in the background and
        // do not block PTT. A re-press while jobs[0].state == .filing succeeds and
        // starts a new capture without disturbing the in-flight job.
        let repoURL = try makeRepo(named: "ptt-during-filing-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "ptt-during-filing-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "ptt-during-filing-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "file this bug" },
            onRunIssueFiling: { _, _, _ in
                // Slow enough that we can observe jobs[0].state == .filing and attempt PTT re-entry.
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for a job to be spawned and be in .filing state.
        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }
        XCTAssertEqual(state.jobs[0].state, .filing, "must have an in-flight job before testing PTT re-entry")

        // Simulate a PTT re-press while jobs[0] is still in .filing — D-09: re-entry is NOW ALLOWED.
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording, "PTT re-entry during an in-flight filing must succeed (D-09)")

        // The in-flight job (jobs[0]) must not be disturbed by the re-entry.
        XCTAssertEqual(state.jobs[0].state, .filing, "in-flight job must remain .filing after PTT re-entry")
    }

    /// Polls `condition` on the main actor until it returns true or the deadline
    /// elapses, instead of sleeping a fixed guessed wall-clock interval (WR-04).
    /// This removes timing assumptions from the async state-machine tests: under
    /// CI load the helper simply waits longer, and it returns as soon as the
    /// pipeline settles. Returns the final value of `condition`.
    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func makeRepo(named name: String) throws -> URL {
        let repo = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return repo
    }

    // MARK: - Jobs model (CONCUR-01 / D-08)

    // MARK: - Concurrency tests (Plan 02 / CONCUR-01 / CONCUR-02 / D-09)

    func testTranscriptionCompletionReturnsCaptureToIdleImmediately() async throws {
        // CONCUR-01 / SC-1: captureState is .idle the moment transcription completes,
        // even though the filing job is still in-flight.
        let repoURL = try makeRepo(named: "concur01-idle-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "concur01-idle-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "concur01-idle-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "concur test transcript" },
            onRunIssueFiling: { _, _, _ in
                // Slow stub keeps jobs[0].state == .filing long enough to observe concurrency.
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for the job to be spawned (transcription has completed).
        await waitUntil { state.jobs.count == 1 }

        // CONCUR-01 / SC-1: captureState is idle the moment transcription completes.
        XCTAssertEqual(state.captureState, .idle, "captureState must be .idle as soon as transcription completes (CONCUR-01/SC-1)")
        XCTAssertEqual(state.jobs[0].state, .filing, "jobs[0] must be .filing while stub is sleeping")
    }

    func testNewRecordingAllowedWhileFilingIsInFlight() async throws {
        // D-09: startRecording() is allowed from .idle even while a job is in-flight.
        let repoURL = try makeRepo(named: "d09-reentry-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "d09-reentry-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "d09-reentry-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "first recording" },
            onRunIssueFiling: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 2, url: "https://github.com/o/r/issues/2")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for the job to be in-flight and captureState to be .idle.
        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }

        // D-09: re-entry is allowed because captureState is .idle (not blocked by filing).
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording, "startRecording() must succeed while a job is .filing (D-09)")
        XCTAssertEqual(state.jobs[0].state, .filing, "in-flight job must remain .filing after PTT re-entry")
    }

    func testPTTReEntryDuringFilingStartsNewRecording() async throws {
        // D-09: PTT re-entry during in-flight filing starts a new recording;
        // the guard admits entry from .idle regardless of concurrent jobs.
        let repoURL = try makeRepo(named: "ptt-reentry-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "ptt-reentry-repo", displayPath: repoURL.path)
        var startCallCount = 0
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "ptt-reentry-repo",
            onStartRecording: { startCallCount += 1; return true },
            onStopRecording: {},
            onRunTranscription: { _ in "ptt transcript" },
            onRunIssueFiling: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 3, url: "https://github.com/o/r/issues/3")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for filing to be in-flight and captureState to be .idle.
        await waitUntil { state.jobs.count == 1 && state.captureState == .idle }

        // Simulate PTT re-press while a job is in-flight.
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording, "PTT re-entry from .idle during in-flight filing must reach .recording (D-09)")
        XCTAssertEqual(startCallCount, 2, "onStartRecording must be called for both recordings")
    }

    func testTwoConcurrentFilingJobsCanBeSpawned() async throws {
        // CONCUR-02 / SC-2: two full record/stop cycles produce two simultaneous .filing jobs.
        let repoURL = try makeRepo(named: "concur02-two-jobs-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "concur02-two-jobs-repo", displayPath: repoURL.path)
        var transcriptionCallCount = 0
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "concur02-two-jobs-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in
                defer { transcriptionCallCount += 1 }
                return "transcript \(transcriptionCallCount + 1)"
            },
            onRunIssueFiling: { _, _, _ in
                // Long sleep keeps both jobs in-flight simultaneously.
                try? await Task.sleep(for: .milliseconds(500))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.micPermissionGranted = true

        // First record/stop cycle.
        state.startRecording()
        state.stopRecording()

        // Wait for first job to be spawned (captureState is now .idle).
        await waitUntil { state.jobs.count == 1 }
        XCTAssertEqual(state.captureState, .idle, "captureState must be .idle after first transcription (CONCUR-01)")
        XCTAssertEqual(state.jobs[0].state, .filing, "first job must be .filing")

        // Second record/stop cycle while first job is still in-flight.
        state.startRecording()
        state.stopRecording()

        // Wait for second job to be spawned.
        await waitUntil { state.jobs.count == 2 }

        // CONCUR-02 / SC-2: both jobs are simultaneously .filing.
        XCTAssertEqual(state.jobs[0].state, .filing, "jobs[0] must still be .filing (CONCUR-02/SC-2)")
        XCTAssertEqual(state.jobs[1].state, .filing, "jobs[1] must be .filing while stub is sleeping (CONCUR-02/SC-2)")
    }

    // MARK: - Announcement and distinct-transcript tests (Plan 02 / CONCUR-02 / CONCUR-03)

    func testBothConcurrentJobsRetainDistinctTranscripts() async throws {
        // CONCUR-02 / Pitfall 1: two concurrent jobs must carry distinct, correct transcripts —
        // no stale-transcript bleed from the shared self.transcript property.
        let repoURL = try makeRepo(named: "distinct-transcripts-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "distinct-transcripts-repo", displayPath: repoURL.path)
        var callIndex = 0
        let expectedTranscripts = ["first transcript", "second transcript"]
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "distinct-transcripts-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in
                defer { callIndex += 1 }
                return expectedTranscripts[callIndex]
            },
            onRunIssueFiling: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(500))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.micPermissionGranted = true

        // First cycle.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 1 }

        // Second cycle while first job is still in-flight.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 2 }

        // CONCUR-02 / Pitfall 1: no stale-transcript bleed.
        XCTAssertEqual(state.jobs[0].transcript, "first transcript", "jobs[0] must carry the first transcript (no stale-capture bleed)")
        XCTAssertEqual(state.jobs[1].transcript, "second transcript", "jobs[1] must carry the second transcript (no stale-capture bleed)")
        XCTAssertNotEqual(state.jobs[0].transcript, state.jobs[1].transcript, "concurrent jobs must have distinct transcripts")
    }

    func testSuccessfulFilingJobSpeaksIssueNumber() async throws {
        // CONCUR-03 / D-01: a successful filing announces "created issue #N".
        let repoURL = try makeRepo(named: "speak-success-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "speak-success-repo", displayPath: repoURL.path)
        var spokenTexts: [String] = []
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "speak-success-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _, _ in
                IssueFilingResult(number: 42, url: "https://github.com/owner/repo/issues/42")
            },
            onSpeak: { text in spokenTexts.append(text) }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { !spokenTexts.isEmpty }

        XCTAssertFalse(spokenTexts.isEmpty, "onSpeak must be called after successful filing (CONCUR-03/D-01)")
        XCTAssertTrue(
            spokenTexts.first?.contains("42") == true,
            "Spoken text must contain the issue number '42', got: \(spokenTexts.first ?? "nil")"
        )
        XCTAssertTrue(
            spokenTexts.first?.contains("created") == true,
            "Spoken text must match 'created issue #N' shape (D-01), got: \(spokenTexts.first ?? "nil")"
        )
    }

    func testFailedFilingJobSpeaksGenericFailure() async throws {
        // CONCUR-03 / D-04 / D-05: a failed filing speaks exactly "issue filing failed" —
        // one generic phrase, no per-type reason exposed to the user.
        let repoURL = try makeRepo(named: "speak-failure-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "speak-failure-repo", displayPath: repoURL.path)
        var spokenTexts: [String] = []
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "speak-failure-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create issue" },
            onRunIssueFiling: { _, _, _ in throw IssueFilingError.timeout },
            onSpeak: { text in spokenTexts.append(text) }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { !spokenTexts.isEmpty }

        XCTAssertEqual(
            spokenTexts.first,
            "issue filing failed",
            "Failed filing must speak 'issue filing failed' (D-04/D-05), got: \(spokenTexts.first ?? "nil")"
        )
    }

    func testAnnouncementDeferredDuringRecording() async throws {
        // D-02: while captureState == .recording, a completed job's announcement is
        // deferred to pendingAnnouncements and NOT immediately spoken.
        let repoURL = try makeRepo(named: "defer-during-recording-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "defer-during-recording-repo", displayPath: repoURL.path)
        var spokenTexts: [String] = []
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "defer-during-recording-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "deferred announcement transcript" },
            onRunIssueFiling: { _, _, _ in
                // Short enough that the job completes while the second recording is active.
                try? await Task.sleep(for: .milliseconds(100))
                return IssueFilingResult(number: 10, url: "https://github.com/o/r/issues/10")
            },
            onSpeak: { text in spokenTexts.append(text) }
        )
        state.micPermissionGranted = true

        // First cycle — spawns a job.
        state.startRecording()
        state.stopRecording()

        // Wait for the job to be in-flight (captureState is .idle at this point).
        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }

        // Start second recording so captureState transitions to .recording.
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording, "precondition: captureState must be .recording")

        // Wait for the first job to complete — announce() must defer because captureState == .recording.
        await waitUntil { state.jobs[0].state == .done }

        // D-02: announcement was deferred; onSpeak must NOT have been called yet.
        XCTAssertTrue(spokenTexts.isEmpty, "onSpeak must NOT be called while captureState == .recording (D-02)")
    }

    func testDeferredAnnouncementFlushedOnRecordingStop() async throws {
        // D-03: the deferred announcement is flushed when stopRecording() triggers
        // beginTranscription(), which calls flushPendingAnnouncements() synchronously.
        let repoURL = try makeRepo(named: "flush-on-stop-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "flush-on-stop-repo", displayPath: repoURL.path)
        var spokenTexts: [String] = []
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "flush-on-stop-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "flush test transcript" },
            onRunIssueFiling: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(100))
                return IssueFilingResult(number: 11, url: "https://github.com/o/r/issues/11")
            },
            onSpeak: { text in spokenTexts.append(text) }
        )
        state.micPermissionGranted = true

        // First cycle — spawns a filing job.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }

        // Start second recording — captureState = .recording.
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording)

        // Wait for first job to complete (announcement must be deferred while recording).
        await waitUntil { state.jobs[0].state == .done }
        XCTAssertTrue(spokenTexts.isEmpty, "precondition: announcement must be deferred during recording (D-02)")

        // Stop second recording — flushPendingAnnouncements() fires inside beginTranscription().
        state.stopRecording()

        // D-03: deferred announcement must be spoken after recording stops.
        await waitUntil { !spokenTexts.isEmpty }
        XCTAssertFalse(spokenTexts.isEmpty, "deferred announcement must be flushed when recording stops (D-03)")
        XCTAssertTrue(
            spokenTexts.first?.contains("11") == true || spokenTexts.first?.contains("created") == true,
            "Flushed text must be the deferred filing announcement, got: \(spokenTexts.first ?? "nil")"
        )
    }

    // MARK: - Retention tests (Plan 02 / D-06 / D-07) and SC-4 tempfile isolation

    func testCompletedFilingJobRetainedInJobsArray() async throws {
        // D-06/D-07: terminal jobs are NOT removed from the jobs array on completion —
        // they are retained for the Phase 9 job-list UI.
        let repoURL = try makeRepo(named: "retention-done-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "retention-done-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "retention-done-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "retained transcript" },
            onRunIssueFiling: { _, _, _ in
                IssueFilingResult(number: 20, url: "https://github.com/o/r/issues/20")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.jobs.first?.state == .done }

        // D-06/D-07: completed job is retained (not removed) in jobs array.
        XCTAssertEqual(state.jobs.count, 1, "jobs array must retain the completed job (D-06/D-07)")
        XCTAssertEqual(state.jobs[0].state, .done, "retained job state must be .done")
    }

    func testFailedFilingJobRetainedInJobsArray() async throws {
        // D-06/D-07: failed jobs are also retained for Phase 9 error-row display.
        let repoURL = try makeRepo(named: "retention-failed-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "retention-failed-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "retention-failed-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "failed transcript" },
            onRunIssueFiling: { _, _, _ in throw IssueFilingError.timeout }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.jobs.first?.state == .failed }

        // D-06/D-07: failed job is retained in jobs array.
        XCTAssertEqual(state.jobs.count, 1, "jobs array must retain the failed job (D-06/D-07)")
        XCTAssertEqual(state.jobs[0].state, .failed, "retained job state must be .failed")
    }

    func testTwoConcurrentStubFilingsDoNotInterfere() async throws {
        // SC-4 behavior: two concurrent filings each complete with their own distinct result —
        // observable evidence that jobs do not share state at the jobs layer.
        let repoURL = try makeRepo(named: "sc4-isolation-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "sc4-isolation-repo", displayPath: repoURL.path)
        var filingCallCount = 0
        var transcriptionCallCount = 0
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "sc4-isolation-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in
                defer { transcriptionCallCount += 1 }
                return "transcript \(transcriptionCallCount + 1)"
            },
            onRunIssueFiling: { _, _, _ in
                // Each invocation captures its own issue number before suspending,
                // proving the two concurrent tasks do not share per-invocation state.
                filingCallCount += 1
                let myNumber = filingCallCount
                try? await Task.sleep(for: .milliseconds(200))
                return IssueFilingResult(number: myNumber, url: "https://github.com/o/r/issues/\(myNumber)")
            }
        )
        state.micPermissionGranted = true

        // First cycle.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 1 }

        // Second cycle while first is in-flight.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 2 }

        // Wait for both to complete.
        await waitUntil { state.jobs.filter { $0.state == .done }.count == 2 }

        // SC-4: both jobs completed with their own distinct results — no cross-job bleed.
        XCTAssertEqual(state.jobs.filter { $0.state == .done }.count, 2, "both jobs must complete as .done (SC-4)")
        XCTAssertNotNil(state.jobs[0].result, "jobs[0] must have a result")
        XCTAssertNotNil(state.jobs[1].result, "jobs[1] must have a result")
        XCTAssertNotEqual(
            state.jobs[0].result?.number,
            state.jobs[1].result?.number,
            "concurrent jobs must have distinct issue numbers — no cross-job result bleed (SC-4)"
        )
    }

    func testCaptureReturnsToIdleImmediatelyWhenFilingBegins() async throws {
        // CONCUR-01: captureState == .idle as soon as transcription succeeds —
        // filing runs independently in jobs[0], not in captureState.
        let repoURL = try makeRepo(named: "idle-on-filing-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "idle-on-filing-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "idle-on-filing-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "a transcript" },
            onRunIssueFiling: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(300))
                return IssueFilingResult(number: 7, url: "https://github.com/o/r/issues/7")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for a job to be spawned (transcription has completed)
        await waitUntil { state.jobs.count == 1 }

        // Capture is immediately idle; the filing runs in jobs[0]
        XCTAssertEqual(state.captureState, .idle, "captureState must be .idle while filing runs in jobs[0] (CONCUR-01)")
        XCTAssertEqual(state.jobs[0].state, .filing, "jobs[0].state must be .filing while the seam is in-flight")

        // Let the job finish
        await waitUntil { state.jobs[0].state == .done }
        XCTAssertEqual(state.jobs[0].state, .done)
    }

    func testFilingJobTrackedInJobsArray() async throws {
        // D-06: terminal jobs are retained; jobs array grows per filing.
        let repoURL = try makeRepo(named: "jobs-array-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "jobs-array-repo", displayPath: repoURL.path)
        var spokenText: String?
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "jobs-array-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "create an issue" },
            onRunIssueFiling: { _, _, _ in
                IssueFilingResult(number: 42, url: "https://github.com/o/r/issues/42")
            },
            onSpeak: { text in spokenText = text }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .done }

        XCTAssertEqual(state.jobs.count, 1, "one filing produces one job entry")
        XCTAssertEqual(state.jobs[0].state, .done)
        XCTAssertNotNil(state.jobs[0].result)
        XCTAssertEqual(state.jobs[0].result?.number, 42)
        XCTAssertTrue(spokenText?.contains("42") == true, "spoken text must announce the issue number")
    }

    // MARK: - Cancel scaffolds (fleshed out in 06-03)

    func testCancelJobIdTransitionsToCancel() async throws {
        // CANCEL-01 / CANCEL-02 / SC-1 / SC-2: cancelling one job by ID drives its state to
        // .cancelled and speaks "filing cancelled" via onSpeak seam (D-05); result is nil.
        let repoURL = try makeRepo(named: "cancel-job-id-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "cancel-job-id-repo", displayPath: repoURL.path)
        var spokenTexts: [String] = []
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "cancel-job-id-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "cancel me" },
            onRunIssueFiling: { _, _, _ in
                // Task.sleep throws CancellationError when the enclosing Task is cancelled.
                try await Task.sleep(for: .seconds(60))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            },
            onSpeak: { text in spokenTexts.append(text) }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        // Wait for the job to be in-flight.
        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }

        // Cancel by job ID.
        state.cancel(jobID: state.jobs[0].id)

        // Wait for CancellationError catch arm to run.
        await waitUntil { state.jobs[0].state == .cancelled }

        XCTAssertEqual(state.jobs[0].state, .cancelled, "cancelled job must reach .cancelled (CANCEL-01)")
        XCTAssertEqual(spokenTexts.first, "filing cancelled", "cancelled job must speak 'filing cancelled' (CANCEL-02/D-05)")
        XCTAssertNil(state.jobs[0].result, "cancelled job must have no result — no issue filed (CANCEL-02)")
    }

    func testCancelAnnouncementDeferredDuringRecording() async throws {
        // D-02 / D-03 / D-05: while captureState == .recording, the cancelled announcement
        // is deferred to pendingAnnouncements and flushed after stopRecording() is called.
        let repoURL = try makeRepo(named: "cancel-deferred-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "cancel-deferred-repo", displayPath: repoURL.path)
        var spokenTexts: [String] = []
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "cancel-deferred-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "cancel deferred" },
            onRunIssueFiling: { _, _, _ in
                try await Task.sleep(for: .seconds(60))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            },
            onSpeak: { text in spokenTexts.append(text) }
        )
        state.micPermissionGranted = true

        // First cycle — spawns a sleeping filing job.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }

        // Start a second recording so captureState == .recording (announce will defer).
        state.startRecording()
        XCTAssertEqual(state.captureState, .recording, "precondition: captureState must be .recording")

        // Cancel the first job while the second recording is active.
        state.cancel(jobID: state.jobs[0].id)

        // Wait for the CancellationError catch arm to store .cancelled.
        await waitUntil { state.jobs[0].state == .cancelled }

        // D-02: announcement was deferred because captureState == .recording.
        XCTAssertTrue(spokenTexts.isEmpty, "onSpeak must NOT be called while captureState == .recording (D-02)")

        // Stop the second recording — flushPendingAnnouncements() fires inside beginTranscription().
        state.stopRecording()

        // D-03: deferred "filing cancelled" announcement flushed after recording stops.
        await waitUntil { !spokenTexts.isEmpty }
        XCTAssertEqual(spokenTexts.first, "filing cancelled",
            "deferred cancel announcement must be flushed when recording stops (D-03), got: \(spokenTexts.first ?? "nil")")
    }

    func testCancelAllCancelsEveryInFlightJob() async throws {
        // CANCEL-03 prep: cancelAll() drives every in-flight (.filing) job to .cancelled.
        let repoURL = try makeRepo(named: "cancel-all-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "cancel-all-repo", displayPath: repoURL.path)
        var transcriptIdx = 0
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "cancel-all-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in
                defer { transcriptIdx += 1 }
                return "transcript \(transcriptIdx + 1)"
            },
            onRunIssueFiling: { _, _, _ in
                try await Task.sleep(for: .seconds(60))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.micPermissionGranted = true

        // First cycle — spawns a sleeping job.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 1 && state.captureState == .idle }

        // Second cycle while first job is still in-flight.
        state.startRecording()
        state.stopRecording()
        await waitUntil { state.jobs.count == 2 }

        // Both jobs must be .filing before cancelAll().
        await waitUntil { state.jobs.filter { $0.state == .filing }.count == 2 }

        state.cancelAll()

        // Both must reach .cancelled.
        await waitUntil { state.jobs.filter { $0.state == .cancelled }.count == 2 }

        XCTAssertEqual(state.jobs[0].state, .cancelled, "jobs[0] must be .cancelled after cancelAll()")
        XCTAssertEqual(state.jobs[1].state, .cancelled, "jobs[1] must be .cancelled after cancelAll()")
    }

    func testCancelledJobRetainedInJobsList() async throws {
        // D-02 / D-03: a cancelled job is retained in state.jobs, not deleted —
        // jobs.count stays at 1 and jobs[0].state == .cancelled.
        let repoURL = try makeRepo(named: "cancel-retained-repo")
        let binding = RepoBinding(rootURL: repoURL, displayName: "cancel-retained-repo", displayPath: repoURL.path)
        let state = AppState(
            boundRepo: binding,
            boundRepoDisplayText: "cancel-retained-repo",
            onStartRecording: { true },
            onStopRecording: {},
            onRunTranscription: { _ in "retained cancel" },
            onRunIssueFiling: { _, _, _ in
                try await Task.sleep(for: .seconds(60))
                return IssueFilingResult(number: 1, url: "https://github.com/o/r/issues/1")
            }
        )
        state.micPermissionGranted = true
        state.startRecording()
        state.stopRecording()

        await waitUntil { state.jobs.count == 1 && state.jobs[0].state == .filing }

        state.cancel(jobID: state.jobs[0].id)

        await waitUntil { state.jobs[0].state == .cancelled }

        // D-02/D-03: retained in jobs[], not deleted.
        XCTAssertEqual(state.jobs.count, 1, "cancelled job must be retained in jobs[] (D-02/D-03)")
        XCTAssertEqual(state.jobs[0].state, .cancelled, "retained job state must be .cancelled")
    }
}
