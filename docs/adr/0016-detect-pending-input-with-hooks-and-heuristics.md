# Detect pending input with hooks and heuristics

Pending Input detection uses Claude Code hooks when available and tmux output heuristics as a fallback. Hook-derived states are treated as authoritative, while heuristic states are surfaced as uncertain so the Owner Device does not accidentally submit replies into the wrong session state.
