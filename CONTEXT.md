# Agent Session Control

This context describes a companion system for monitoring and controlling local coding-agent sessions from an iPhone while the Mac remains the trusted execution host.

## Language

**Agent Session**:
A running Claude Code or OpenAI Codex interaction hosted on the Mac and exposed to the iPhone for monitoring and control; the MVP allows one active Agent Session at a time.
_Avoid_: Terminal session, job

**Wrapped Session**:
An Agent Session started through an app-managed launcher so identity, Planning Artifact attachment, logs, prompts, diffs, and approval hooks are available from the beginning.
_Avoid_: Discovered terminal, attached process

**tmux Launcher**:
The Mac Agent's controlled launcher for starting a Wrapped Session inside tmux so Claude Code remains usable from a normal Mac terminal while output capture and typed input are stable.
_Avoid_: Embedded terminal, unmanaged tmux

**Structured Action**:
A typed, authorized command that the iPhone can send to an Agent Session, such as replying when user input is pending, approving a request, denying a request, answering a clarification, or stopping the session.
_Avoid_: Shell command, remote terminal input

**Pending Input**:
An Agent Session state where Claude Code is waiting for user text or a user decision, allowing the Owner Device to submit a reply Structured Action.
_Avoid_: Open prompt, terminal input

**Pending Input Signal**:
Evidence that an Agent Session is in Pending Input, preferably from Claude Code hooks and secondarily from tmux output heuristics.
_Avoid_: Prompt guess, terminal pattern

**Uncertain Pending Input**:
Pending Input inferred only from heuristics, requiring extra confirmation before the Owner Device can submit a reply.
_Avoid_: Normal reply state, guessed prompt

**Planning Artifact**:
A GitHub Issue or Pull Request used as the system of record for planning phases, proposed code changes, and implementation progress; Issues support planning and PRs support review of proposed code.
_Avoid_: Notes, task, plan thread

**Planning-Centered View**:
The iPhone app navigation model where Planning Artifacts are the primary objects and attached Agent Sessions appear inside them.
_Avoid_: Session dashboard, process monitor

**Attached Session**:
An Agent Session associated with one Planning Artifact so its prompts, proposed changes, and user decisions can be discussed in GitHub.
_Avoid_: Synced task, copied plan

**Existing Planning Artifact**:
A GitHub Issue or Pull Request that already exists before an Agent Session is attached in the MVP.
_Avoid_: App-created issue, generated PR

**Draft Comment**:
A proposed general GitHub comment prepared by the Mac agent for a Planning Artifact and posted only after the user approves it.
_Avoid_: Auto-comment, agent note

**Observable Summary**:
A summary based only on user-visible prompts, agent messages, tool events, command outcomes, diffs, and requested decisions.
_Avoid_: Reasoning summary, thought trace

**Code Decision**:
A user-owned choice about what code should be written, changed, committed, pushed, reviewed, or merged.
_Avoid_: Agent decision, implementation choice

**External Action**:
A Structured Action that changes shared project state outside the local working copy, such as posting to GitHub, committing, pushing, opening or updating a Pull Request, merging, or approving a requested operation.
_Avoid_: Background sync, automatic publish

**Attention Event**:
A meaningful Agent Session state change that justifies notifying the user, such as needing approval, needing clarification, completing, failing, or hitting a high-priority warning.
_Avoid_: Log update, status tick

**Foreground Sync**:
The MVP behavior where the iPhone refreshes Agent Session state only while the app is open, before push notifications are added.
_Avoid_: Background polling, always-on connection

**Local Connection**:
An encrypted connection between the iPhone and Mac agent over the same local network, discovered locally and authenticated through device pairing.
_Avoid_: LAN server, local-only trust

**Relay-Ready Protocol**:
A message protocol that works over a Local Connection first while preserving device identity, authentication, message envelopes, and authorization boundaries needed for a future cloud relay; the MVP does not include relay infrastructure.
_Avoid_: LAN protocol, relay tunnel

**Control API**:
The authenticated HTTP request/response API used by the iPhone to read Planning Artifacts, read Agent Session state, and submit Structured Actions.
_Avoid_: WebSocket stream, terminal socket

**Paired TLS Channel**:
A TLS-protected Control API connection where the Mac Agent and Owner Device authenticate the paired device identity rather than trusting the local network.
_Avoid_: Plain LAN HTTP, unauthenticated local API

**Owner Device**:
The single paired iPhone authorized to monitor Agent Sessions and send Structured Actions in the MVP.
_Avoid_: Client, phone, user device

**Pairing Invitation**:
A short-lived QR code shown by the Mac Agent and scanned by the iPhone to establish the Owner Device relationship.
_Avoid_: Login code, shared password

**Session Event Log**:
A durable local record on the Mac of Agent Session prompts, lifecycle changes, tool activity, approval requests, Structured Actions, Draft Comments, File Diffs, and outcomes.
_Avoid_: Stream cache, transcript

**Audit Timeline**:
A compact iPhone-visible view of important Session Event Log entries, including approved, denied, posted, replied, and stopped actions.
_Avoid_: Debug log, activity feed

**Session Store**:
The local SQLite database on the Mac that stores Session Event Log entries and queryable session metadata.
_Avoid_: File log, app database

**Secret Material**:
Pairing keys, local API credentials, encryption keys, and other credentials stored outside the Session Store.
_Avoid_: Session metadata, database config

**Raw Transcript**:
The captured text output from an Agent Session, retained locally on the Mac for search, debugging, and on-demand review.
_Avoid_: Synced log, phone history

**Transcript File**:
An append-only local file on the Mac that stores Raw Transcript chunks, referenced by the Session Store.
_Avoid_: Database blob, synced log file

**Transcript Slice**:
A bounded excerpt from a Raw Transcript requested for focused review after the MVP structured event and File Review flow is working.
_Avoid_: Full log sync, live terminal view

**GitHub Action**:
A Structured Action that reads from or writes to GitHub using the Mac's existing GitHub authentication.
_Avoid_: Phone GitHub request, relay GitHub request

**Agent Adapter**:
The Mac-side integration layer for one supported coding agent, responsible for launching Wrapped Sessions and translating native hooks, terminal output, prompts, diffs, and approval signals into Session Event Log entries.
_Avoid_: Plugin, CLI wrapper

**First Agent Adapter**:
The initial Agent Adapter for the MVP, targeting Claude Code before Codex support is added.
_Avoid_: Primary agent, only agent

**Mac Agent**:
The menu bar app component that hosts the background monitoring and control service for Wrapped Sessions in the MVP.
_Avoid_: Daemon, server

**Apple App Codebase**:
The Swift codebase for the iPhone app and MVP Mac Agent.
_Avoid_: Mobile app code, native code

**MVP Control Set**:
The first Structured Actions supported by the iPhone: reply with text, approve or deny a detected Claude Code request, approve posting a Draft Comment to the attached Planning Artifact, and stop a Wrapped Session; it excludes committing or pushing code.
_Avoid_: Full remote control, read-only monitoring

**Guarded Stop**:
A confirmed Structured Action that stops a Wrapped Session by attempting a graceful interrupt before escalating to termination and recording the outcome.
_Avoid_: Kill switch, force quit

**File Review**:
A phone-sized view of proposed code changes organized by file, showing summary, change size, risk signals, and selected hunks before raw diff slices are requested.
_Avoid_: Full patch view, diff dump

**Worktree Baseline**:
The git status captured before a Wrapped Session starts, used to distinguish pre-existing local changes from changes made during the Agent Session.
_Avoid_: Clean checkout, initial diff

**Configured Repository**:
The single local Git repository that the Mac Agent manages for Wrapped Sessions in the MVP.
_Avoid_: Workspace, project list
