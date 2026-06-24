import XCTest
@testable import MakeAnIssue

final class LaunchRequestStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testWriteAndConsumeRemovesRequestFile() throws {
        let store = LaunchRequestStore(requestDirectory: temporaryDirectory)
        let request = LaunchRequest(cwd: "/tmp/example repo", createdAtUnixSeconds: 1_710_000_000)

        try store.write(request)

        let consumed = try store.consumeLatest()
        XCTAssertEqual(consumed, request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.requestFileURL.path))
    }

    func testConsumeLatestReturnsNilWhenMissing() throws {
        let store = LaunchRequestStore(requestDirectory: temporaryDirectory)

        XCTAssertNil(try store.consumeLatest())
    }

    func testMalformedJSONIsClearedAndReturnsNil() throws {
        let store = LaunchRequestStore(requestDirectory: temporaryDirectory)
        try "{not-json".write(to: store.requestFileURL, atomically: true, encoding: .utf8)

        XCTAssertNil(try store.consumeLatest())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.requestFileURL.path))
    }

    func testDecodesShellWrittenLaunchRequestFixture() throws {
        let data = Data(#"{"cwd":"/tmp/example repo","createdAtUnixSeconds":1710000000}"#.utf8)

        let request = try JSONDecoder().decode(LaunchRequest.self, from: data)

        XCTAssertEqual(request.cwd, "/tmp/example repo")
        XCTAssertEqual(request.createdAtUnixSeconds, 1_710_000_000)
    }

    func testConsumesShellWrittenLaunchRequestFixture() throws {
        let store = LaunchRequestStore(requestDirectory: temporaryDirectory)
        try #"{"cwd":"/tmp/example repo","createdAtUnixSeconds":1710000000}"#
            .write(to: store.requestFileURL, atomically: true, encoding: .utf8)

        let request = try store.consumeLatest()

        XCTAssertEqual(request?.cwd, "/tmp/example repo")
        XCTAssertEqual(request?.createdAtUnixSeconds, 1_710_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.requestFileURL.path))
    }
}
