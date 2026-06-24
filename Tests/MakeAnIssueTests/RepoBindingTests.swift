import XCTest
@testable import MakeAnIssue

final class RepoBindingTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testResolvesAncestorWithGitDirectory() throws {
        let repo = temporaryDirectory.appendingPathComponent("example repo", isDirectory: true)
        let nested = repo.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let binding = RepoBinding.resolve(from: nested)

        XCTAssertEqual(binding?.rootURL.standardizedFileURL, repo.standardizedFileURL)
        XCTAssertEqual(binding?.displayName, "example repo")
        XCTAssertEqual(binding?.displayPath, repo.path)
    }

    func testResolvesAncestorWithGitFile() throws {
        let repo = temporaryDirectory.appendingPathComponent("worktree", isDirectory: true)
        let nested = repo.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/worktree\n"
            .write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let binding = RepoBinding.resolve(from: nested)

        XCTAssertEqual(binding?.rootURL.standardizedFileURL, repo.standardizedFileURL)
        XCTAssertEqual(binding?.displayName, "worktree")
    }

    func testReturnsNilOutsideGitRepository() throws {
        let nested = temporaryDirectory.appendingPathComponent("plain/subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertNil(RepoBinding.resolve(from: nested))
    }

    func testResolvesPathContainingSpaces() throws {
        let repo = temporaryDirectory.appendingPathComponent("repo with spaces", isDirectory: true)
        let nested = repo.appendingPathComponent("nested folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let binding = RepoBinding.resolve(from: nested)

        XCTAssertEqual(binding?.displayName, "repo with spaces")
        XCTAssertEqual(binding?.displayPath, repo.path)
    }
}
