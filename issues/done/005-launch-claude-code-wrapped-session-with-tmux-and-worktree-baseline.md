# Launch a Claude Code Wrapped Session with tmux and Worktree Baseline

GitHub: https://github.com/brunovskyoliver/55/issues/5

## Parent

#1

## What to build

Start one Claude Code Wrapped Session for the active Planning Artifact through a tmux Launcher. Before launch, capture the Configured Repository Worktree Baseline. After launch, expose the session identity, tmux attachment information, baseline summary, and basic running state to both the Mac menu bar app and iPhone.

## Acceptance criteria

- [ ] The Mac Agent enforces one Configured Repository and one active Agent Session at a time.
- [ ] Starting a Wrapped Session captures the Worktree Baseline before Claude Code launches.
- [ ] Claude Code is launched through tmux in a way that preserves local terminal attachment.
- [ ] Dirty worktrees are allowed but surfaced clearly in session state.
- [ ] Tests cover clean baseline, dirty baseline, active-session conflict, launch failure, and successful state returned to the iPhone.

## Blocked by

- #4
