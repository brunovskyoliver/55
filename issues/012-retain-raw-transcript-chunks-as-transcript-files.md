# Retain Raw Transcript chunks as Transcript Files

GitHub: https://github.com/brunovskyoliver/55/issues/12

## Parent

#1

## What to build

Retain Raw Transcript chunks from the active tmux-backed Wrapped Session as append-only Transcript Files referenced by Session Store metadata. Keep transcript data local to the Mac and do not sync full transcripts to the iPhone in this MVP slice.

## Acceptance criteria

- [ ] tmux output from the Wrapped Session is captured into append-only Transcript Files.
- [ ] The Session Store records transcript file metadata and offsets needed for later bounded Transcript Slice reads.
- [ ] Transcript retention is local to the Mac and does not expose full raw logs through the iPhone API.
- [ ] Transcript capture failure is surfaced without breaking structured session event capture.
- [ ] Tests cover append, offset metadata, restart continuation, capture failure, and absence of full transcript sync in Control API responses.

## Blocked by

- #5
- #6
