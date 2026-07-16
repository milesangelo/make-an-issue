import Foundation

public struct IssueReference: Equatable, Sendable {
    public let url: URL
    public let repository: String
    public let issueNumber: Int

    public init(url: URL, repository: String, issueNumber: Int) {
        self.url = url
        self.repository = repository
        self.issueNumber = issueNumber
    }

    public static func parse(_ value: String) throws -> IssueReference {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            throw IssueRoutingError.invalidIssueURL(
                "must be an HTTPS GitHub URL in the form https://github.com/owner/repo/issues/N"
            )
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4,
              parts[2] == "issues",
              let issueNumber = Int(parts[3]),
              issueNumber > 0 else {
            throw IssueRoutingError.invalidIssueURL(
                "must be an HTTPS GitHub URL in the form https://github.com/owner/repo/issues/N"
            )
        }
        let owner = parts[0].lowercased()
        let repo = parts[1].lowercased()
        guard owner.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil,
              repo.range(of: #"^[a-z0-9_.][a-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            throw IssueRoutingError.invalidIssueURL("owner and repository names are invalid")
        }
        let canonical = URL(string: "https://github.com/\(owner)/\(repo)/issues/\(issueNumber)")!
        return IssueReference(url: canonical, repository: "\(owner)/\(repo)", issueNumber: issueNumber)
    }
}

public enum IssueRoutingError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidIssueURL(String)
    case repositoryNotConfigured(String)
    case repositoryDisabled(String)
    case agentNotConfigured(String)
    case routeNotConfigured(String)
    case noMatchingRoute(String)

    public var description: String {
        switch self {
        case .invalidIssueURL(let reason): return "invalid issue URL: \(reason)"
        case .repositoryNotConfigured(let slug): return "repository \(slug) is not configured"
        case .repositoryDisabled(let slug): return "repository \(slug) is disabled"
        case .agentNotConfigured(let id): return "agent \(id) is not configured"
        case .routeNotConfigured(let id): return "route \(id) is not configured"
        case .noMatchingRoute(let slug): return "no configured route matches labels for \(slug)"
        }
    }
}

public struct ResolvedRoute: Equatable, Sendable {
    public let routeID: String
    public let agent: AgentConfig
    public let provider: ProviderConfig
}

public struct RouteResolver: Sendable {
    public init() {}

    public func configuredRepository(
        for issue: IssueReference,
        config: WorkerConfigSnapshot
    ) throws -> RepositoryConfig {
        guard let repository = config.repository(slug: issue.repository) else {
            throw IssueRoutingError.repositoryNotConfigured(issue.repository)
        }
        guard repository.enabled else {
            throw IssueRoutingError.repositoryDisabled(issue.repository)
        }
        return repository
    }

    public func resolve(
        repository: RepositoryConfig,
        labels: Set<String>,
        agentOverride: String?,
        config: WorkerConfigSnapshot
    ) throws -> ResolvedRoute {
        if let agentOverride {
            guard let agent = config.agent(id: agentOverride) else {
                throw IssueRoutingError.agentNotConfigured(agentOverride)
            }
            guard let provider = config.provider(id: agent.provider) else {
                throw IssueRoutingError.agentNotConfigured(agentOverride)
            }
            return ResolvedRoute(routeID: "cli-agent-override", agent: agent, provider: provider)
        }

        let routes = try repository.routeIDs.map { routeID in
            guard let route = config.route(id: routeID) else {
                throw IssueRoutingError.routeNotConfigured(routeID)
            }
            return route
        }.sorted { $0.priority > $1.priority }

        guard let route = routes.first(where: { $0.matches(labels: labels) }) else {
            throw IssueRoutingError.noMatchingRoute(repository.repository)
        }
        guard let agent = config.agent(id: route.agent),
              let provider = config.provider(id: agent.provider) else {
            throw IssueRoutingError.agentNotConfigured(route.agent)
        }
        return ResolvedRoute(routeID: route.id, agent: agent, provider: provider)
    }
}
