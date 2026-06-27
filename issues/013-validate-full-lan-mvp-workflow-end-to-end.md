# Validate the full LAN MVP workflow end to end

GitHub: https://github.com/brunovskyoliver/55/issues/13

## Parent

#1

## What to build

Validate the complete LAN MVP workflow end to end: pair the Owner Device, attach an Existing Planning Artifact, launch a Claude Code Wrapped Session, observe state, reply to Pending Input, approve or deny a request, review files, approve a Draft Comment, Guarded Stop the session, and verify the Audit Timeline.

## Acceptance criteria

- [ ] A documented local demo flow exercises pairing, Planning Artifact attachment, Wrapped Session launch, Foreground Sync, Structured Actions, File Review, Draft Comment posting, Guarded Stop, and Audit Timeline.
- [ ] End-to-end verification uses the real app surfaces where practical and a fake or sandboxed Agent Adapter where real Claude Code automation would be brittle.
- [ ] The workflow confirms the iPhone cannot send arbitrary terminal input, commit, push, merge, or create PRs.
- [ ] The workflow confirms unpaired devices cannot access the Control API.
- [ ] Any remaining MVP limitations or Claude Code signal-quality findings are documented on the parent Planning Artifact.

## Blocked by

- #3
- #4
- #5
- #6
- #7
- #8
- #9
- #10
- #11
- #12
