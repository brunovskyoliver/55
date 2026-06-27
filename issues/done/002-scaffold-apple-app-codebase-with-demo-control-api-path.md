# Scaffold Apple App Codebase with a demo Control API path

GitHub: https://github.com/brunovskyoliver/55/issues/2

## Parent

#1

## What to build

Create the first demoable Apple App Codebase slice: a Swift iPhone app, a Swift macOS menu bar Mac Agent, shared MVP domain models, and a testable Mac Agent service seam. The iPhone should foreground-sync against a seeded local Control API response and render a basic Planning-Centered View for one placeholder Planning Artifact and session state.

## Acceptance criteria

- [ ] The Mac Agent can run as a menu bar app and expose a local demo Control API response.
- [ ] The iPhone app can request foreground state and render a Planning-Centered View from that response.
- [ ] Shared domain models cover Planning Artifact, Agent Session, Attached Session, Structured Action availability, File Review placeholder, and Audit Timeline placeholder.
- [ ] The Mac Agent service logic is testable without launching the menu bar UI.
- [ ] Tests verify the foreground Control API response is transformed into the iPhone-visible planning/session state.

## Blocked by

None - can start immediately
