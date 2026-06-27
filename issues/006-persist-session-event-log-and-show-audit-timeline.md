# Persist Session Event Log and show Audit Timeline

GitHub: https://github.com/brunovskyoliver/55/issues/6

## Parent

#1

## What to build

Persist structured session activity in a SQLite Session Store and expose a compact Audit Timeline on the iPhone. This slice should record lifecycle changes and Structured Actions from the current MVP path, then make those events queryable by Planning Artifact and Agent Session.

## Acceptance criteria

- [ ] The Mac Agent appends Session Event Log entries for session lifecycle and Structured Action attempts/results.
- [ ] Session Store data is queryable by Planning Artifact, Agent Session, event type, and time order.
- [ ] The iPhone shows a compact Audit Timeline for the active Planning Artifact.
- [ ] Secret Material is not stored in the Session Store.
- [ ] Tests cover event append, ordered timeline query, filtering, persistence across restart, and secret exclusion.

## Blocked by

- #5
