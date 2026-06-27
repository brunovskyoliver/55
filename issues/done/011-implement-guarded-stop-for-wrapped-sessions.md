# Implement Guarded Stop for Wrapped Sessions

GitHub: https://github.com/brunovskyoliver/55/issues/11

## Parent

#1

## What to build

Add Guarded Stop for the active Wrapped Session. The iPhone should require confirmation, the Mac Agent should attempt a graceful interrupt first, escalate to termination only if needed, update session state, and record the outcome in the Audit Timeline.

## Acceptance criteria

- [ ] The iPhone exposes stop only for an active Wrapped Session and requires confirmation.
- [ ] The Mac Agent attempts graceful interrupt before termination fallback.
- [ ] Session state reflects stopping, stopped, or failed-to-stop outcomes.
- [ ] Guarded Stop attempts and outcomes are recorded in the Session Event Log.
- [ ] Tests cover confirmed stop, cancelled stop, graceful success, termination fallback, and no-active-session rejection.

## Blocked by

- #6
