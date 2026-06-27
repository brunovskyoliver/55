import AgentShared
import MacAgentCore
import XCTest

final class FileReviewTests: XCTestCase {
    func testCleanBaselineChangesAreAgentSessionChangesWithSelectedHunks() throws {
        let builder = GitFileReviewBuilder(
            executor: FileReviewProcessExecutor(results: [
                "git -C /repo status --porcelain": .success(" M Sources/App.swift\n"),
                "git -C /repo diff --numstat HEAD -- Sources/App.swift": .success("10\t2\tSources/App.swift\n"),
                "git -C /repo diff --unified=3 HEAD -- Sources/App.swift": .success(
                    """
                    diff --git a/Sources/App.swift b/Sources/App.swift
                    @@ -1,3 +1,4 @@
                     import Foundation
                    -let old = true
                    +let new = true
                    +let other = true
                    """
                )
            ])
        )

        let review = builder.buildFileReview(repositoryURL: repositoryURL, activeSession: attachedSession(baseline: .clean))

        XCTAssertEqual(review.status, .changesAvailable)
        XCTAssertEqual(review.preExistingChangeCount, 0)
        XCTAssertEqual(review.agentSessionChangeCount, 1)
        XCTAssertEqual(review.files.first?.ownership, .agentSession)
        XCTAssertEqual(review.files.first?.changeKind, .modified)
        XCTAssertEqual(review.files.first?.additions, 10)
        XCTAssertEqual(review.files.first?.deletions, 2)
        XCTAssertEqual(review.files.first?.selectedHunks.first?.header, "@@ -1,3 +1,4 @@")
    }

    func testDirtyBaselineIsSeparatedFromAgentSessionChanges() throws {
        let builder = GitFileReviewBuilder(
            executor: FileReviewProcessExecutor(results: [
                "git -C /repo status --porcelain": .success(" M Sources/PreExisting.swift\n M Sources/NewWork.swift\n"),
                "git -C /repo diff --numstat HEAD -- Sources/PreExisting.swift": .success("1\t1\tSources/PreExisting.swift\n"),
                "git -C /repo diff --unified=3 HEAD -- Sources/PreExisting.swift": .success("@@ -1 +1 @@\n-old\n+baseline\n"),
                "git -C /repo diff --numstat HEAD -- Sources/NewWork.swift": .success("8\t0\tSources/NewWork.swift\n"),
                "git -C /repo diff --unified=3 HEAD -- Sources/NewWork.swift": .success("@@ -1 +1 @@\n+new\n")
            ])
        )
        let baseline = WorktreeBaselineSummary.dirty(
            changedFiles: [
                WorktreeBaselineFileChange(path: "Sources/PreExisting.swift", status: "M")
            ]
        )

        let review = builder.buildFileReview(repositoryURL: repositoryURL, activeSession: attachedSession(baseline: baseline))

        XCTAssertEqual(review.changedFileCount, 2)
        XCTAssertEqual(review.preExistingChangeCount, 1)
        XCTAssertEqual(review.agentSessionChangeCount, 1)
        XCTAssertEqual(review.files.map(\.path), ["Sources/PreExisting.swift", "Sources/NewWork.swift"])
        XCTAssertEqual(review.files.first?.ownership, .preExistingDirtyWorktree)
        XCTAssertTrue(review.files.first?.riskSignals.contains("Pre-existing dirty worktree") == true)
    }

    func testDeletedFilesAreSurfacedWithRiskSignal() throws {
        let builder = GitFileReviewBuilder(
            executor: FileReviewProcessExecutor(results: [
                "git -C /repo status --porcelain": .success(" D Sources/Deleted.swift\n"),
                "git -C /repo diff --numstat HEAD -- Sources/Deleted.swift": .success("0\t12\tSources/Deleted.swift\n"),
                "git -C /repo diff --unified=3 HEAD -- Sources/Deleted.swift": .success("@@ -1,2 +0,0 @@\n-old\n-lines\n")
            ])
        )

        let review = builder.buildFileReview(repositoryURL: repositoryURL, activeSession: attachedSession(baseline: .clean))

        XCTAssertEqual(review.files.first?.changeKind, .deleted)
        XCTAssertEqual(review.files.first?.deletions, 12)
        XCTAssertTrue(review.files.first?.riskSignals.contains("Deleted file") == true)
    }

    func testRenamedFilesCarryPreviousPath() throws {
        let builder = GitFileReviewBuilder(
            executor: FileReviewProcessExecutor(results: [
                "git -C /repo status --porcelain": .success("R  Sources/Old.swift -> Sources/New.swift\n"),
                "git -C /repo diff --numstat HEAD -- Sources/New.swift": .success("2\t1\tSources/{Old.swift => New.swift}\n"),
                "git -C /repo diff --unified=3 HEAD -- Sources/New.swift": .success("@@ -1 +1 @@\n-old\n+new\n")
            ])
        )

        let review = builder.buildFileReview(repositoryURL: repositoryURL, activeSession: attachedSession(baseline: .clean))

        XCTAssertEqual(review.files.first?.changeKind, .renamed)
        XCTAssertEqual(review.files.first?.previousPath, "Sources/Old.swift")
        XCTAssertTrue(review.files.first?.riskSignals.contains("Renamed file") == true)
    }

    func testNoChangeState() throws {
        let builder = GitFileReviewBuilder(
            executor: FileReviewProcessExecutor(results: [
                "git -C /repo status --porcelain": .success("")
            ])
        )

        let review = builder.buildFileReview(repositoryURL: repositoryURL, activeSession: attachedSession(baseline: .clean))

        XCTAssertEqual(review.status, .noChanges)
        XCTAssertEqual(review.changedFileCount, 0)
        XCTAssertEqual(review.files, [])
    }
}

private let repositoryURL = URL(fileURLWithPath: "/repo")

private func attachedSession(baseline: WorktreeBaselineSummary) -> AttachedSession {
    AttachedSession(
        planningArtifactID: "issue-9",
        session: AgentSession(
            id: "session-9",
            displayName: "Claude Code Wrapped Session",
            state: .running,
            summary: "Running",
            worktreeBaseline: baseline
        )
    )
}

private extension WorktreeBaselineSummary {
    static let clean = WorktreeBaselineSummary(
        repositoryPath: "/repo",
        branchName: "main",
        headSHA: "abcdef1234567890",
        isDirty: false,
        changedFileCount: 0,
        summary: "Clean worktree on main at abcdef123456.",
        capturedAt: Date(timeIntervalSince1970: 20)
    )

    static func dirty(changedFiles: [WorktreeBaselineFileChange]) -> WorktreeBaselineSummary {
        WorktreeBaselineSummary(
            repositoryPath: "/repo",
            branchName: "main",
            headSHA: "abcdef1234567890",
            isDirty: true,
            changedFileCount: changedFiles.count,
            changedFiles: changedFiles,
            summary: "Dirty worktree: \(changedFiles.count) changed files on main at abcdef123456.",
            capturedAt: Date(timeIntervalSince1970: 20)
        )
    }
}

private final class FileReviewProcessExecutor: ProcessCommandExecuting, @unchecked Sendable {
    enum Result {
        case success(String)
        case failure(ProcessCommandFailure)
    }

    private let results: [String: Result]

    init(results: [String: Result]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        switch results[key] {
        case .success(let text):
            return ProcessCommandResult(stdout: Data(text.utf8))
        case .failure(let error):
            throw error
        case nil:
            throw ProcessCommandFailure(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stderr: "unexpected command: \(key)"
            )
        }
    }
}
