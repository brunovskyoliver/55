# Attach an Existing Planning Artifact through Mac gh auth

GitHub: https://github.com/brunovskyoliver/55/issues/4

## Parent

#1

## What to build

Let the paired iPhone attach the MVP workflow to an Existing Planning Artifact. The Mac Agent should use the Mac's existing gh authentication to fetch a GitHub Issue or Pull Request, store the active attachment, and return enough metadata for the iPhone Planning-Centered View to distinguish Issues from PRs.

## Acceptance criteria

- [ ] The iPhone can submit an Issue or PR reference as the active Existing Planning Artifact.
- [ ] The Mac Agent resolves the artifact through the local gh authentication and returns title, number, type, URL, and basic state.
- [ ] The app distinguishes Issue planning affordances from PR review affordances.
- [ ] Failed gh resolution returns a user-visible error without storing a broken attachment.
- [ ] Tests use a fake GitHub executor and cover Issue attach, PR attach, missing artifact, and unauthenticated gh failure.

## Blocked by

- #3
