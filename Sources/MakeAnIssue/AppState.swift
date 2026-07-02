import AVFoundation
import Combine
import Darwin
import Foundation
import KeyboardShortcuts

enum CaptureState: Equatable {
    case idle
    case recording
    /// ASR command is executing; results are in-flight (D-10).
    case transcribing
    // .finished and .filing removed — filing state now lives in FilingJob.state (D-08).
}

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option]))
}

@MainActor
final class AppState: ObservableObject {
    /// Shared UserDefaults key for the editable drafting-instructions field — must match
    /// @AppStorage in SettingsView (Pitfall 5 pattern, mirrors former cliCommandKey). (D-05)
    nonisolated static let instructionsKey = "instructions"

    /// Reads the persisted drafting instructions fresh from UserDefaults at call time — never
    /// cached on `self`/`@Published` — so each concurrent filing sees the current value with no
    /// staleness across in-flight jobs (D-02/SETTINGS-02). `nonisolated` so the async filing
    /// closure can call it without hopping the main actor; parameterized on `defaults` for tests.
    nonisolated static func currentPersistedInstructions(
        _ defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: AppState.instructionsKey) ?? ""
    }

    @Published var statusText: String
    @Published var launchCWD: String?
    @Published var boundRepo: RepoBinding?
    @Published var boundRepoDisplayText: String
    @Published var captureState: CaptureState = .idle
    @Published var micPermissionGranted: Bool = false
    /// Last successful transcript text (D-09, TRANSCRIBE-02).
    @Published var transcript: String?
    /// Last transcription failure reason; cleared when a new transcription starts.
    @Published var transcriptError: String?
    /// Active and terminal filing jobs for this session. Retained per D-06/D-07.
    @Published var jobs: [FilingJob] = []
    /// Announcements deferred while captureState == .recording (D-02/D-03).
    private var pendingAnnouncements: [String] = []

    // Anchors the AudioRecorder's lifetime and is the integration point for its
    // delegate callbacks (onRecordingError, wired in init). The start/stop seam
    // closures route commands; this property routes errors back. (IN-01)
    private let audioRecorder: AudioRecorder
    private let onStartRecording: () -> Bool
    private let onStopRecording: () -> Void
    /// Seam for transcription — the default wires the real Transcriber; tests inject a stub.
    private let onRunTranscription: (URL) async throws -> String
    /// Seam for issue filing — the default wires the real IssueFilingRunner; tests inject a stub.
    /// The third parameter is a per-job process-started callback forwarded to IssueFilingRunner.file(onProcessStarted:).
    private let onRunIssueFiling: (String, RepoBinding, @escaping @Sendable (pid_t) -> Void) async throws -> IssueFilingResult
    /// Stored AVSpeechSynthesizer — MUST be a stored property; a local variable is deallocated
    /// before speaking completes and produces no audio (Pitfall 1 in 04-RESEARCH.md).
    private let speechSynthesizer = AVSpeechSynthesizer()
    /// Seam for spoken confirmation — when nil the default `speak(_:)` method is used;
    /// tests inject a closure to capture the spoken string without producing audio.
    private let onSpeak: ((String) -> Void)?
    /// Seam for the live microphone-authorization re-check performed in
    /// `startRecording()`. The default reads the real TCC status; tests inject a
    /// deterministic value so the result does not depend on the host's TCC state. (WR-03)
    private let onCheckMicAuthorization: () -> Bool

    /// Maximum recording duration. If a key-up event is missed (focus change while
    /// held, dropped system event, menu-mode flapping), this caps the stuck
    /// "Recording…" state and auto-stops so the feature can recover. (WR-04)
    private let maxRecordingDuration: Duration
    private var recordingTimeoutTask: Task<Void, Never>?

    /// Convenience init for the running app: wires a real AudioRecorder and Transcriber into the seams.
    convenience init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound"
    ) {
        let recorder = AudioRecorder()
        self.init(
            statusText: statusText,
            launchCWD: launchCWD,
            boundRepo: boundRepo,
            boundRepoDisplayText: boundRepoDisplayText,
            onStartRecording: recorder.start,
            onStopRecording: recorder.stop,
            audioRecorder: recorder
        )
    }

    /// Designated init: accepts explicit seam closures for testing.
    ///
    /// - Parameters:
    ///   - onRunTranscription: Closure injected for testing — default wires the real Transcriber.
    ///     Signature: `(URL) async throws -> String` (wavURL → trimmed transcript or throws TranscriberError).
    ///   - onRunIssueFiling: Closure injected for testing — default wires the real IssueFilingRunner.
    ///     Signature: `(String, RepoBinding) async throws -> IssueFilingResult`.
    ///   - onSpeak: Closure injected for testing — default calls AVSpeechSynthesizer.speak().
    ///     Allows tests to capture the spoken string without producing audio.
    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound",
        onStartRecording: @escaping () -> Bool,
        onStopRecording: @escaping () -> Void,
        audioRecorder: AudioRecorder = AudioRecorder(),
        maxRecordingDuration: Duration = .seconds(120),
        onRunTranscription: @escaping (URL) async throws -> String = { url in
            try await Transcriber.run(wavURL: url)
        },
        onRunIssueFiling: @escaping (String, RepoBinding, @escaping @Sendable (pid_t) -> Void) async throws -> IssueFilingResult = { transcript, repo, onStarted in
            // Read the persisted drafting instructions fresh at invocation time — never cached
            // on self/@Published — so concurrent filings each see the current value with no
            // staleness across in-flight jobs (D-02/SETTINGS-02).
            let instructions = AppState.currentPersistedInstructions()
            return try await IssueFilingRunner.file(transcript: transcript, repo: repo, config: .claudeGitHub, ownerRepo: nil, instructions: instructions, onProcessStarted: onStarted)
        },
        onSpeak: ((String) -> Void)? = nil,
        onCheckMicAuthorization: @escaping () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
        self.audioRecorder = audioRecorder
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording
        self.maxRecordingDuration = maxRecordingDuration
        self.onRunTranscription = onRunTranscription
        self.onRunIssueFiling = onRunIssueFiling
        self.onSpeak = onSpeak
        self.onCheckMicAuthorization = onCheckMicAuthorization

        // Route encode/IO errors that occur after recording starts back into the
        // state machine. The delegate fires on a background audio thread, so hop
        // to the main actor before mutating @Published state.
        audioRecorder.onRecordingError = { [weak self] error in
            Task { @MainActor in
                self?.handleRecordingError(error)
            }
        }

        // [weak self] mirrors the recorder/permission closures above and avoids a
        // retain cycle through the global KeyboardShortcuts handler registry, which
        // would otherwise pin every AppState instance for the process lifetime (WR-03).
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.captureState == .idle else { return }
                self.startRecording()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.captureState == .recording else { return }
                self.stopRecording()
            }
        }

        // Request microphone permission at startup so TCC dialog appears before first recording.
        // Only ever PROMOTE to granted: a late-resolving denied result must not clobber a grant
        // that startRecording() re-discovered (or that a test set synchronously). The authoritative
        // re-check happens in startRecording() so a grant made in System Settings after launch is
        // honored without relaunch (WR-03).
        Task { [weak self] in
            let granted = await AppState.requestMicrophonePermission()
            if granted {
                self?.micPermissionGranted = true
            } else {
                self?.statusText = "Microphone access denied — enable in System Settings"
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            // macOS 13: AVAudioSession is unavailable on macOS; use AVCaptureDevice
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func startRecording() {
        // Only allow starting from .idle. This blocks re-entry during .recording
        // (D-04: ignore key repeats) and .transcribing. Under the jobs model,
        // filings run concurrently in the background and do not block PTT (D-09).
        guard captureState == .idle else { return }
        // Re-query the live authorization status instead of trusting the one-shot
        // startup result, so a grant made in System Settings after launch takes
        // effect without relaunch. Only promote — never revoke a flag a test set. (WR-03)
        if !micPermissionGranted, onCheckMicAuthorization() {
            micPermissionGranted = true
        }
        guard micPermissionGranted else {
            statusText = "Microphone access denied — enable in System Settings"
            captureState = .idle
            return
        }
        guard onStartRecording() else {
            statusText = "Recording failed — check microphone permission"
            captureState = .idle
            return
        }
        captureState = .recording
        scheduleRecordingTimeout()
    }

    func stopRecording() {
        guard captureState == .recording else { return }
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        onStopRecording()
        beginTranscription()
    }

    /// Shared transition into transcription, used by both the normal key-up stop
    /// and the max-duration cap. Centralizing it means a missed key-up that hits
    /// the cap still transcribes the captured audio instead of silently discarding
    /// it (WR-02). Enters `.transcribing` synchronously (D-10), then runs the ASR
    /// command off the main actor and routes the result back.
    private func beginTranscription() {
        captureState = .transcribing   // D-10: show transcribing state immediately
        flushPendingAnnouncements()    // D-02/D-03: drain announcements deferred during .recording
        transcriptError = nil           // clear stale error from prior attempt

        guard let wavURL = audioRecorder.latestWavURL else {
            captureState = .idle
            statusText = "Transcription failed — recording not found"
            return
        }

        Task {
            do {
                let text = try await onRunTranscription(wavURL)
                self.transcript = text
                NSLog("MakeAnIssue transcript: \(text)")
                self.captureState = .idle   // D-08: capture returns to idle immediately (CONCUR-01)
                if let repo = self.boundRepo {
                    self.spawnFilingJob(transcript: text, repo: repo)
                } else {
                    self.statusText = "No repository bound — cannot file"
                }
            } catch let error as TranscriberError {
                let message = Self.message(for: error)
                await MainActor.run {
                    self.transcriptError = message
                    self.statusText = message
                    self.captureState = .idle   // D-11: reset so next push-to-talk works
                }
            } catch {
                let message = "Transcription failed — \(error.localizedDescription)"
                await MainActor.run {
                    self.transcriptError = message
                    self.statusText = message
                    self.captureState = .idle
                }
            }
        }
    }

    /// Spawns an independent filing job for the given transcript and repo.
    ///
    /// Generalizes the former `beginFiling()` single-Task pattern to N concurrent jobs (CONCUR-02).
    /// `transcript` and `repo` are captured by value from the function parameters — never read
    /// from `self` properties after an `await` (Pitfall 1). Uses `[weak self]` to avoid a retain
    /// cycle (Pitfall 4). The Task inherits `@MainActor` isolation from the calling context —
    /// no `await MainActor.run {}` is needed inside (Pitfall 2).
    private func spawnFilingJob(transcript: String, repo: RepoBinding) {
        let id = UUID()
        jobs.append(FilingJob(id: id, transcript: transcript, repo: repo, state: .filing))

        // Build a @Sendable callback that hops to @MainActor before mutating jobs (the callback
        // fires on CLIRunner's non-main executor). Captures [weak self, id] to avoid a retain cycle.
        let onStarted: @Sendable (pid_t) -> Void = { [weak self, id] pgid in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[idx].processGroupID = pgid
                }
            }
        }

        let task = Task { [weak self, id, transcript, repo] in
            guard let self else { return }
            do {
                let result = try await onRunIssueFiling(transcript, repo, onStarted)
                // @MainActor-inherited Task — no MainActor.run needed after await.
                if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[idx].state = .done
                    self.jobs[idx].result = result
                }
                self.announce("created issue #\(result.number)")   // D-01
            } catch is CancellationError {
                // State transitions to .cancelled here, after the process is dead — never in
                // cancel(jobID:) which only calls task?.cancel() (D-02/D-03, avoids premature state).
                if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[idx].state = .cancelled   // retain in jobs[], do NOT remove (D-02/D-03)
                }
                self.announce("filing cancelled")   // D-05: routes through defer-until-mic-idle queue
            } catch let filingError as IssueFilingError {
                if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[idx].state = .failed
                    self.jobs[idx].error = filingError
                }
                self.announce("issue filing failed")   // D-04
            } catch {
                if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[idx].state = .failed
                }
                self.announce("issue filing failed")   // D-04
            }
        }

        // Store the task handle for cancellation.
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].task = task
        }
    }

    /// Cancel a single in-flight job by ID. No-ops for jobs not in .filing state.
    ///
    /// Only calls task?.cancel() — the .cancelled state transition is owned by the
    /// CancellationError catch arm in spawnFilingJob, after the process is confirmed dead (D-02/D-03).
    func cancel(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID && $0.state == .filing }) else { return }
        jobs[idx].task?.cancel()
        // State transition to .cancelled happens in the CancellationError catch arm, not here.
    }

    /// Cancel every in-flight (.filing) job's Task. The quit-path graceful API (CANCEL-03).
    func cancelAll() {
        for job in jobs where job.state == .filing {
            job.task?.cancel()
        }
    }

    /// Send a group SIGKILL to every still-filing job that has a stored process group id.
    /// Called by the quit path after SIGTERM grace expires (CANCEL-03 — sequenced in 06-04).
    /// Guards pgid > 0 to prevent accidentally signalling the app's own process group.
    func forceKillAllProcessTrees() {
        for job in jobs where job.state == .filing {
            if let pgid = job.processGroupID, pgid > 0 {
                kill(-pgid, SIGKILL)   // negative pid = signal the process group
            }
        }
    }

    /// Dismiss a single terminal job by ID, removing it from `jobs[]`. No-ops for a job that is
    /// still `.filing` — dismissal is not cancellation (D-05/D-06). Callers wanting to abort an
    /// in-flight job must use `cancel(jobID:)`; this method never calls `task?.cancel()`.
    func dismiss(jobID: UUID) {
        jobs.removeAll { $0.id == jobID && $0.state != .filing }
    }

    /// Remove every terminal (non-`.filing`) job from `jobs[]`. Active `.filing` jobs are left
    /// untouched (D-05). Uses the explicit `$0.state != .filing` predicate — not a negated
    /// "is terminal" helper — so a future 5th `FilingJobState` case can never be silently swept.
    func clearFinished() {
        jobs.removeAll { $0.state != .filing }
    }

    /// Speak text now if mic is not active; defer to `pendingAnnouncements` if recording (D-02/D-03).
    private func announce(_ text: String) {
        if captureState == .recording {
            pendingAnnouncements.append(text)
        } else {
            speakText(text)
        }
    }

    /// Drain all deferred announcements through TTS (D-02/D-03).
    private func flushPendingAnnouncements() {
        let pending = pendingAnnouncements
        pendingAnnouncements = []
        for text in pending {
            speakText(text)
        }
    }

    /// Routes through the `onSpeak` seam when set, otherwise calls the real TTS.
    /// Consolidates the seam-routing check in one place (preserves test injection).
    private func speakText(_ text: String) {
        if let onSpeak = onSpeak {
            onSpeak(text)
        } else {
            speak(text)
        }
    }

    /// Speak a confirmation string via native macOS TTS (FEEDBACK-01).
    ///
    /// Uses the stored `speechSynthesizer` — must be a stored property, not a local variable,
    /// so it remains alive until speaking completes (Pitfall 1 in 04-RESEARCH.md).
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        speechSynthesizer.speak(utterance)
    }

    /// Map a `TranscriberError` to a short user-facing message (D-11).
    private static func message(for error: TranscriberError) -> String {
        switch error {
        case .bundledResourcesMissing(let detail):
            return "Whisper not bundled — rebuild the app: \(detail)"
        case .asrFailed(let exitCode, let stderr):
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? stderr
            return "ASR failed (exit \(exitCode))\(tail.isEmpty ? "" : " — \(tail)")"
        case .asrTimedOut:
            return "ASR timed out after 120s"
        case .emptyTranscript:
            return "ASR produced no output — re-record and try again"
        }
    }

    /// Map an `IssueFilingError` to a short user-facing message.
    ///
    /// Only the success path speaks (v1 contract); failures surface as status text only.
    private static func message(for error: IssueFilingError) -> String {
        switch error {
        case .tokenAcquisitionFailed:
            return "Sign in to GitHub first: gh auth login"
        case .timeout:
            return "AI CLI timed out — check your internet connection"
        case .cliFailed(let exitCode, _):
            return "AI CLI failed (exit \(exitCode)) — see log"
        case .permissionDenied:
            return "Issue tool not granted — the AI CLI denied issue-write permission"
        case .parseFailed:
            return "Couldn't confirm an issue was filed — check GitHub (is Docker running?)"
        }
    }

    /// Recovery path for a stuck recording (missed key-up). Auto-stops at the
    /// max-duration cap and transcribes whatever was captured, so a dropped key-up
    /// never silently discards the user's speech (WR-02). The state machine then
    /// follows the normal transcription path back to .finished or .idle.
    func recordingDidTimeout() {
        guard captureState == .recording else { return }
        recordingTimeoutTask = nil
        onStopRecording()
        statusText = "Recording stopped — maximum duration reached; transcribing…"
        beginTranscription()
    }

    private func scheduleRecordingTimeout() {
        recordingTimeoutTask?.cancel()
        let duration = maxRecordingDuration
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.recordingDidTimeout()
        }
    }

    /// Called when the recorder reports an encode/IO failure after recording began.
    /// Resets the state machine and surfaces a message so the UI does not remain
    /// stuck on "Recording…" with a corrupt/empty capture.
    func handleRecordingError(_ error: Error?) {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        onStopRecording()
        captureState = .idle
        statusText = "Recording failed — \(error?.localizedDescription ?? "audio error")"
    }

    func handleLaunchRequest(_ request: LaunchRequest) {
        launchCWD = request.cwd
        if let binding = RepoBinding.resolve(from: URL(fileURLWithPath: request.cwd)) {
            boundRepo = binding
            statusText = "Bound to \(binding.displayName)"
            boundRepoDisplayText = binding.displayPath
        } else {
            statusText = "No git repository found"
        }
    }
}
