import Foundation

/// The state of an individual filing job.
///
/// `FilingJobState` is `Equatable` so tests can assert job state directly.
/// `.cancelled` is Phase 6 forward-prep — the model shape is established here;
/// the cancellation mechanics (`.cancel()` on the task handle) are added in Phase 6.
enum FilingJobState: Equatable {
    case filing
    case done
    case failed
    case cancelled   // Phase 6 forward-prep — mechanics owned by Phase 6
}

/// An independent per-recording filing job tracked in `AppState.jobs`.
///
/// Each job captures the transcript and repo by value at spawn time (Pitfall 1 — never
/// read from `self.transcript` after an `await`). `Identifiable` conformance is required
/// for Phase 9's `ForEach` job list (JOBS-01); add now per D-06.
///
/// `task` is the cancellation handle for Phase 6 (stored here, `.cancel()` wired in Phase 6).
struct FilingJob: Identifiable {
    let id: UUID
    /// The originating transcript, captured by value at spawn time (D-06 / Pitfall 1).
    let transcript: String
    /// The bound repo at filing time, captured by value at spawn time (D-06 / Pitfall 1).
    let repo: RepoBinding
    /// The current state of this job (D-06).
    var state: FilingJobState
    /// Set on success — the filed issue number and URL (D-06).
    var result: IssueFilingResult?
    /// Set on typed failure — the `IssueFilingError` thrown by the filing pipeline (D-06).
    var error: IssueFilingError?
    /// Cancellation handle for Phase 6. Stored here; `.cancel()` is wired in Phase 6.
    var task: Task<Void, Never>?
    /// Process group id of the filing subprocess. Set by AppState once CLIRunner starts
    /// (06-03); read for quit-time SIGKILL in AppDelegate.forceKillAllProcessTrees() (06-04).
    var processGroupID: pid_t?
}
