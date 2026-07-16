import Darwin
import Foundation
import MakeAnIssueWorkerCore

@main
struct MakeAnIssueWorkerCLI {
    static func main() {
        exit(execute(arguments: Array(CommandLine.arguments.dropFirst())))
    }

    private static func execute(arguments: [String]) -> Int32 {
        do {
            let parsed = try Arguments(arguments)
            switch parsed.command {
            case .version:
                print("make-an-issue-worker \(WorkerVersion.current)")
                return 0
            case .help:
                print(Arguments.usage)
                return 0
            case .doctor:
                let report = Doctor().run(configURL: parsed.configURL) { check in
                    print(DoctorReport.humanReadable(check))
                    fflush(stdout)
                }
                return report.hasBlockingIssues ? 1 : 0
            case .run(let issueURL, let agent):
                let config = try ConfigLoader().load(from: parsed.configURL)
                let ledger = try RunLedger(stateRoot: config.worker.stateRoot)
                let service = RunService(config: config, ledger: ledger)
                try service.reconcileStartup()
                let outcome = try service.run(
                    issueURL: issueURL,
                    agentOverride: agent
                )
                print(outcome.message)
                return outcome.exitCode
            }
        } catch let error as ArgumentError {
            writeError("error: \(error.description)\n\n\(Arguments.usage)")
            return 2
        } catch {
            writeError("error: \(error)")
            return 1
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum Command {
    case doctor
    case run(issueURL: String, agent: String?)
    case version
    case help
}

private struct Arguments {
    static let usage = """
    Usage:
      make-an-issue-worker [--config <path>] doctor
      make-an-issue-worker [--config <path>] run --issue <https://github.com/owner/repo/issues/N> [--agent <id>]
      make-an-issue-worker --version

    The default config is ~/Library/Application Support/MakeAnIssue/agents.toml.
    The run command opens a draft pull request only after isolated editing, inspection, and validation.
    """

    let configURL: URL
    let command: Command

    init(_ original: [String]) throws {
        var arguments = original
        var configURL = ConfigLoader.defaultConfigURL()
        if let configIndex = arguments.firstIndex(of: "--config") {
            let valueIndex = arguments.index(after: configIndex)
            guard valueIndex < arguments.endIndex else { throw ArgumentError("--config requires a path") }
            let value = arguments[valueIndex]
            guard value.hasPrefix("/") else { throw ArgumentError("--config path must be absolute") }
            configURL = URL(fileURLWithPath: value)
            arguments.remove(at: valueIndex)
            arguments.remove(at: configIndex)
        }
        self.configURL = configURL

        guard let verb = arguments.first else { throw ArgumentError("a subcommand is required") }
        switch verb {
        case "doctor":
            guard arguments.count == 1 else { throw ArgumentError("doctor accepts only --config") }
            command = .doctor
        case "run":
            var remaining = Array(arguments.dropFirst())
            let issue = try Self.takeOption("--issue", from: &remaining, required: true)
            let agent = try Self.takeOption("--agent", from: &remaining, required: false)
            guard remaining.isEmpty else { throw ArgumentError("unknown run argument \(remaining[0])") }
            command = .run(issueURL: issue!, agent: agent)
        case "--version", "version":
            guard arguments.count == 1 else { throw ArgumentError("version accepts no arguments") }
            command = .version
        case "--help", "help", "-h":
            command = .help
        default:
            throw ArgumentError("unknown subcommand \(verb)")
        }
    }

    private static func takeOption(
        _ option: String,
        from arguments: inout [String],
        required: Bool
    ) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else {
            if required { throw ArgumentError("\(option) is required") }
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { throw ArgumentError("\(option) requires a value") }
        let value = arguments[valueIndex]
        arguments.remove(at: valueIndex)
        arguments.remove(at: index)
        return value
    }
}

private struct ArgumentError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
