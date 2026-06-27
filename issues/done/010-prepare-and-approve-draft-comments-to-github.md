# Prepare and approve Draft Comments to GitHub

GitHub: https://github.com/brunovskyoliver/55/issues/10

## Parent

#1

## What to build

Prepare Observable Summary-based Draft Comments for the active Planning Artifact, require explicit iPhone approval, then post the approved general GitHub comment through the Mac's gh authentication. The post must be recorded as a GitHub Action in the Audit Timeline.

## Acceptance criteria

- [ ] The Mac Agent can prepare a Draft Comment from observable prompts, agent messages, tool events, command outcomes, File Review data, and requested decisions.
- [ ] The iPhone displays the Draft Comment and requires explicit approval before posting.
- [ ] Approved Draft Comments are posted as general comments to the attached Issue or PR through local gh authentication.
- [ ] Draft rejection or edit/cancel does not post to GitHub.
- [ ] Tests cover generated draft preview, approval post, rejection, gh failure, and audit timeline output.

## Blocked by

- #4
- #6
- #9
