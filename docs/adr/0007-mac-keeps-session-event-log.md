# Mac keeps a session event log

The Mac agent keeps a durable local session event log instead of relying only on live tmux, PTY, or hook streams. This lets the iPhone reconnect after notifications or restarts, preserves context for user decisions, and keeps detailed session history local unless the user approves publishing a summary or comment to GitHub.
