# Full LAN MVP Demo Flow

This runbook validates the LAN-first Agent Session Control MVP with real app-facing boundaries where practical and fake Agent Adapter signals where Claude Code automation would be brittle.

## Preconditions

- Run on macOS.
- Use the Swift package from the repository root.
- Keep `gh` authenticated on the Mac when doing a real Draft Comment post. For local verification, use the fake GitHub poster in `FullLANMVPWorkflowTests`.
- Use a fake or sandboxed Agent Adapter for Pending Input and approval request signals. A real Claude Code tmux run can be added after signal quality is stable.

## Automated Local Check

Run the full workflow scenario:

```sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/module-cache SWIFTPM_HOME=$PWD/.build/swiftpm-cache swift test --disable-sandbox --filter FullLANMVPWorkflowTests
```

The scenario exercises:

- Pairing through `/v1/pairings/complete`.
- Rejection of an unpaired Control API request.
- Planning Artifact attachment for Issue #13.
- Wrapped Session launch through the Mac service boundary.
- Foreground Sync mapping into the iPhone Planning-Centered View.
- fake Claude Code Pending Input detection and guarded reply.
- fake Claude Code approval request detection and denial.
- File Review with pre-existing dirty worktree changes separated from Agent Session changes.
- Draft Comment preparation and approved posting through a fake GitHub poster.
- Guarded Stop with graceful interrupt result.
- Audit Timeline entries for the user-visible decisions and outcomes.

## Manual Demo Sequence

1. Start the Mac Agent service with paired TLS enabled.
2. Generate a short-lived Pairing Invitation from the Mac Agent and scan it from the Owner Device.
3. Confirm an unpaired request to `/v1/foreground-state` returns `401 paired_identity_required`.
4. Attach Existing Planning Artifact `https://github.com/brunovskyoliver/55/issues/13`.
5. Launch a Claude Code Wrapped Session from the Mac Agent. For repeatable demos, use a fake tmux launcher or a sandboxed Agent Adapter.
6. Foreground the iPhone app and verify the Planning-Centered View shows the active Issue, Attached Session, Worktree Baseline, File Review, Structured Actions, and Audit Timeline.
7. Inject a hook-confirmed Pending Input signal from the fake Adapter and reply from the iPhone.
8. Inject a Claude Code approval request and deny or approve it from the iPhone.
9. Review File Review output and confirm pre-existing dirty worktree files are labeled separately from Agent Session files.
10. Prepare a Draft Comment, edit it if needed, and approve posting. In local tests, the fake GitHub poster records the body instead of calling `gh`.
11. Use Guarded Stop with explicit confirmation and verify the session reaches `stopped`.
12. Review the Audit Timeline for pairing-adjacent setup, attachment, launch, reply, approval decision, Draft Comment posting, and stop entries.

## Negative Checks

- The iPhone Planning-Centered View exposes only `reply`, `approve`, `deny`, `draft-comment`, and `guarded-stop` Structured Actions.
- The MVP does not expose arbitrary terminal input, commit, push, merge, or pull request creation actions.
- Requests to local paths such as `/v1/terminal/input`, `/v1/git/commit`, `/v1/git/push`, `/v1/git/merge`, and `/v1/pull-request/create` must return `404`.
- Unpaired devices must not read foreground state or submit Structured Actions.
- Raw Transcript bytes remain local to Transcript Files and are not part of shared foreground responses.

## MVP Limitations And Signal Findings

- The repeatable end-to-end check uses fake Adapter signals for Pending Input and approval requests because real Claude Code prompt and approval automation is still signal-quality work.
- tmux output heuristics should be validated against real clarification, approval, completion, and failure transcripts before treating heuristic Pending Input as low-friction.
- Draft Comment posting is validated through the Control API contract and a fake poster in tests; a real `gh` post remains an operator-run demo step.
- The LAN MVP still excludes cloud relay, APNs, background iOS polling, commit, push, merge, pull request creation, inline review comments, and arbitrary terminal input.
