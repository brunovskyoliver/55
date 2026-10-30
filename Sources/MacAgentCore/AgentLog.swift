#if os(macOS)
import Foundation
import os

// MARK: - Log entry

public struct AgentLogEntry: Identifiable, Sendable {
    public enum Category: String, Sendable {
        case pairing   = "pairing"
        case discovery = "discovery"
        case focus     = "focus"
        case http      = "http"
        case general   = "general"
    }

    public var id: String
    public var category: Category
    public var message: String
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        category: Category,
        message: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - Log store

/// In-memory ring buffer of log entries. All mutations on main thread.
/// Marked @unchecked Sendable so it can be captured in @Sendable closures
/// crossing concurrency boundaries (mirrors AdapterDebugState pattern).
public final class AgentLogStore: ObservableObject, @unchecked Sendable {
    public static let shared = AgentLogStore()

    @Published public private(set) var entries: [AgentLogEntry] = []

    private let maxEntries = 500
    private let lock = NSLock()

    public init() {}

    public func append(_ entry: AgentLogEntry) {
        // Route through os.Logger for system log visibility.
        osLogger(for: entry.category).log("\(entry.message, privacy: .public)")

        // Update published array on main actor.
        if Thread.isMainThread {
            addEntry(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.addEntry(entry)
            }
        }
    }

    public func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    // MARK: - Convenience

    public func log(_ message: String, category: AgentLogEntry.Category = .general) {
        append(AgentLogEntry(category: category, message: message))
    }

    // MARK: - Private

    private func addEntry(_ entry: AgentLogEntry) {
        var all = entries
        all.append(entry)
        if all.count > maxEntries {
            all.removeFirst(all.count - maxEntries)
        }
        entries = all
    }

    private func osLogger(for category: AgentLogEntry.Category) -> Logger {
        Logger(subsystem: "com.agentcontrol.mac", category: category.rawValue)
    }
}

// MARK: - Global convenience

/// Log a message to the shared store.
public func agentLog(_ message: String, category: AgentLogEntry.Category = .general) {
    AgentLogStore.shared.log(message, category: category)
}
#endif
