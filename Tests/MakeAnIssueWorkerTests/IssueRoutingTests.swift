import XCTest
@testable import MakeAnIssueWorkerCore

final class IssueRoutingTests: XCTestCase {
    func testParsesAndCanonicalizesGitHubIssueURL() throws {
        let issue = try IssueReference.parse("https://github.com/Acme/Widgets/issues/42")

        XCTAssertEqual(issue.repository, "acme/widgets")
        XCTAssertEqual(issue.issueNumber, 42)
        XCTAssertEqual(issue.url.absoluteString, "https://github.com/acme/widgets/issues/42")
    }

    func testRejectsNonGitHubOrNonIssueURLs() {
        for value in [
            "http://github.com/acme/widgets/issues/42",
            "https://example.com/acme/widgets/issues/42",
            "https://github.com/acme/widgets/pull/42",
            "https://github.com/acme/widgets/issues/0",
            "https://github.com/acme/widgets/issues/42?tab=comments",
        ] {
            XCTAssertThrowsError(try IssueReference.parse(value), value)
        }
    }

    func testResolvesHighestPriorityMatchingRoute() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let resolver = RouteResolver()
        let repository = try resolver.configuredRepository(for: makeIssue(), config: config)

        let resolved = try resolver.resolve(
            repository: repository,
            labels: ["agent:run", "bug", "priority:high"],
            agentOverride: nil,
            config: config
        )

        XCTAssertEqual(resolved.routeID, "urgent-bug")
        XCTAssertEqual(resolved.agent.id, "bugfix")
        XCTAssertEqual(resolved.provider.id, "claude-primary")
    }

    func testAgentOverrideBypassesLabelRouteButNotAgentValidation() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let resolver = RouteResolver()
        let repository = try resolver.configuredRepository(for: makeIssue(), config: config)

        let resolved = try resolver.resolve(
            repository: repository,
            labels: [],
            agentOverride: "bugfix",
            config: config
        )
        XCTAssertEqual(resolved.routeID, "cli-agent-override")

        XCTAssertThrowsError(
            try resolver.resolve(repository: repository, labels: [], agentOverride: "missing", config: config)
        ) { error in
            XCTAssertEqual(error as? IssueRoutingError, .agentNotConfigured("missing"))
        }
    }

    func testNoMatchingRouteFailsClosed() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let resolver = RouteResolver()
        let repository = try resolver.configuredRepository(for: makeIssue(), config: config)

        XCTAssertThrowsError(
            try resolver.resolve(repository: repository, labels: ["agent:run", "enhancement"], agentOverride: nil, config: config)
        ) { error in
            XCTAssertEqual(error as? IssueRoutingError, .noMatchingRoute("acme/widgets"))
        }
    }

    func testConfiguredRepositoryMustExistAndBeEnabled() throws {
        let fixture = try ConfigFixture()
        let config = try fixture.snapshot()
        let resolver = RouteResolver()

        XCTAssertThrowsError(
            try resolver.configuredRepository(
                for: IssueReference.parse("https://github.com/acme/other/issues/1"),
                config: config
            )
        ) { error in
            XCTAssertEqual(error as? IssueRoutingError, .repositoryNotConfigured("acme/other"))
        }
    }
}
