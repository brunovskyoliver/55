# Handle Claude Code approve and deny Structured Actions

GitHub: https://github.com/brunovskyoliver/55/issues/8

## Parent

#1

## What to build

Surface Claude Code approval requests as Structured Actions on the iPhone and let the Owner Device approve or deny them. The decision should be applied to the Wrapped Session, reflected in session state, and recorded in the Audit Timeline.

## Acceptance criteria

- [ ] The Agent Adapter detects a Claude Code approval request from hook or supported session signal.
- [ ] The iPhone shows the pending approval request with approve and deny actions.
- [ ] Approve and deny decisions are delivered to the Wrapped Session through the Mac Agent.
- [ ] Every approval request and decision is recorded in the Session Event Log.
- [ ] Tests cover approve, deny, duplicate decision rejection, stale request rejection, and audit timeline output.

## Blocked by

- #7
