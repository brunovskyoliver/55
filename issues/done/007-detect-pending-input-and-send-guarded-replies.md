# Detect Pending Input and send guarded replies

GitHub: https://github.com/brunovskyoliver/55/issues/7

## Parent

#1

## What to build

Detect Pending Input for the active Claude Code Wrapped Session and allow the Owner Device to submit replies only through a Structured Action. Hook-derived Pending Input should be treated as authoritative. Heuristic-only Pending Input should be represented as Uncertain Pending Input and require extra confirmation before sending.

## Acceptance criteria

- [ ] The Agent Adapter accepts Claude Code hook signals and tmux heuristic signals for Pending Input.
- [ ] The Control API exposes whether input is unavailable, hook-confirmed, or uncertain.
- [ ] The iPhone enables reply only when Pending Input exists and requires extra confirmation for Uncertain Pending Input.
- [ ] Submitted replies are sent to the Wrapped Session and recorded in the Session Event Log.
- [ ] Tests cover hook-confirmed reply, heuristic-confirmed reply, heuristic cancellation, no-pending-input rejection, and false-positive heuristic handling.

## Blocked by

- #6
