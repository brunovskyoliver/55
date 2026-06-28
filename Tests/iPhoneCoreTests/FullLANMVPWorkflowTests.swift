#if os(macOS)
import AgentShared
import iPhoneCore
import MacAgentCore
import XCTest

final class FullLANMVPWorkflowTests: XCTestCase {
    func testFullLANMVPWorkflowUsesPairedControlAPIAndStructuredActionsOnly() throws {
        let store = SQLiteSessionStore.inMemory()
        let secretStore = WorkflowPairingSecretStore()
        let clock = WorkflowPairingClock(now: Date(timeIntervalSince1970: 1_788_000_000))
        let pairingService = MacPairingService(
            secretStore: secretStore,
            tokenGenerator: WorkflowPairingTokenGenerator(tokens: [
                "invitation-id",
                "invitation-secret",
                "owner-device-id",
                "owner-bearer-token"
            ]),
            clock: clock
        )
        let inputSender = WorkflowInputSender()
        let approvalSender = WorkflowApprovalDecisionSender()
        let commentPoster = WorkflowGitHubCommentPoster()
        let stopper = WorkflowStopper()
        let eventIDs = WorkflowIDSequence(prefix: "event")
        let service = DemoControlService(
            resolver: WorkflowPlanningArtifactResolver(),
            configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
            baselineCapturer: WorkflowBaselineCapturer(),
            tmuxLauncher: WorkflowTmuxLauncher(),
            transcriptCapturer: DisabledWrappedSessionTranscriptCapturer(),
            sessionStopper: stopper,
            inputSender: inputSender,
            approvalDecisionSender: approvalSender,
            commentPoster: commentPoster,
            fileReviewBuilder: WorkflowFileReviewBuilder(),
            sessionStore: store,
            sessionIDGenerator: { "session-13" },
            draftIDGenerator: { "draft-13" },
            eventIDGenerator: { eventIDs.next() },
            now: { clock.now }
        )
        let responder = LocalControlAPIResponder(
            provider: service,
            pairingService: pairingService,
            securityPolicy: .pairedTLS(PairedControlAPIAuthorizer(secretStore: secretStore))
        )

        let unpairedResponse = responder.response(
            for: getRequest(path: LocalControlAPIServer.foregroundStatePath),
            channelSecurity: .pairedTLS
        )
        XCTAssertEqual(unpairedResponse.statusCode, 401)

        let credentials = try completePairing(using: responder, pairingService: pairingService)
        let authHeaders = [
            "X-Owner-Device-ID": credentials.deviceID,
            "Authorization": credentials.authorizationHeaderValue
        ]

        let attachResponse: AttachPlanningArtifactResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.planningArtifactAttachmentPath,
                    headers: authHeaders,
                    body: encode(AttachPlanningArtifactRequest(kind: .issue, reference: "13"))
                ),
                channelSecurity: .pairedTLS
            )
        )
        XCTAssertEqual(attachResponse.planningArtifact.id, "issue-13")
        XCTAssertEqual(try PlanningStateMapper().map(attachResponse.foregroundState).activePlanningArtifact.label, "Issue #13")

        let launchResponse: StartWrappedSessionResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.wrappedSessionStartPath,
                    headers: authHeaders,
                    body: encode(StartWrappedSessionRequest())
                ),
                channelSecurity: .pairedTLS
            )
        )
        var iPhoneState = try PlanningStateMapper().map(launchResponse.foregroundState)
        XCTAssertEqual(iPhoneState.attachedSession?.stateText, "Running")
        XCTAssertEqual(iPhoneState.fileReview.changedFileCount, 2)
        XCTAssertEqual(iPhoneState.fileReview.agentSessionChangeCount, 1)
        XCTAssertEqual(iPhoneState.fileReview.preExistingChangeCount, 1)

        let pendingState = try service.acceptPendingInputSignal(.hookConfirmed(prompt: "Should I continue with the demo?"))
        iPhoneState = try PlanningStateMapper().map(pendingState)
        XCTAssertTrue(iPhoneState.structuredActions.first { $0.id == "reply" }?.isAvailable == true)

        let replyResponse: SubmitPendingInputReplyResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.pendingInputReplyPath,
                    headers: authHeaders,
                    body: encode(SubmitPendingInputReplyRequest(reply: "Continue with the LAN MVP validation."))
                ),
                channelSecurity: .pairedTLS
            )
        )
        XCTAssertEqual(inputSender.sentReplies, ["Continue with the LAN MVP validation."])
        XCTAssertEqual(replyResponse.foregroundState.pendingInput.status, .unavailable)

        let approvalState = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(
                requestID: "approval-13",
                title: "Allow shell command?",
                detail: "Claude Code wants to run a non-demo command."
            )
        )
        iPhoneState = try PlanningStateMapper().map(approvalState)
        XCTAssertTrue(iPhoneState.structuredActions.first { $0.id == "deny" }?.requiresConfirmation == true)

        let approvalResponse: SubmitApprovalDecisionResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.approvalDecisionPath,
                    headers: authHeaders,
                    body: encode(SubmitApprovalDecisionRequest(requestID: "approval-13", decision: .deny))
                ),
                channelSecurity: .pairedTLS
            )
        )
        XCTAssertEqual(approvalSender.sentDecisions, [.deny])
        XCTAssertNil(approvalResponse.foregroundState.pendingApprovalRequest)

        let draftResponse: PrepareDraftCommentResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.draftCommentPreparePath,
                    headers: authHeaders,
                    body: encode(PrepareDraftCommentRequest())
                ),
                channelSecurity: .pairedTLS
            )
        )
        XCTAssertEqual(draftResponse.draftComment.id, "draft-13")
        XCTAssertTrue(draftResponse.draftComment.body.contains("Observable Summary"))

        let draftDecisionResponse: SubmitDraftCommentDecisionResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.draftCommentDecisionPath,
                    headers: authHeaders,
                    body: encode(
                        SubmitDraftCommentDecisionRequest(
                            draftID: "draft-13",
                            decision: .approve,
                            approvedBody: "LAN MVP validation completed with fake adapter signals."
                        )
                    )
                ),
                channelSecurity: .pairedTLS
            )
        )
        XCTAssertEqual(commentPoster.postedBodies, ["LAN MVP validation completed with fake adapter signals."])
        XCTAssertEqual(draftDecisionResponse.foregroundState.draftComment.status, .posted)

        let stopResponse: StopWrappedSessionResponse = try decode(
            responder.response(
                for: postRequest(
                    path: LocalControlAPIServer.wrappedSessionStopPath,
                    headers: authHeaders,
                    body: encode(StopWrappedSessionRequest(confirmStop: true))
                ),
                channelSecurity: .pairedTLS
            )
        )
        iPhoneState = try PlanningStateMapper().map(stopResponse.foregroundState)
        XCTAssertEqual(stopper.stoppedSessionIDs, ["session-13"])
        XCTAssertEqual(iPhoneState.attachedSession?.stateText, "Stopped")

        let exposedActionIDs = Set(iPhoneState.structuredActions.map(\.id))
        XCTAssertEqual(exposedActionIDs, ["reply", "approve", "deny", "draft-comment", "guarded-stop"])
        XCTAssertFalse(exposedActionIDs.contains("arbitrary-terminal-input"))
        XCTAssertFalse(exposedActionIDs.contains("commit"))
        XCTAssertFalse(exposedActionIDs.contains("push"))
        XCTAssertFalse(exposedActionIDs.contains("merge"))
        XCTAssertFalse(exposedActionIDs.contains("create-pr"))

        for forbiddenPath in [
            "/v1/terminal/input",
            "/v1/git/commit",
            "/v1/git/push",
            "/v1/git/merge",
            "/v1/pull-request/create"
        ] {
            let response = responder.response(
                for: postRequest(path: forbiddenPath, headers: authHeaders, body: Data("{}".utf8)),
                channelSecurity: .pairedTLS
            )
            XCTAssertEqual(response.statusCode, 404, "Unexpected Control API surface at \(forbiddenPath)")
        }

        let timelineTitles = stopResponse.foregroundState.auditTimeline.entries.map(\.title)
        XCTAssertTrue(timelineTitles.contains("Planning Artifact attached"))
        XCTAssertTrue(timelineTitles.contains("Start Wrapped Session succeeded"))
        XCTAssertTrue(timelineTitles.contains("Pending Input reply sent"))
        XCTAssertTrue(timelineTitles.contains("Denial decision delivered"))
        XCTAssertTrue(timelineTitles.contains("GitHub comment posted"))
        XCTAssertTrue(timelineTitles.contains("Wrapped Session stopped"))
    }

    private func completePairing(
        using responder: LocalControlAPIResponder,
        pairingService: MacPairingService
    ) throws -> PairedControlCredentials {
        let invitation = try pairingService.generateInvitation(
            macAgentName: "Test Mac",
            controlBaseURL: URL(string: "https://127.0.0.1:5577")!,
            timeToLive: 60
        )
        let response = responder.response(
            for: postRequest(
                path: LocalControlAPIServer.pairingCompletionPath,
                body: try encode(
                    PairingCompletionRequest(
                        invitationID: invitation.id,
                        invitationSecret: invitation.invitationSecret,
                        ownerDeviceName: "Owner iPhone",
                        ownerDevicePublicKey: "owner-public-key"
                    )
                )
            ),
            channelSecurity: .pairedTLS
        )

        XCTAssertEqual(response.statusCode, 200)
        let completion: PairingCompletionResponse = try decode(response)
        return completion.credentials
    }
}

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private func decode<T: Decodable>(_ response: LocalControlAPIHTTPResponse) throws -> T {
    XCTAssertEqual(response.statusCode, 200, String(decoding: response.body, as: UTF8.self))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: response.body)
}

private func getRequest(path: String, headers: [String: String] = [:]) -> String {
    request(method: "GET", path: path, headers: headers, body: Data())
}

private func postRequest(path: String, headers: [String: String] = [:], body: Data) -> String {
    request(method: "POST", path: path, headers: headers, body: body)
}

private func request(method: String, path: String, headers: [String: String], body: Data) -> String {
    var lines = [
        "\(method) \(path) HTTP/1.1",
        "Host: 127.0.0.1",
        "Content-Length: \(body.count)"
    ]
    if !body.isEmpty {
        lines.append("Content-Type: application/json")
    }
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
        lines.append("\(name): \(value)")
    }

    return lines.joined(separator: "\r\n") + "\r\n\r\n" + String(decoding: body, as: UTF8.self)
}

private struct WorkflowPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        PlanningArtifact(
            id: "issue-\(request.reference)",
            kind: request.kind,
            number: Int(request.reference) ?? 13,
            title: "Validate the full LAN MVP workflow end to end",
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/\(request.reference)")!,
            state: "open"
        )
    }
}

private struct WorkflowBaselineCapturer: WorktreeBaselineCapturing {
    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary {
        WorktreeBaselineSummary(
            repositoryPath: repositoryURL.path,
            branchName: "main",
            headSHA: "abcdef1234567890",
            isDirty: true,
            changedFileCount: 1,
            changedFiles: [
                WorktreeBaselineFileChange(path: "Sources/ExistingWork.swift", status: "M")
            ],
            summary: "Dirty worktree: 1 changed file on main at abcdef123456.",
            capturedAt: Date(timeIntervalSince1970: 1_788_000_010)
        )
    }
}

private struct WorkflowTmuxLauncher: TmuxLaunching {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        TmuxAttachmentInfo(
            sessionName: "agent-issue-13",
            windowName: "claude",
            attachCommand: "tmux attach-session -t agent-issue-13"
        )
    }
}

private struct WorkflowFileReviewBuilder: FileReviewBuilding {
    func buildFileReview(repositoryURL: URL, activeSession: AttachedSession?) -> FileReviewState {
        guard activeSession != nil else {
            return FileReviewState(
                status: .unavailable,
                summary: "File Review is unavailable until a Wrapped Session starts.",
                changedFileCount: 0
            )
        }

        return FileReviewState(
            status: .changesAvailable,
            summary: "2 changed files: 1 pre-existing, 1 Agent Session.",
            changedFileCount: 2,
            preExistingChangeCount: 1,
            agentSessionChangeCount: 1,
            files: [
                FileReviewFile(
                    path: "Sources/ExistingWork.swift",
                    ownership: .preExistingDirtyWorktree,
                    changeKind: .modified,
                    additions: 2,
                    deletions: 1,
                    summary: "Modified, +2/-1.",
                    riskSignals: ["Pre-existing dirty worktree"],
                    selectedHunks: [
                        FileReviewHunk(
                            id: "Sources/ExistingWork.swift:0",
                            header: "@@ -1 +1 @@",
                            lines: ["-old local work", "+updated local work"]
                        )
                    ]
                ),
                FileReviewFile(
                    path: "docs/demo/full-lan-mvp.md",
                    ownership: .agentSession,
                    changeKind: .added,
                    additions: 48,
                    deletions: 0,
                    summary: "Added, +48/-0.",
                    riskSignals: [],
                    selectedHunks: [
                        FileReviewHunk(
                            id: "docs/demo/full-lan-mvp.md:0",
                            header: "@@ -0,0 +1,3 @@",
                            lines: ["+# LAN MVP Demo", "+", "+Run the local validation flow."]
                        )
                    ]
                )
            ]
        )
    }
}

private final class WorkflowInputSender: WrappedSessionInputSending, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String] = []

    var sentReplies: [String] {
        lock.withLock { replies }
    }

    func sendReply(_ reply: String, to session: AttachedSession) throws {
        lock.withLock {
            replies.append(reply)
        }
    }
}

private final class WorkflowApprovalDecisionSender: ApprovalDecisionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [ApprovalRequestDecision] = []

    var sentDecisions: [ApprovalRequestDecision] {
        lock.withLock { decisions }
    }

    func sendApprovalDecision(_ decision: ApprovalRequestDecision, to session: AttachedSession) throws {
        lock.withLock {
            decisions.append(decision)
        }
    }
}

private final class WorkflowGitHubCommentPoster: GitHubCommentPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    var postedBodies: [String] {
        lock.withLock { bodies }
    }

    func postGeneralComment(_ body: String, to artifact: PlanningArtifact) throws -> GitHubCommentPostResult {
        lock.withLock {
            bodies.append(body)
        }
        return GitHubCommentPostResult(
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/13#issuecomment-validation")!,
            summary: "https://github.com/brunovskyoliver/55/issues/13#issuecomment-validation"
        )
    }
}

private final class WorkflowStopper: WrappedSessionStopping, @unchecked Sendable {
    private let lock = NSLock()
    private var sessionIDs: [String] = []

    var stoppedSessionIDs: [String] {
        lock.withLock { sessionIDs }
    }

    func stopWrappedSession(_ session: AttachedSession) throws -> WrappedSessionStopResult {
        lock.withLock {
            sessionIDs.append(session.session.id)
        }
        return WrappedSessionStopResult(
            method: .gracefulInterrupt,
            summary: "The Wrapped Session stopped after a graceful interrupt."
        )
    }
}

private final class WorkflowPairingSecretStore: PairingSecretMaterialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var materialByDeviceID: [String: PairingSecretMaterial] = [:]

    func store(_ material: PairingSecretMaterial) throws {
        lock.withLock {
            materialByDeviceID[material.deviceID] = material
        }
    }

    func material(forDeviceID deviceID: String) throws -> PairingSecretMaterial? {
        lock.withLock {
            materialByDeviceID[deviceID]
        }
    }

    func delete(deviceID: String) throws {
        _ = lock.withLock {
            materialByDeviceID.removeValue(forKey: deviceID)
        }
    }
}

private struct WorkflowPairingClock: PairingClock {
    var now: Date
}

private struct WorkflowPairingTokenGenerator: PairingTokenGenerating {
    private let tokens: WorkflowTokenQueue

    init(tokens: [String]) {
        self.tokens = WorkflowTokenQueue(tokens)
    }

    func token(byteCount: Int) throws -> String {
        try tokens.next()
    }
}

private final class WorkflowTokenQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() throws -> String {
        try lock.withLock {
            guard !tokens.isEmpty else {
                throw WorkflowTokenQueueError.empty
            }
            return tokens.removeFirst()
        }
    }
}

private enum WorkflowTokenQueueError: Error {
    case empty
}

private final class WorkflowIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var value = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> String {
        lock.withLock {
            value += 1
            return "\(prefix)-\(value)"
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
#endif
