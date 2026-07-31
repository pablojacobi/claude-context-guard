# Overnight run template (the /goal alternative)

Tracking and handoffs are **always on** — there is nothing to arm. The only manual step is
the `/goal`, because no hook or skill can invoke it for you, and because the objective is
yours, not guessable.

> Prefer the **velador skill** for zero-friction runs: just tell the conversation
> "leave it running until it's done" and the model derives the goal itself. This template
> is the alternative with an external judge (`/goal`'s own evaluator).

## 1. Paste the `/goal` into the conversation

**Shortcut:** if the run is "execute the approved plan" (the common case),

```sh
~/.claude/context-guard/bin/cg-goal.sh
```

generates the line pointing at the newest plan file and puts it on the clipboard: Cmd-V and
go to sleep. For an objective other than the plan, fill in `<...>` and paste the full line.
`/goal` is **per session**: parallel conversations each carry their own without clashing.

```
/goal <VERIFIABLE CONDITION>. Stop after <N> turns. Stop immediately if a credential, an
access, an external service, or a human decision is missing. After 2 failed attempts change
approach materially; if 2 distinct approaches fail, re-examine the hypothesis and stop
instead of retrying. Do not invent requirements or work outside the objective. Do not push,
merge, rebase shared branches, or perform any irreversible operation.
```

Example:

```
/goal `pytest tests/unit -q` exits 0 and the diff is committed on fix/issue-123 in the
myrepo-wt1 worktree. Stop after 25 turns. Stop immediately if a credential, an access, an
external service, or a human decision is missing. After 2 failed attempts change approach
materially; if 2 distinct approaches fail, re-examine the hypothesis and stop instead of
retrying. Do not invent requirements or work outside the objective. Do not push, merge,
rebase shared branches, or perform any irreversible operation.
```

## 2. In the morning

```sh
~/.claude/context-guard/bin/cg-status.sh
cat ~/.claude/context-guard/night/handoff-<session_id>.md
```

The handoff exists **no matter what**, regardless of how the session ended: objective met,
turn limit, blocked, or crash. The hook writes it every turn; the model never writes it at
the end.

If it starts with `# STALLED: N turns with no verifiable progress`, the session was going in
circles: neither HEAD nor the set of modified files changed for N turns. Review which
strategies it already tried before retrying.

## What this does NOT do

- **No hook can stop a session that insists on continuing.** `Stop` can only force the
  opposite. The turn cap is held by `/goal`; irreversible actions are covered by your
  permissions `deny` list and the explicit prohibition above.
- The "stop after N turns" clause is documented but not confirmed in the binary, so it goes
  **inside** the condition in natural language: it degrades to the evaluator instead of
  failing silently. The deterministic handoff is the net in case it does not bite.
- If two overnight conversations touch the same checkout they will trample each other's git
  index. Use one worktree per run; `cg-status.sh` warns when it detects the collision.