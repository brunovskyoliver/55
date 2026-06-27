# Ralph — Default Prompt

Fallback when no `ralph/prompt.md` exists in the project. Copy to `ralph/prompt.md` and customise for your stack.

---

Work on **AFK issues only** — fully specified, no human input needed. Skip HITL or "needs info" issues.

Issue source: local Markdown queue in `issues/*.md`; skip `issues/done/`.

Skip tasks whose `Blocked by` references point at unfinished local or GitHub issues.

Pick ONE task per iteration. Priority: bugfixes → dev infra → tracer bullets → polish → refactors.

Before committing, run whatever feedback loops exist:
- `cargo test --workspace` / `cargo build --workspace`
- `npm test` / `npm run typecheck`
- `pytest` / `go test ./...`

Commit message must include: key decisions, files changed, blockers for next iteration.

Move completed issues to `issues/done/`. Append progress notes to partial ones. If the local issue contains a GitHub issue URL, also comment on the linked GitHub issue; close it when the local issue is done.

If all AFK tasks are done, output `<promise>NO MORE TASKS</promise>`.

ONLY WORK ON A SINGLE TASK.
