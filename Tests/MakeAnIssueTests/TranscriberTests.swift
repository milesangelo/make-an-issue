import XCTest
@testable import MakeAnIssue

/// Tests for `Transcriber.prepare()` — pure function, no process spawn.
/// Covers command validation (D-03, D-05) and POSIX single-quote path substitution (T-03-05).
final class TranscriberTests: XCTestCase {

    // MARK: - emptyCommand

    func testEmptyCommandThrowsEmptyCommandError() {
        let wavURL = URL(fileURLWithPath: "/tmp/test.wav")
        XCTAssertThrowsError(try Transcriber.prepare(command: "", wavURL: wavURL)) { error in
            XCTAssertEqual(error as? TranscriberError, .emptyCommand)
        }
    }

    func testWhitespaceOnlyCommandThrowsEmptyCommandError() {
        let wavURL = URL(fileURLWithPath: "/tmp/test.wav")
        XCTAssertThrowsError(try Transcriber.prepare(command: "   \t\n  ", wavURL: wavURL)) { error in
            XCTAssertEqual(error as? TranscriberError, .emptyCommand)
        }
    }

    // MARK: - missingWavToken

    func testMissingWavTokenError() {
        let wavURL = URL(fileURLWithPath: "/tmp/latest.wav")
        // Command is non-empty but has no {wav} token (D-05)
        XCTAssertThrowsError(try Transcriber.prepare(command: "whisper --model base", wavURL: wavURL)) { error in
            XCTAssertEqual(error as? TranscriberError, .missingWavToken)
        }
    }

    func testNonEmptyCommandWithoutWavTokenThrowsMissingWavToken() {
        let wavURL = URL(fileURLWithPath: "/tmp/latest.wav")
        XCTAssertThrowsError(try Transcriber.prepare(command: "echo hello", wavURL: wavURL)) { error in
            XCTAssertEqual(error as? TranscriberError, .missingWavToken)
        }
    }

    // MARK: - {wav} substitution

    func testWavSubstitutionQuoting() throws {
        let wavURL = URL(fileURLWithPath: "/Users/me/Library/Application Support/MakeAnIssue/latest.wav")
        let result = try Transcriber.prepare(command: "whisper {wav} --model base", wavURL: wavURL)

        // The path must be wrapped in single quotes so it survives as a single shell word (T-03-05)
        XCTAssertTrue(
            result.contains("'"),
            "Result must contain single quotes wrapping the WAV path"
        )
        // The quoted path must appear in the substituted command
        let expectedQuoted = "'/Users/me/Library/Application Support/MakeAnIssue/latest.wav'"
        XCTAssertTrue(
            result.contains(expectedQuoted),
            "Result '\(result)' should contain single-quoted path '\(expectedQuoted)'"
        )
        // The {wav} token must not remain in the output
        XCTAssertFalse(result.contains("{wav}"), "Token {wav} must be replaced")
    }

    func testSubstitutionPreservesCommandParts() throws {
        let wavURL = URL(fileURLWithPath: "/tmp/latest.wav")
        let result = try Transcriber.prepare(command: "whisper {wav} --model base --language en", wavURL: wavURL)

        XCTAssertTrue(result.hasPrefix("whisper "))
        XCTAssertTrue(result.contains("--model base --language en"))
        XCTAssertFalse(result.contains("{wav}"))
    }

    func testPathWithSpaceIsWrappedInSingleQuotes() throws {
        // A path containing a space must be wrapped in single quotes so the shell treats it as one word.
        let wavURL = URL(fileURLWithPath: "/Users/test user/Library/latest.wav")
        let result = try Transcriber.prepare(command: "asr {wav}", wavURL: wavURL)

        // Entire path (with space) must be inside single quotes
        XCTAssertTrue(
            result.contains("'/Users/test user/Library/latest.wav'"),
            "Space-containing path must be wrapped in single quotes in '\(result)'"
        )
    }

    func testPathWithSingleQuoteIsEscaped() throws {
        // A path containing a single-quote must use the POSIX close/literal/reopen sequence:
        // path: /Users/o'brien/latest.wav
        // expected substitution: '/Users/o'\''brien/latest.wav'
        let wavURL = URL(fileURLWithPath: "/Users/o'brien/latest.wav")
        let result = try Transcriber.prepare(command: "asr {wav}", wavURL: wavURL)

        // The embedded single-quote must be escaped via the POSIX sequence: '\''
        XCTAssertTrue(
            result.contains("'\\''"),
            "Embedded single-quote must use POSIX escape sequence in '\(result)'"
        )
        // The path content must appear with the escape sequence applied
        XCTAssertTrue(
            result.contains("/Users/o'\\''" + "brien/latest.wav"),
            "Escaped path must appear in result '\(result)'"
        )
    }

    func testSimplePathSubstitution() throws {
        let wavURL = URL(fileURLWithPath: "/tmp/latest.wav")
        let result = try Transcriber.prepare(command: "echo {wav}", wavURL: wavURL)

        XCTAssertEqual(result, "echo '/tmp/latest.wav'")
    }
}
