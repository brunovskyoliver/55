import AgentShared
import MacAgentCore
import XCTest

final class PlanningArtifactAttachmentTests: XCTestCase {
    func testIssueAttachUsesFakeGitHubExecutorAndStoresActiveArtifact() throws {
        let executor = FakeGitHubExecutor(results: [
            "issue view 4 --json number,title,state,url": .success(issuePayload(number: 4, title: "Attach planning artifact"))
        ])
        let service = DemoControlService(resolver: GitHubPlanningArtifactResolver(executor: executor))

        let response = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "4"))

        XCTAssertEqual(executor.recordedArguments, [["issue", "view", "4", "--json", "number,title,state,url"]])
        XCTAssertEqual(response.planningArtifact.kind, .issue)
        XCTAssertEqual(response.planningArtifact.id, "issue-4")
        XCTAssertEqual(response.planningArtifact.title, "Attach planning artifact")
        XCTAssertEqual(response.foregroundState.activePlanningArtifactID, "issue-4")
        XCTAssertEqual(try service.foregroundState().planningArtifacts.first, response.planningArtifact)
    }

    func testPRAttachUsesFakeGitHubExecutorAndStoresReviewArtifact() throws {
        let executor = FakeGitHubExecutor(results: [
            "pr view 5 --json number,title,state,url": .success(issuePayload(number: 5, title: "Review wrapped session", state: "MERGED", path: "pull/5"))
        ])
        let service = DemoControlService(resolver: GitHubPlanningArtifactResolver(executor: executor))

        let response = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .pullRequest, reference: "5"))

        XCTAssertEqual(executor.recordedArguments, [["pr", "view", "5", "--json", "number,title,state,url"]])
        XCTAssertEqual(response.planningArtifact.kind, .pullRequest)
        XCTAssertEqual(response.planningArtifact.id, "pr-5")
        XCTAssertEqual(response.planningArtifact.state, "merged")
        XCTAssertEqual(response.foregroundState.auditTimeline.entries.first?.detail, "Pull Request #5 is active.")
    }

    func testMissingArtifactReturnsUserVisibleErrorWithoutStoringBrokenAttachment() throws {
        let executor = FakeGitHubExecutor(results: [
            "issue view 404 --json number,title,state,url": .failure(
                GitHubCommandFailure(exitCode: 1, stderr: "GraphQL: Could not resolve to an Issue with the number of 404.")
            )
        ])
        let service = DemoControlService(resolver: GitHubPlanningArtifactResolver(executor: executor))

        XCTAssertThrowsError(
            try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "404"))
        ) { error in
            XCTAssertEqual(
                error as? PlanningArtifactResolutionError,
                .artifactNotFound("GraphQL: Could not resolve to an Issue with the number of 404.")
            )
        }

        let foregroundState = try service.foregroundState()
        XCTAssertEqual(foregroundState.activePlanningArtifactID, "issue-2")
        XCTAssertEqual(foregroundState.planningArtifacts.first?.title, "Scaffold Apple App Codebase with a demo Control API path")
    }

    func testUnauthenticatedGhReturnsUserVisibleErrorWithoutStoringBrokenAttachment() throws {
        let executor = FakeGitHubExecutor(results: [
            "pr view 12 --json number,title,state,url": .failure(
                GitHubCommandFailure(exitCode: 4, stderr: "You are not logged into any GitHub hosts. Run gh auth login.")
            )
        ])
        let service = DemoControlService(resolver: GitHubPlanningArtifactResolver(executor: executor))

        XCTAssertThrowsError(
            try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .pullRequest, reference: "12"))
        ) { error in
            XCTAssertEqual(
                error as? PlanningArtifactResolutionError,
                .ghUnauthenticated("You are not logged into any GitHub hosts. Run gh auth login.")
            )
        }

        XCTAssertEqual(try service.foregroundState().activePlanningArtifactID, "issue-2")
    }

    func testLocalControlAPIResponderReturnsAttachmentErrorResponse() throws {
        let executor = FakeGitHubExecutor(results: [
            "issue view 404 --json number,title,state,url": .failure(
                GitHubCommandFailure(exitCode: 1, stderr: "not found")
            )
        ])
        let service = DemoControlService(resolver: GitHubPlanningArtifactResolver(executor: executor))
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)
        let body = try JSONEncoder().encode(AttachPlanningArtifactRequest(kind: .issue, reference: "404"))

        let response = responder.response(for: postRequest(path: LocalControlAPIServer.planningArtifactAttachmentPath, body: body))

        XCTAssertEqual(response.statusCode, 404)
        let error = try JSONDecoder().decode(ControlAPIErrorResponse.self, from: response.body)
        XCTAssertEqual(error.error, "planning_artifact_not_found")
        XCTAssertEqual(error.message, "not found")
        XCTAssertEqual(try service.foregroundState().activePlanningArtifactID, "issue-2")
    }

    func testLocalControlAPIResponderAttachesResolvedArtifact() throws {
        let executor = FakeGitHubExecutor(results: [
            "issue view 4 --json number,title,state,url": .success(issuePayload(number: 4, title: "Attach planning artifact"))
        ])
        let service = DemoControlService(resolver: GitHubPlanningArtifactResolver(executor: executor))
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)
        let body = try JSONEncoder().encode(AttachPlanningArtifactRequest(kind: .issue, reference: "4"))

        let response = responder.response(for: postRequest(path: LocalControlAPIServer.planningArtifactAttachmentPath, body: body))

        XCTAssertEqual(response.statusCode, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let attachment = try decoder.decode(AttachPlanningArtifactResponse.self, from: response.body)
        XCTAssertEqual(attachment.planningArtifact.id, "issue-4")
        XCTAssertEqual(attachment.foregroundState.activePlanningArtifactID, "issue-4")
    }
}

private final class FakeGitHubExecutor: GitHubCommandExecuting, @unchecked Sendable {
    enum Result {
        case success(Data)
        case failure(GitHubCommandFailure)
    }

    private let lock = NSLock()
    private let results: [String: Result]
    private var arguments: [[String]] = []

    init(results: [String: Result]) {
        self.results = results
    }

    var recordedArguments: [[String]] {
        lock.withLock { arguments }
    }

    func run(arguments: [String]) throws -> GitHubCommandResult {
        let key = arguments.joined(separator: " ")
        return try lock.withLock {
            self.arguments.append(arguments)

            switch results[key] {
            case .success(let data):
                return GitHubCommandResult(stdout: data)
            case .failure(let error):
                throw error
            case nil:
                throw GitHubCommandFailure(exitCode: 1, stderr: "unexpected command: \(key)")
            }
        }
    }
}

private func issuePayload(number: Int, title: String, state: String = "OPEN", path: String? = nil) -> Data {
    let path = path ?? "issues/\(number)"
    return Data(
        """
        {"number":\(number),"title":"\(title)","state":"\(state)","url":"https://github.com/brunovskyoliver/55/\(path)"}
        """.utf8
    )
}

private func postRequest(path: String, body: Data) -> String {
    """
    POST \(path) HTTP/1.1\r
    Host: 127.0.0.1\r
    Content-Type: application/json\r
    Content-Length: \(body.count)\r
    \r
    \(String(decoding: body, as: UTF8.self))
    """
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
