import XCTest
@testable import MakeAnIssue

/// Tests for `Transcriber` bundled-binary path resolution and command construction.
/// All tests use an injectable `resourceBase` temp directory — the real ~466 MB
/// whisper-cli binary and model are never spawned (RESEARCH §Pitfall 6).
final class TranscriberTests: XCTestCase {

    // MARK: - bundledBinaryURL

    func testBundledBinaryURLThrowsWhenResourcesNil() throws {
        // Temp dir exists but does NOT contain whisper-cli.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(try Transcriber.bundledBinaryURL(resourceBase: tempDir)) { error in
            guard case .bundledResourcesMissing = error as? TranscriberError else {
                XCTFail("Expected .bundledResourcesMissing, got \(error)")
                return
            }
        }
    }

    // MARK: - bundledModelURL

    func testBundledModelURLThrowsWhenModelAbsent() throws {
        // Temp dir contains whisper-cli but NOT ggml-small.en.bin.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write whisper-cli so bundledBinaryURL would succeed.
        try Data().write(to: tempDir.appendingPathComponent("whisper-cli"))

        XCTAssertThrowsError(try Transcriber.bundledModelURL(resourceBase: tempDir)) { error in
            guard case .bundledResourcesMissing = error as? TranscriberError else {
                XCTFail("Expected .bundledResourcesMissing, got \(error)")
                return
            }
        }
    }

    // MARK: - run

    func testRunConstructsCorrectCommand() async throws {
        // Create a temp dir with a fake echo whisper-cli and a stub model.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Fake whisper-cli: a shell script that echoes all its arguments.
        let binaryURL = tempDir.appendingPathComponent("whisper-cli")
        try "#!/bin/sh\necho \"$@\"\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryURL.path
        )

        // Stub model file — content unused since the fake binary ignores it.
        try Data().write(to: tempDir.appendingPathComponent("ggml-small.en.bin"))

        let wavURL = URL(fileURLWithPath: "/tmp/test.wav")

        let result = try await Transcriber.run(wavURL: wavURL, resourceBase: tempDir)

        // The fake whisper-cli echoes its args; verify all required flags are present.
        XCTAssertTrue(result.contains("-m"), "Command must contain -m flag, got: '\(result)'")
        XCTAssertTrue(result.contains("-f"), "Command must contain -f flag, got: '\(result)'")
        XCTAssertTrue(result.contains("-l en"), "Command must contain -l en flag, got: '\(result)'")
        XCTAssertTrue(result.contains("-nt"), "Command must contain -nt flag, got: '\(result)'")
        XCTAssertTrue(result.contains("-t 4"), "Command must contain -t 4 flag, got: '\(result)'")
        // The WAV path must appear in the output (single-quoting by the caller
        // ensures it survived as a single shell word before echo received it).
        XCTAssertTrue(result.contains("/tmp/test.wav"), "WAV path must appear in output, got: '\(result)'")
    }
}
