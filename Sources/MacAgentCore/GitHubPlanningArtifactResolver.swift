import AgentShared
import Foundation

public protocol PlanningArtifactResolving: Sendable {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact
}

public protocol GitHubCommandExecuting: Sendable {
    func run(arguments: [String]) throws -> GitHubCommandResult
}

public struct GitHubCommandResult: Equatable, Sendable {
    public var stdout: Data
    public var stderr: String

    public init(stdout: Data, stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct GitHubCommandFailure: Error, Equatable, Sendable {
    public var exitCode: Int32
    public var stderr: String

    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

public enum PlanningArtifactResolutionError: Error, Equatable, Sendable {
    case missingReference
    case artifactNotFound(String)
    case ghUnauthenticated(String)
    case invalidGitHubResponse
    case ghFailed(String)

    var apiErrorCode: String {
        switch self {
        case .missingReference:
            return "planning_artifact_reference_required"
        case .artifactNotFound:
            return "planning_artifact_not_found"
        case .ghUnauthenticated:
            return "gh_unauthenticated"
        case .invalidGitHubResponse:
            return "gh_response_invalid"
        case .ghFailed:
            return "gh_resolution_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .missingReference:
            return "Enter a GitHub Issue or Pull Request number or URL."
        case .artifactNotFound(let detail):
            return detail.isEmpty ? "GitHub could not find that planning artifact." : detail
        case .ghUnauthenticated(let detail):
            return detail.isEmpty ? "The Mac is not authenticated with gh. Run gh auth login on the Mac." : detail
        case .invalidGitHubResponse:
            return "gh returned an unexpected response while resolving the planning artifact."
        case .ghFailed(let detail):
            return detail.isEmpty ? "gh could not resolve the planning artifact." : detail
        }
    }
}

public struct GitHubPlanningArtifactResolver: PlanningArtifactResolving {
    private let executor: any GitHubCommandExecuting
    private let decoder: JSONDecoder

    public init(executor: any GitHubCommandExecuting = ProcessGitHubCommandExecutor()) {
        self.executor = executor
        self.decoder = JSONDecoder()
    }

    public func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        let reference = request.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw PlanningArtifactResolutionError.missingReference
        }

        let command = request.kind == .issue ? "issue" : "pr"

        do {
            let result = try executor.run(arguments: [
                command,
                "view",
                reference,
                "--json",
                "number,title,state,url"
            ])
            let payload = try decoder.decode(GitHubPlanningArtifactPayload.self, from: result.stdout)

            return PlanningArtifact(
                id: Self.artifactID(kind: request.kind, number: payload.number),
                kind: request.kind,
                number: payload.number,
                title: payload.title,
                url: payload.url,
                state: payload.state.lowercased()
            )
        } catch let error as GitHubCommandFailure {
            throw mapCommandFailure(error)
        } catch let error as PlanningArtifactResolutionError {
            throw error
        } catch {
            throw PlanningArtifactResolutionError.invalidGitHubResponse
        }
    }

    public static func artifactID(kind: PlanningArtifact.Kind, number: Int) -> String {
        switch kind {
        case .issue:
            return "issue-\(number)"
        case .pullRequest:
            return "pr-\(number)"
        }
    }

    private func mapCommandFailure(_ error: GitHubCommandFailure) -> PlanningArtifactResolutionError {
        let detail = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = detail.lowercased()

        if normalized.contains("authentication")
            || normalized.contains("not logged")
            || normalized.contains("gh auth login")
            || normalized.contains("requires login") {
            return .ghUnauthenticated(detail)
        }

        if normalized.contains("not found")
            || normalized.contains("could not resolve")
            || normalized.contains("no issue")
            || normalized.contains("no pull request") {
            return .artifactNotFound(detail)
        }

        return .ghFailed(detail)
    }
}

public struct ProcessGitHubCommandExecutor: GitHubCommandExecuting {
    public init() {}

    public func run(arguments: [String]) throws -> GitHubCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw GitHubCommandFailure(exitCode: process.terminationStatus, stderr: errorText)
        }

        return GitHubCommandResult(stdout: outputData, stderr: errorText)
    }
}

private struct GitHubPlanningArtifactPayload: Decodable {
    var number: Int
    var title: String
    var state: String
    var url: URL
}
