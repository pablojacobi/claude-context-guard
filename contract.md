Additional instructions for this summary. Keep the sections you were already asked for
(`Primary Request and Intent`, `Files and Code Sections`, `Errors and fixes`, `Pending Tasks`,
`Current Work`, `Optional Next Step`, etc.) and apply the following ON TOP of them.

## ADD these two sections, which are not in the base list

**`Decisions and Rationale`** — the most important content, and what gets lost first:
- Every relevant design or architecture decision, and **why** it was made.
- The constraints that shaped it.
- **Alternatives that were evaluated and rejected, with the reason for the rejection.** Without
  this, the conversation will re-propose what was already discarded.
- Hypotheses that were refuted, and what refuted them.
- Assumptions not yet verified, explicitly marked as such.

**`Repo State`**:
- Active branch and worktree.
- Commits created in this session, and the ones still pending.
- Migrations or schema changes applied.
- External or concurrent changes that must not be overwritten.

## ADJUST the base sections

- `Primary Request and Intent`: include the **verifiable success criterion** — the exact command
  or condition that decides whether the task is done. Describing the intent is not enough.
- `Errors and fixes`: for errors **still unresolved**, keep the **literal** message. For errors
  already fixed, one line with the cause and the fix; nothing more.
- Add the validation state: which commands were run, what passes, what fails, and **what still
  has to run before success can be declared**.
- `Optional Next Step`: besides the next step, the following 2-3 actions and the rollback if one
  applies.

## DISCARD — this part overrides the expansive instructions above

The base list asks you to enumerate EVERYTHING. Do not: the goal is a summary to **resume the
work**, not minutes of the conversation. Concretely:

- Do **not** narrate the conversation message by message or turn by turn.
- Do **not** transcribe every user message. Keep only the ones that changed the direction, the
  scope, or a decision — paraphrased, unless the exact wording matters.
- Do **not** copy the content of files that are on disk: reference them by path.
- Do **not** include full logs: the relevant error is enough.
- Do **not** repeat tool outputs or regenerable results.
- Do **not** keep exploration already resolved (only its conclusion), dead hypotheses, or
  obsolete plans.
- **Never** reproduce secrets, tokens, credentials, or sensitive data.

- If you use an `<analysis>` block as a reasoning step, **keep it short**: it is a scratchpad,
  not part of the deliverable, and it must not duplicate what already goes in the sections. Do
  not enumerate the conversation turn by turn there.

When in doubt between losing a decision and losing a log: **keep the decision.**