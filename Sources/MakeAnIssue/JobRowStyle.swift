import SwiftUI

/// Pure per-state styling for a jobs-list row, plus a done-row URL-open safety guard.
///
/// `JobRowStyle` is a plain (non-`@MainActor`) namespace enum with no cases — every member is
/// `nonisolated static`, so it is callable from tests without hopping the main actor. This is
/// what makes per-state icon/color mapping and the URL guard unit-testable in a project with no
/// rendered-view test infra (ViewInspector/SnapshotTesting are not in Package.swift); the view
/// composition in Plan 09-02 is a thin, manual-UAT-only shell over these pure functions.
enum JobRowStyle {

    /// A distinct SF Symbol per `FilingJobState`, for the jobs-list row icon (JOBS-01, D-01).
    static func iconName(for state: FilingJobState) -> String {
        switch state {
        case .filing:
            return "arrow.triangle.2.circlepath"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle"
        }
    }

    /// A tint color per `FilingJobState`, distinct from `StateBadge`'s capture-state palette
    /// (`.filing` uses `.blue`, not `StateBadge`'s `.orange`, so the two indicators never
    /// visually collide in the same window).
    static func tintColor(for state: FilingJobState) -> Color {
        switch state {
        case .filing:
            return .blue
        case .done:
            return .green
        case .failed:
            return Color.amberStyle
        case .cancelled:
            return .secondary
        }
    }

    /// Parses `raw` into a `URL` and returns it ONLY when its scheme is `https` (case-insensitive).
    /// Returns `nil` for any other scheme (http, javascript, file, mailto, …) or unparseable input.
    ///
    /// This is the D-10 done-row open guard: `IssueFilingResult.url` originates from `claude`
    /// stdout, regex-parsed by `IssueResultParser`. The parser's github-anchored regex is the
    /// first layer of trust; this is defense-in-depth at the `NSWorkspace.shared.open` call site
    /// in Plan 09-02 (T-09-02, ASVS V5 input validation).
    static func openableIssueURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }
}
