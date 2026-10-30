import MacAgentCore
import XCTest

// MARK: - Shared test fakes

final class FakeProcessCommandExecutor: ProcessCommandExecuting, @unchecked Sendable {
    enum Result {
        case success(String)
        case failure(ProcessCommandFailure)
    }

    struct ExecutedCommand: Equatable {
        var executable: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private let results: [String: Result]
    private var commands: [ExecutedCommand] = []

    init(results: [String: Result]) {
        self.results = results
    }

    var executedCommands: [ExecutedCommand] {
        lock.withLock { commands }
    }

    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        lock.withLock {
            commands.append(ExecutedCommand(executable: executable, arguments: arguments))
        }
        let key = ([executable] + arguments).joined(separator: " ")
        switch results[key] ?? results[executable] {
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

struct FakeGhosttyRunningProbe: GhosttyRunningProbing {
    var isRunning: Bool

    func isGhosttyRunning() -> Bool {
        isRunning
    }
}
