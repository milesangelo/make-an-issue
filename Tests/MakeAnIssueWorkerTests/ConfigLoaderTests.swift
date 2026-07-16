import Darwin
import Foundation
import XCTest
@testable import MakeAnIssueWorkerCore

final class ConfigLoaderTests: XCTestCase {
    func testLoadsCompleteSchemaAndSnapshotsReferencedInstructions() throws {
        let fixture = try ConfigFixture()

        let config = try fixture.snapshot()

        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertEqual(config.revision.count, 64)
        XCTAssertEqual(config.worker.pollIntervalSeconds, 60)
        XCTAssertEqual(config.worker.workspaceBackend, .treehouse)
        XCTAssertEqual(config.worker.publisherBackend, .auto)
        XCTAssertEqual(config.providers.map(\.kind), [.claudeCode])
        XCTAssertEqual(config.agents.first?.instructions, "Fix only the requested issue.\n")
        XCTAssertEqual(config.routes.map(\.priority), [300, 200])
        XCTAssertEqual(config.repositories.first?.repository, "acme/widgets")
        XCTAssertFalse(config.redactedSnapshot.contains("Fix only the requested issue"))
        XCTAssertFalse(config.redactedSnapshot.contains("--model"))
    }

    func testSchemaVersionMismatchHasGuidance() throws {
        let fixture = try ConfigFixture { $0.replacingOccurrences(of: "schema_version = 1", with: "schema_version = 2") }

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            let configError = error as? ConfigError
            XCTAssertEqual(configError?.key, "schema_version")
            XCTAssertTrue(configError?.reason.contains("install a compatible worker") == true)
            XCTAssertEqual(configError?.file, fixture.configURL.path)
        }
    }

    func testRejectsUnknownProviderKindPrecisely() throws {
        let fixture = try ConfigFixture { $0.replacingOccurrences(of: "kind = \"claude-code\"", with: "kind = \"shell\"") }

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            let configError = error as? ConfigError
            XCTAssertEqual(configError?.key, "providers[claude-primary].kind")
            XCTAssertTrue(configError?.reason.contains("unknown provider kind shell") == true)
        }
    }

    func testRejectsEqualRoutePrioritiesEvenWhenRoutesDiffer() throws {
        let fixture = try ConfigFixture { $0.replacingOccurrences(of: "priority = 200", with: "priority = 300") }

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            let configError = error as? ConfigError
            XCTAssertEqual(configError?.key, "routes[].priority")
            XCTAssertTrue(configError?.reason.contains("urgent-bug, bug") == true)
        }
    }

    func testRejectsUnknownKeysAtTheirFullPath() throws {
        let fixture = try ConfigFixture { value in
            value.replacingOccurrences(of: "publisher_backend = \"auto\"", with: "publisher_backend = \"auto\"\nmagic = true")
        }

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            let configError = error as? ConfigError
            XCTAssertEqual(configError?.key, "worker.magic")
            XCTAssertEqual(configError?.reason, "unknown key")
        }
    }

    func testRejectsMissingReferences() throws {
        let fixture = try ConfigFixture { $0.replacingOccurrences(of: "provider = \"claude-primary\"", with: "provider = \"missing\"") }

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            let configError = error as? ConfigError
            XCTAssertEqual(configError?.key, "agents[bugfix].provider")
            XCTAssertTrue(configError?.reason.contains("missing provider") == true)
        }
    }

    func testRejectsSymlinkConfigWithoutFollowingIt() throws {
        let fixture = try ConfigFixture()
        let symlink = fixture.root.appendingPathComponent("linked.toml")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.configURL)

        XCTAssertThrowsError(try ConfigLoader().load(from: symlink)) { error in
            XCTAssertTrue(String(describing: error).contains("must not be a symlink"))
        }
    }

    func testRejectsGroupWritableConfig() throws {
        let fixture = try ConfigFixture()
        chmod(fixture.configURL.path, 0o620)

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            XCTAssertTrue(String(describing: error).contains("group- or world-writable"))
        }
    }

    func testRejectsEnvironmentAssignmentsInProviderArgv() throws {
        let fixture = try ConfigFixture { $0.replacingOccurrences(of: "argv = [\"--model\", \"sonnet\"]", with: "argv = [\"TOKEN=secret\"]") }

        XCTAssertThrowsError(try fixture.snapshot()) { error in
            let configError = error as? ConfigError
            XCTAssertEqual(configError?.key, "providers[claude-primary].argv[0]")
            XCTAssertTrue(configError?.reason.contains("environment assignments") == true)
        }
    }
}
