# Build File Review from Worktree Baseline and session changes

GitHub: https://github.com/brunovskyoliver/55/issues/9

## Parent

#1

## What to build

Build File Review for the active Planning Artifact by comparing the current worktree to the Worktree Baseline and separating pre-existing dirty changes from Agent Session changes. The iPhone should show a file-by-file review with summary, change size, risk signals, and selected hunks without requiring full raw diff browsing.

## Acceptance criteria

- [ ] The Mac Agent computes File Review data for the Configured Repository relative to the Worktree Baseline.
- [ ] Pre-existing dirty worktree changes are clearly separated from Agent Session changes.
- [ ] The iPhone renders changed files with summary, change size, risk signals, and selected hunks.
- [ ] Commit and push approval remain unavailable in the MVP UI.
- [ ] Tests cover clean baseline changes, dirty baseline separation, deleted files, renamed files where detectable, and no-change state.

## Blocked by

- #6
