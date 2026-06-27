import AgentShared
import Foundation

public protocol FileReviewBuilding: Sendable {
    func buildFileReview(repositoryURL: URL, activeSession: AttachedSession?) -> FileReviewState
}

public struct GitFileReviewBuilder: FileReviewBuilding {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func buildFileReview(repositoryURL: URL, activeSession: AttachedSession?) -> FileReviewState {
        guard let baseline = activeSession?.session.worktreeBaseline else {
            return FileReviewState(
                status: .unavailable,
                summary: "File Review is unavailable until a Wrapped Session starts.",
                changedFileCount: 0
            )
        }

        do {
            let statusText = try gitTextPreservingWhitespace(arguments: ["-C", repositoryURL.path, "status", "--porcelain"])
            let currentChanges = parsePorcelainStatus(statusText)
            guard !currentChanges.isEmpty else {
                return FileReviewState(
                    status: .noChanges,
                    summary: "No worktree changes are present relative to the Worktree Baseline.",
                    changedFileCount: 0
                )
            }

            let baselineIDs = Set(baseline.changedFiles.flatMap { [$0.path, $0.previousPath].compactMap(\.self) })
            let files = currentChanges.map { change in
                fileReviewFile(for: change, baselineIDs: baselineIDs, repositoryURL: repositoryURL)
            }
            let preExistingCount = files.filter { $0.ownership == .preExistingDirtyWorktree }.count
            let agentSessionCount = files.filter { $0.ownership == .agentSession }.count

            return FileReviewState(
                status: .changesAvailable,
                summary: "\(files.count) changed file\(files.count == 1 ? "" : "s"): \(preExistingCount) pre-existing, \(agentSessionCount) Agent Session.",
                changedFileCount: files.count,
                preExistingChangeCount: preExistingCount,
                agentSessionChangeCount: agentSessionCount,
                files: files.sorted(by: sortFiles)
            )
        } catch let error as ProcessCommandFailure {
            return failedFileReview(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return failedFileReview(String(describing: error))
        }
    }

    private func fileReviewFile(
        for change: PorcelainFileChange,
        baselineIDs: Set<String>,
        repositoryURL: URL
    ) -> FileReviewFile {
        let ownership: FileReviewFile.Ownership = baselineIDs.contains(change.path) || change.previousPath.map(baselineIDs.contains) == true
            ? .preExistingDirtyWorktree
            : .agentSession
        let kind = changeKind(for: change.status)
        let counts = (try? numstat(repositoryURL: repositoryURL, path: change.path)) ?? (0, 0)
        let riskSignals = riskSignals(
            path: change.path,
            ownership: ownership,
            changeKind: kind,
            additions: counts.0,
            deletions: counts.1
        )

        return FileReviewFile(
            path: change.path,
            previousPath: change.previousPath,
            ownership: ownership,
            changeKind: kind,
            additions: counts.0,
            deletions: counts.1,
            summary: fileSummary(kind: kind, additions: counts.0, deletions: counts.1, previousPath: change.previousPath),
            riskSignals: riskSignals,
            selectedHunks: selectedHunks(repositoryURL: repositoryURL, path: change.path, changeKind: kind)
        )
    }

    private func parsePorcelainStatus(_ rawStatus: String) -> [PorcelainFileChange] {
        rawStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let rawLine = String(line)
                guard rawLine.count >= 4 else {
                    return nil
                }

                let status = String(rawLine.prefix(2))
                let pathText = String(rawLine.dropFirst(3))
                if let range = pathText.range(of: " -> ") {
                    return PorcelainFileChange(
                        path: String(pathText[range.upperBound...]),
                        previousPath: String(pathText[..<range.lowerBound]),
                        status: status.trimmingCharacters(in: .whitespaces)
                    )
                }

                return PorcelainFileChange(path: pathText, status: status.trimmingCharacters(in: .whitespaces))
            }
    }

    private func changeKind(for status: String) -> FileReviewFile.ChangeKind {
        if status == "??" {
            return .untracked
        }
        if status.contains("R") {
            return .renamed
        }
        if status.contains("C") {
            return .copied
        }
        if status.contains("D") {
            return .deleted
        }
        if status.contains("A") {
            return .added
        }
        if status.contains("M") {
            return .modified
        }
        if status.contains("T") {
            return .typeChanged
        }
        return .unknown
    }

    private func numstat(repositoryURL: URL, path: String) throws -> (Int, Int) {
        let text = try gitText(arguments: ["-C", repositoryURL.path, "diff", "--numstat", "HEAD", "--", path])
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return (0, 0)
        }

        let parts = firstLine.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return (0, 0)
        }

        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    private func selectedHunks(
        repositoryURL: URL,
        path: String,
        changeKind: FileReviewFile.ChangeKind
    ) -> [FileReviewHunk] {
        guard changeKind != .untracked else {
            return []
        }

        guard let diff = try? gitTextPreservingWhitespace(arguments: ["-C", repositoryURL.path, "diff", "--unified=3", "HEAD", "--", path]) else {
            return []
        }

        var hunks: [FileReviewHunk] = []
        var currentHeader: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentHeader, hunks.count < 2 else {
                return
            }
            hunks.append(
                FileReviewHunk(
                    id: "\(path):\(hunks.count)",
                    header: currentHeader,
                    lines: Array(currentLines.prefix(12))
                )
            )
            currentLines = []
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@") {
                flush()
                currentHeader = line
                currentLines = []
            } else if currentHeader != nil, !line.hasPrefix("diff --git"), !line.hasPrefix("index ") {
                currentLines.append(line)
            }
        }
        flush()

        return hunks
    }

    private func riskSignals(
        path: String,
        ownership: FileReviewFile.Ownership,
        changeKind: FileReviewFile.ChangeKind,
        additions: Int,
        deletions: Int
    ) -> [String] {
        var signals: [String] = []
        if ownership == .preExistingDirtyWorktree {
            signals.append("Pre-existing dirty worktree")
        }
        if changeKind == .deleted {
            signals.append("Deleted file")
        }
        if changeKind == .renamed {
            signals.append("Renamed file")
        }
        if additions + deletions >= 100 {
            signals.append("Large change")
        }
        if path == "Package.swift" || path.hasPrefix(".github/") {
            signals.append("Project configuration")
        }
        return signals
    }

    private func fileSummary(
        kind: FileReviewFile.ChangeKind,
        additions: Int,
        deletions: Int,
        previousPath: String?
    ) -> String {
        let movement = previousPath.map { " from \($0)" } ?? ""
        return "\(kind.displayName)\(movement), +\(additions)/-\(deletions)."
    }

    private func failedFileReview(_ detail: String) -> FileReviewState {
        FileReviewState(
            status: .failed,
            summary: detail.isEmpty ? "File Review could not be computed." : "File Review could not be computed: \(detail)",
            changedFileCount: 0
        )
    }

    private func sortFiles(_ lhs: FileReviewFile, _ rhs: FileReviewFile) -> Bool {
        if lhs.ownership != rhs.ownership {
            return lhs.ownership == .preExistingDirtyWorktree
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func gitText(arguments: [String]) throws -> String {
        try gitTextPreservingWhitespace(arguments: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitTextPreservingWhitespace(arguments: [String]) throws -> String {
        let result = try executor.run(executable: "git", arguments: arguments)
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

private struct PorcelainFileChange: Equatable {
    var path: String
    var previousPath: String?
    var status: String
}

private extension FileReviewFile.ChangeKind {
    var displayName: String {
        switch self {
        case .added:
            return "Added"
        case .modified:
            return "Modified"
        case .deleted:
            return "Deleted"
        case .renamed:
            return "Renamed"
        case .untracked:
            return "Untracked"
        case .copied:
            return "Copied"
        case .typeChanged:
            return "Type changed"
        case .unknown:
            return "Changed"
        }
    }
}
