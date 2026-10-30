import Foundation

/// Writes ephemeral per-session hook files (shell shim + Claude `--settings` JSON) so every
/// Claude Code hook event is fire-and-forget POSTed to the AgentEventServer.
///
/// Design constraints:
/// - The hook shim **always exits 0** and **emits nothing to stdout** — a non-zero exit or
///   stdout output from a PreToolUse hook can accidentally block or deny a tool use.
/// - The POST is **backgrounded** (`&`) with a hard `--max-time 1` so a slow or unreachable
///   Mac Agent never stalls Claude Code (hooks run synchronously up to their timeout).
/// - Files live in NSTemporaryDirectory(), named by wrappedSessionID, and are removed on stop.
public struct ClaudeCodeHookTransport {
    // MARK: - Token

    /// Generate a random per-session bearer token (no special chars — safe for shell embedding).
    public static func generateToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") +
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - File writing

    /// Write the hook shim script and Claude settings JSON for a Wrapped Session.
    /// Returns the URL of the settings file to pass to `claude --settings`.
    public static func writeHookFiles(
        wrappedSessionID: String,
        token: String,
        port: UInt16,
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) throws -> URL {
        let scriptURL = scriptFileURL(wrappedSessionID: wrappedSessionID, directory: directory)
        let settingsURL = settingsFileURL(wrappedSessionID: wrappedSessionID, directory: directory)

        // 1. Write the shell shim
        let script = hookShimScript(wrappedSessionID: wrappedSessionID, token: token, port: port)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        // 2. Write the Claude settings JSON
        let settings = claudeSettingsJSON(scriptPath: scriptURL.path)
        try settings.write(to: settingsURL, atomically: true, encoding: .utf8)

        return settingsURL
    }

    /// Remove the ephemeral hook files for a session (call on session end or error).
    public static func removeHookFiles(
        wrappedSessionID: String,
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) {
        for url in [
            scriptFileURL(wrappedSessionID: wrappedSessionID, directory: directory),
            settingsFileURL(wrappedSessionID: wrappedSessionID, directory: directory),
        ] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - File URLs

    public static func scriptFileURL(wrappedSessionID: String, directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> URL {
        directory.appendingPathComponent("agent-hook-\(wrappedSessionID).sh")
    }

    public static func settingsFileURL(wrappedSessionID: String, directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> URL {
        directory.appendingPathComponent("agent-settings-\(wrappedSessionID).json")
    }

    // MARK: - Content generation

    /// Shell script that reads stdin and fire-and-forgets a POST to the event server.
    /// Never writes to stdout; always exits 0.
    static func hookShimScript(wrappedSessionID: String, token: String, port: UInt16) -> String {
        // Single-quote the token (no special chars possible given generateToken() implementation).
        return """
        #!/bin/bash
        # Mac Agent hook shim — fire-and-forget to AgentEventServer.
        # IMPORTANT: must always exit 0 and produce no stdout (a PreToolUse hook that
        # prints JSON or exits non-zero can accidentally block or deny a tool use).
        INPUT=$(cat)
        curl --silent --output /dev/null --max-time 1 \\
          -X POST \\
          -H 'Content-Type: application/json' \\
          -H 'Authorization: Bearer \(token)' \\
          -H 'X-Wrapped-Session-ID: \(wrappedSessionID)' \\
          'http://127.0.0.1:\(port)\(AgentEventServer.eventsPath)' \\
          --data-binary "$INPUT" 2>/dev/null &
        exit 0
        """
    }

    /// Claude Code `--settings` JSON that registers the hook shim for every event.
    static func claudeSettingsJSON(scriptPath: String) -> String {
        // Events whose hooks we want. PreCompact omitted — it's low value and high noise.
        let events = [
            "PreToolUse",
            "PostToolUse",
            "UserPromptSubmit",
            "Notification",
            "Stop",
            "SubagentStop",
            "SessionStart",
            "SessionEnd",
        ]

        // Escape script path for JSON string (backslash and double-quote)
        let escapedPath = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let hookEntry = """
        {"type": "command", "command": "\(escapedPath)", "timeout": 5}
        """

        let eventLines = events.map { event in
            """
                "\(event)": [{"matcher": ".*", "hooks": [\(hookEntry)]}]
            """
        }.joined(separator: ",\n")

        return """
        {
          "hooks": {
        \(eventLines)
          }
        }
        """
    }
}
