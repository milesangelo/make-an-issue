import XCTest
@testable import MakeAnIssue

/// Tests for `IssueResultParser.parse()` — pure function, no process spawn.
/// Covers tool_result structured path, prose fallback, permission_denials gate,
/// and the critical rule that the issue number comes from the url path, not the id field.
final class IssueResultParserTests: XCTestCase {

    // MARK: - Structured tool_result path

    func testStructuredToolResultReturnsNumberFromURLPath() throws {
        // The tool_result content contains `"id"` (GitHub's internal node id) and `"url"`.
        // The issue NUMBER must come from the url path (/issues/89), never from the id field.
        let stdout = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"{\\"id\\":\\"MDU6SXNzdWU0NzQ3Mzk4MTcx\\",\\"url\\":\\"https://github.com/owner/repo/issues/89\\"}"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Issue filed.","session_id":"s1","total_cost_usd":0.01,"num_turns":1,"permission_denials":[]}
        """

        let result = try IssueResultParser.parse(stdout: stdout)

        XCTAssertEqual(result.number, 89, "Number must come from url path (/issues/89), not the id field")
        XCTAssertEqual(result.url, "https://github.com/owner/repo/issues/89")
    }

    func testStructuredToolResultWithArrayContent() throws {
        // tool_result block content can also be an array of objects with "text" keys
        let stdout = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"toolu_xyz","content":[{"type":"text","text":"{\\"id\\":\\"node123\\",\\"url\\":\\"https://github.com/acme/widgets/issues/42\\"}"}]}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Filed.","session_id":"s2","total_cost_usd":0.01,"num_turns":1,"permission_denials":[]}
        """

        let result = try IssueResultParser.parse(stdout: stdout)

        XCTAssertEqual(result.number, 42)
        XCTAssertEqual(result.url, "https://github.com/acme/widgets/issues/42")
    }

    // MARK: - Prose fallback

    func testProseFallbackWhenNoToolResult() throws {
        // No tool_result block — only a result event with the URL in the prose text.
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,"result":"I have filed the issue. Issue URL: https://github.com/owner/repo/issues/42","session_id":"s3","total_cost_usd":0.01,"num_turns":1,"permission_denials":[]}
        """

        let result = try IssueResultParser.parse(stdout: stdout)

        XCTAssertEqual(result.number, 42, "Prose fallback must extract number from url path")
        XCTAssertEqual(result.url, "https://github.com/owner/repo/issues/42")
    }

    // MARK: - Structured wins over prose when both are present

    func testStructuredWinsOverProseWhenBothPresent() throws {
        // Structured result says issue 89; prose text mentions issue 99.
        // The structured tool_result must win.
        let stdout = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"{\\"id\\":\\"node-id-here\\",\\"url\\":\\"https://github.com/owner/repo/issues/89\\"}"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Issue URL: https://github.com/owner/repo/issues/99","session_id":"s4","total_cost_usd":0.01,"num_turns":1,"permission_denials":[]}
        """

        let result = try IssueResultParser.parse(stdout: stdout)

        XCTAssertEqual(result.number, 89, "Structured tool_result must win over prose when both present")
    }

    // MARK: - permission_denials gate

    func testPermissionDeniedDetected() throws {
        // Non-empty permission_denials means no issue was filed — even if the result string
        // looks successful. The parser must throw .permissionDenied with the denied tool names.
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,"result":"I was unable to call the tool.","session_id":"s5","total_cost_usd":0.01,"num_turns":1,"permission_denials":[{"tool_name":"mcp__github__issue_write","tool_use_id":"toolu_001","tool_input":{}}]}
        """

        XCTAssertThrowsError(try IssueResultParser.parse(stdout: stdout)) { error in
            guard case IssueParseError.permissionDenied(let tools) = error else {
                XCTFail("Expected .permissionDenied, got \(error)")
                return
            }
            XCTAssertEqual(tools, ["mcp__github__issue_write"])
        }
    }

    func testPermissionDeniedBeatsSuccessfulToolResult() throws {
        // Even if there is a tool_result block that looks successful, a non-empty
        // permission_denials must cause the parser to throw (belt-and-suspenders).
        let stdout = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"{\\"id\\":\\"node-id\\",\\"url\\":\\"https://github.com/owner/repo/issues/89\\"}"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Filed.","session_id":"s6","total_cost_usd":0.01,"num_turns":1,"permission_denials":[{"tool_name":"mcp__github__issue_write","tool_use_id":"toolu_abc","tool_input":{}}]}
        """

        XCTAssertThrowsError(try IssueResultParser.parse(stdout: stdout)) { error in
            if case IssueParseError.permissionDenied(_) = error {
                // Expected
            } else {
                XCTFail("Expected .permissionDenied, got \(error)")
            }
        }
    }

    // MARK: - noIssueFound

    func testNoIssueFoundWhenNothingParseable() throws {
        // Stream has no tool_result url and the result string has no github url.
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,"result":"I investigated the repo but could not file the issue.","session_id":"s7","total_cost_usd":0.01,"num_turns":1,"permission_denials":[]}
        """

        XCTAssertThrowsError(try IssueResultParser.parse(stdout: stdout)) { error in
            XCTAssertEqual(error as? IssueParseError, .noIssueFound)
        }
    }

    func testEmptyStdoutThrowsNoIssueFound() throws {
        XCTAssertThrowsError(try IssueResultParser.parse(stdout: "")) { error in
            XCTAssertEqual(error as? IssueParseError, .noIssueFound)
        }
    }

    func testMalformedJSONLinesAreSkipped() throws {
        // Lines that fail JSON decode are skipped; only valid lines are processed.
        // Here, the valid result line has no url — expect noIssueFound.
        let stdout = """
        not-json
        {"broken": true
        {"type":"result","subtype":"success","is_error":false,"result":"No url here.","session_id":"s8","total_cost_usd":0.01,"num_turns":1,"permission_denials":[]}
        """

        XCTAssertThrowsError(try IssueResultParser.parse(stdout: stdout)) { error in
            XCTAssertEqual(error as? IssueParseError, .noIssueFound)
        }
    }
}
