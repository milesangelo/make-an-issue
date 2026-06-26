import Foundation

/// The result of a successful issue filing parse — the human-facing issue number and URL.
struct IssueFilingResult {
    /// The GitHub issue number extracted from the url path (/issues/N).
    /// This is NEVER the GitHub internal node id field.
    let number: Int
    /// The full issue URL, e.g. "https://github.com/owner/repo/issues/89".
    let url: String
}

/// Errors thrown by `IssueResultParser.parse()`.
enum IssueParseError: Error, Equatable {
    /// A tool was denied — `permission_denials` was non-empty. No issue was filed.
    case permissionDenied([String])
    /// The stream ran to completion but no parseable issue url was found.
    case noIssueFound
    /// The stream output was structurally malformed and could not be interpreted.
    case malformedOutput
}

/// Parses the JSONL stdout produced by `claude -p --output-format stream-json --verbose`
/// to extract the newly filed GitHub issue number and URL.
///
/// Two-pass algorithm (ported from spike 002 `parse-issue.js`):
/// 1. Walk `assistant` message content blocks for `tool_result` blocks → extract url via regex.
/// 2. Fall back to prose regex over the `result` event's `result` string.
/// 3. A parsed issue url wins — return it before inspecting permission_denials. Only if no url
///    was found AND `permission_denials` is non-empty, throw `.permissionDenied`.
///
/// Critical rule: the issue NUMBER lives ONLY in the url path (`/issues/N`), NEVER in the
/// `id` field of the GitHub MCP `issue_write` result. [Spike 002, T-04-03]
struct IssueResultParser {

    // MARK: - Regex (compiled once, static)

    /// Matches the structured url field in a tool_result JSON body.
    /// Capture group 1: full url. Capture group 2: issue number digits.
    private static let structuredURLRegex: NSRegularExpression = {
        // Matches: "url": "https://github.com/owner/repo/issues/89"
        // Also catches "html_url" as a secondary structural match.
        try! NSRegularExpression(
            pattern: #""(?:url|html_url)"\s*:\s*"(https?://github\.com/[^"]+/issues/(\d+))""#
        )
    }()

    /// Matches a bare GitHub issues url in prose text.
    /// Capture group 1: issue number digits.
    private static let proseURLRegex: NSRegularExpression = {
        // Matches: https://github.com/owner/repo/issues/42  (stops at space/)/"/')
        try! NSRegularExpression(
            pattern: #"https?://github\.com/[^\s)"']+/issues/(\d+)"#
        )
    }()

    // MARK: - Public API

    /// Parse the JSONL stdout and return the filed issue's number and URL.
    ///
    /// - Parameter stdout: The raw stdout string from `claude -p --output-format stream-json --verbose`.
    /// - Returns: `IssueFilingResult` with the issue number (from url path) and full url.
    /// - Throws:
    ///   - `IssueParseError.permissionDenied([String])` when `permission_denials` is non-empty
    ///     AND no issue url was found — indicates no issue was filed even if exit code was 0.
    ///   - `IssueParseError.noIssueFound` when the stream completed but no parseable url appeared.
    static func parse(stdout: String) throws -> IssueFilingResult {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)

        var fromToolResult: IssueFilingResult? = nil
        var finalResultText: String = ""
        var deniedTools: [String] = []

        for line in lines {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Result envelope — capture prose text and permission_denials.
            if obj["type"] as? String == "result" {
                if let text = obj["result"] as? String {
                    finalResultText = text
                }
                if let denials = obj["permission_denials"] as? [[String: Any]] {
                    deniedTools = denials.compactMap { $0["tool_name"] as? String }
                }
            }

            // Assistant message — walk content blocks for tool_result entries.
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_result" {
                    // Normalize content: may be a plain String or an array of {text:…} objects.
                    let text: String
                    if let s = block["content"] as? String {
                        text = s
                    } else if let arr = block["content"] as? [[String: Any]] {
                        text = arr.compactMap { $0["text"] as? String }.joined()
                    } else {
                        continue
                    }

                    if let result = extractFromStructuredText(text) {
                        fromToolResult = result
                    }
                }
            }
        }

        // A parsed issue url is proof the issue was filed — success wins over any denial.
        // Structured tool_result result wins over prose.
        if let r = fromToolResult { return r }

        // Prose fallback: regex the final result text.
        if let r = extractFromProseText(finalResultText) { return r }

        // No url found. If tools were denied, surface the denial — the filing did not succeed.
        if !deniedTools.isEmpty {
            throw IssueParseError.permissionDenied(deniedTools)
        }

        throw IssueParseError.noIssueFound
    }

    // MARK: - Private helpers

    private static func extractFromStructuredText(_ text: String) -> IssueFilingResult? {
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = structuredURLRegex.firstMatch(in: text, range: range),
            let urlRange = Range(match.range(at: 1), in: text),
            let numRange = Range(match.range(at: 2), in: text),
            let number = Int(text[numRange])
        else { return nil }
        return IssueFilingResult(number: number, url: String(text[urlRange]))
    }

    private static func extractFromProseText(_ text: String) -> IssueFilingResult? {
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = proseURLRegex.firstMatch(in: text, range: range),
            let urlRange = Range(match.range(at: 0), in: text),
            let numRange = Range(match.range(at: 1), in: text),
            let number = Int(text[numRange])
        else { return nil }
        return IssueFilingResult(number: number, url: String(text[urlRange]))
    }
}
