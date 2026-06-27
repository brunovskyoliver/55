# PRD: Agent Session Control MVP

## Problem Statement

When the user is away from the Mac, they cannot reliably monitor or steer long-running Claude Code work without either returning to the Mac or exposing broad remote shell access. They want to stay in charge of Code Decisions while using GitHub Issues and Pull Requests as the durable planning record, reviewing what the agent is doing from an iPhone, and approving only structured, intentional actions.

The Mac must remain the trusted execution host. The iPhone should not hold Claude Code, Codex, or GitHub credentials, and the system must not create an unauthenticated LAN server or a general remote terminal.

## Solution

Build a LAN-first Apple App Codebase with an iPhone app and a macOS menu bar Mac Agent written in Swift.

The Mac Agent manages one Configured Repository and one active Claude Code Wrapped Session at a time. A Wrapped Session starts through a tmux Launcher, attaches to one Existing Planning Artifact, records a Worktree Baseline, captures structured events into a SQLite Session Store, and writes Raw Transcript chunks to local Transcript Files.

The iPhone app uses a Planning-Centered View. Planning Artifacts are the primary objects, and each one can show its Attached Session, current state, File Review, Draft Comments, Audit Timeline, and available Structured Actions.

The MVP uses Foreground Sync over an authenticated HTTP Control API on a Paired TLS Channel. Pairing is established by scanning a short-lived Pairing Invitation QR code from the Mac. There is no cloud relay code in the MVP, but the Relay-Ready Protocol preserves identity, message envelopes, authentication, and authorization boundaries for future relay support.

The first Agent Adapter targets Claude Code. It uses Claude Code hooks where available and tmux output heuristics as fallback to detect Pending Input. Heuristic-only states become Uncertain Pending Input and require extra confirmation before a reply can be sent.

GitHub remains the system of record for Planning Artifacts. GitHub Actions execute on the Mac through the existing authenticated `gh` CLI. The iPhone can approve posting a Draft Comment, but GitHub-visible writing never happens automatically.

## User Stories

1. As the owner, I want to pair my iPhone with the Mac Agent by scanning a QR code, so that setup is fast and does not require typing long secrets.
2. As the owner, I want only my paired Owner Device to access the Mac Agent, so that other devices on the LAN cannot control sessions.
3. As the owner, I want the Local Connection to use TLS, so that the Control API does not trust the local network.
4. As the owner, I want the iPhone app to work while foregrounded on the same LAN, so that the first MVP avoids push notification and relay complexity.
5. As the owner, I want the Mac Agent to manage one Configured Repository, so that the MVP remains focused and predictable.
6. As the owner, I want to attach a Wrapped Session to an Existing Planning Artifact, so that the agent work is anchored in a GitHub Issue or Pull Request.
7. As the owner, I want GitHub Issues to support planning workflows, so that early design and implementation direction happen in the durable GitHub record.
8. As the owner, I want GitHub Pull Requests to support review workflows, so that proposed code can be discussed where review already happens.
9. As the owner, I want Planning Artifacts to be the main objects in the iPhone UI, so that code decisions stay centered on the planning record rather than on running processes.
10. As the owner, I want to start a Claude Code Wrapped Session from the Mac Agent, so that identity, logs, diffs, and hooks are available from the beginning.
11. As the owner, I want Claude Code to run inside tmux, so that the native terminal workflow still works on the Mac.
12. As the owner, I want to attach locally to the tmux session from the Mac, so that the app does not lock me out of normal terminal usage.
13. As the owner, I want the Mac Agent to capture a Worktree Baseline before the session starts, so that pre-existing local changes are distinguishable from agent changes.
14. As the owner, I want dirty worktrees to be allowed with warning state, so that legitimate local work does not block the app.
15. As the owner, I want the Mac Agent to record prompts, lifecycle changes, tool activity, approval requests, Draft Comments, File Reviews, and Structured Actions, so that I can reconstruct what happened.
16. As the owner, I want Raw Transcript chunks retained locally on the Mac, so that detailed debugging and later review are possible without syncing everything to the iPhone.
17. As the owner, I want the iPhone to receive structured event state instead of full log streams, so that the app remains readable and battery-aware.
18. As the owner, I want a compact Audit Timeline on the iPhone, so that I can see what I approved, denied, replied to, posted, or stopped.
19. As the owner, I want to see when Claude Code is in Pending Input, so that I know when a reply is safe to send.
20. As the owner, I want hook-confirmed Pending Input to be treated as authoritative, so that normal replies feel direct and low-friction.
21. As the owner, I want heuristic-only Pending Input to require extra confirmation, so that false positives do not inject text into the wrong terminal state.
22. As the owner, I want to send a reply only when Pending Input exists, so that the iPhone is not a general terminal input device.
23. As the owner, I want to approve or deny detected Claude Code requests, so that important agent decisions remain under my control.
24. As the owner, I want to stop a Wrapped Session from the iPhone with confirmation, so that I can halt runaway or mistaken work while away from the Mac.
25. As the owner, I want Guarded Stop to attempt graceful interrupt before termination, so that session shutdown is controlled and auditable.
26. As the owner, I want the Mac Agent to prepare Draft Comments, so that agent output can be converted into concise GitHub updates.
27. As the owner, I want Draft Comments to require explicit approval before posting, so that GitHub does not fill with automatic agent noise.
28. As the owner, I want Draft Comments to be general GitHub comments in the MVP, so that I can steer planning or review without hunk-position complexity.
29. As the owner, I want summaries to use only Observable Summary inputs, so that the system never depends on hidden model reasoning.
30. As the owner, I want File Review to show changed files, summaries, change size, risk signals, and selected hunks, so that phone review is practical.
31. As the owner, I want raw diff slices to be deferred until later, so that the MVP focuses on decision flow rather than full patch browsing.
32. As the owner, I want the iPhone to show proposed code changes before I comment, so that my planning feedback is grounded in actual diffs.
33. As the owner, I want commit and push approval excluded from MVP, so that the first version cannot accidentally create version history from the phone.
34. As the owner, I want GitHub Actions to run through the Mac's existing `gh` authentication, so that GitHub tokens stay off the iPhone and relay.
35. As the owner, I want the Session Store to be inspectable without exposing secrets, so that debugging does not leak credentials.
36. As the owner, I want Secret Material stored in Keychain, so that pairing and encryption keys are protected by the platform.
37. As the owner, I want the Mac Agent to expose session state through an HTTP Control API, so that the first protocol is simple to secure and test.
38. As the owner, I want the protocol to remain relay-ready, so that remote access can be added later without redesigning identity and authorization.
39. As the owner, I want no cloud relay code in the MVP, so that the first milestone proves the local workflow before adding infrastructure.
40. As the owner, I want no APNs dependency in the first LAN MVP, so that the earliest product can be tested without Apple push setup.
41. As the owner, I want the app to preserve Claude Code functionality, so that the wrapper does not reduce what the native CLI can do.
42. As the owner, I want Codex support to be designed for but not implemented first, so that the first Agent Adapter can be reliable.
43. As the owner, I want the Mac menu bar app to show pairing and session state, so that I can inspect and control the local service.
44. As the owner, I want the iPhone UI to clearly distinguish Issues from PRs, so that planning and review affordances match the GitHub artifact.
45. As the owner, I want every External Action to be recorded, so that I can audit what changed shared project state.
46. As the owner, I want the MVP to make me the owner of Code Decisions, so that the agent suggests and executes locally but does not publish or finalize work without me.

## Implementation Decisions

- Build the Apple App Codebase in Swift for both the iPhone app and the MVP Mac Agent.
- Ship the MVP Mac Agent as a macOS menu bar app with an embedded background service, keeping the core service separable for a future LaunchAgent.
- Support one Owner Device, one Configured Repository, and one active Agent Session at a time in the MVP.
- Use a short-lived QR Pairing Invitation to establish the Owner Device relationship.
- Store Secret Material in Keychain, not in the Session Store.
- Use a Paired TLS Channel for the local Control API. Plain or unauthenticated LAN HTTP is not acceptable.
- Use authenticated HTTP request/response with Foreground Sync for the MVP Control API.
- Do not build cloud relay infrastructure in the MVP. Preserve Relay-Ready Protocol boundaries for future transport.
- Organize the iPhone around Planning Artifacts, not a raw session dashboard.
- Treat GitHub Issues and Pull Requests as Planning Artifacts. Issues support planning; PRs support review.
- Require Planning Artifacts to already exist before attaching a session in the MVP.
- Attach each Agent Session to exactly one Planning Artifact.
- Use GitHub as the system of record for planning. Do not create a separate planning database.
- Execute GitHub Actions on the Mac through the existing authenticated `gh` CLI.
- Require user approval before posting any Draft Comment to GitHub.
- Limit MVP PR feedback to general GitHub comments, not inline review comments.
- Summarize only Observable Summary inputs: visible prompts, agent messages, tool events, command outcomes, diffs, and requested decisions.
- Start with Claude Code as the First Agent Adapter. Design the Agent Adapter boundary so Codex can be added later.
- Start Wrapped Sessions through a tmux Launcher so native Claude Code terminal usage remains available.
- Capture a Worktree Baseline before session start and surface pre-existing local changes in File Review.
- Allow local agent edits in the worktree, but require approval for External Actions.
- Exclude commit and push approval from the MVP Control Set.
- Include reply, approve, deny, approve Draft Comment, and Guarded Stop in the MVP Control Set.
- Allow replies only when Pending Input exists. Do not expose arbitrary terminal input from the iPhone.
- Detect Pending Input through Claude Code hooks where possible and tmux output heuristics as fallback.
- Require extra confirmation for Uncertain Pending Input.
- Store the Session Event Log and queryable metadata in SQLite.
- Store Raw Transcript chunks in append-only Transcript Files referenced by the Session Store.
- Expose structured events, File Review, and Audit Timeline to the iPhone before exposing Transcript Slice access.
- Use File Review as the phone-first code review surface: per-file summary, change size, risk signals, and selected hunks before raw diff slices.
- Record every Structured Action and External Action in the Session Event Log.

## Testing Decisions

- The highest-value test seam is the Control API scenario seam: from a paired Owner Device request through Mac Agent application services to Session Store state and returned iPhone-readable responses.
- Tests should verify external behavior: pairing, authorization, session attachment, event recording, Pending Input state, Structured Action handling, Draft Comment approval, File Review output, and Audit Timeline output.
- Tests should not assert implementation details such as specific tmux command strings, SQLite table layout, or internal Swift type names unless those are public contracts.
- The Mac Agent service layer should be testable without launching the full menu bar UI.
- The Agent Adapter should be testable with fixture inputs representing Claude Code hook events and tmux transcript snippets.
- Pending Input tests should cover hook-confirmed states, heuristic states, false positives, and the extra-confirmation rule.
- GitHub Action tests should use a fake executor for `gh` behavior and verify that posting requires an approved Structured Action.
- Session Store tests should verify append, query by Planning Artifact, query by session, retention metadata, and Secret Material exclusion.
- Transcript File tests should verify append, offset metadata, and bounded slice reads without loading a full transcript.
- File Review tests should use fixture worktree baselines and diffs to verify that pre-existing changes are separated from Agent Session changes.
- Control API authorization tests should verify that unpaired devices, invalid identities, and invalid action tokens cannot read state or submit Structured Actions.
- iPhone UI tests should focus on Planning-Centered View behavior: Planning Artifact list/detail, Attached Session state, pending decisions, Draft Comment approval, File Review, and Audit Timeline.
- End-to-end local MVP testing should run a fake or sandboxed Agent Adapter first, then a real Claude Code Wrapped Session once the adapter boundary is stable.

## Out of Scope

- Cloud relay infrastructure.
- APNs push notifications.
- Background iOS polling or long-running iPhone sockets.
- Multiple Owner Devices.
- Multiple Configured Repositories.
- Multiple active Agent Sessions.
- Codex Agent Adapter implementation.
- App-created GitHub Issues or Pull Requests.
- Inline GitHub review comments on specific diff hunks.
- Commit, push, merge, or PR creation approval from the iPhone.
- Arbitrary terminal input from the iPhone.
- Full raw transcript sync to the iPhone.
- Direct storage of GitHub, Claude Code, or Codex credentials on the iPhone or relay.
- A headless LaunchAgent-only Mac deployment.

## Further Notes

- The first milestone should validate the local workflow: pair, attach an Existing Planning Artifact, launch Claude Code through tmux, detect state, show File Review and Audit Timeline, reply to Pending Input, approve a Draft Comment, and Guarded Stop.
- The second milestone can add APNs and Attention Events once Foreground Sync is reliable.
- The third milestone can add the cloud relay using the already-defined Relay-Ready Protocol boundaries.
- The main experimental unknown is Claude Code signal quality: hooks should be validated against real approval, clarification, completion, and failure flows.
- Another key unknown is how reliably tmux output heuristics identify Pending Input without false positives.
- Battery risk is managed by Foreground Sync in the MVP and a push-driven design later.

## LAN MVP Validation Notes

- Local validation is documented in `docs/demo/full-lan-mvp.md`.
- The automated end-to-end check uses the real Control API responder, pairing service, Session Store, Mac service layer, and iPhone Planning-Centered mapper.
- The automated check uses fake Adapter seams for tmux launch, Pending Input, approval request, GitHub comment posting, and Guarded Stop so the workflow is deterministic without brittle real Claude Code automation.
- The validated MVP Control Set remains limited to reply, approve, deny, Draft Comment approval, and Guarded Stop. Arbitrary terminal input, commit, push, merge, and pull request creation are not exposed by the iPhone surface or Control API.
- Unpaired Control API access is rejected before foreground state or Structured Actions are served.
- Remaining signal-quality work: validate real Claude Code hook coverage for approval, clarification, completion, and failure states; validate tmux heuristic false-positive rates before reducing confirmation friction.
