---
name: velador
description: Let this conversation keep working autonomously until its objective is complete, without /goal or a mandatory plan. Invoke when the user asks the session to continue on its own — "leave it running", "keep working on your own", "work through the night", "autonomous mode", "don't stop until it's done", "déjalo corriendo", "sigue trabajando solo", "trabaja toda la noche", "no pares hasta terminarlo", "te dejo trabajando". The model distills the objective from its own context and a deterministic hook sustains the continuation with a turn budget and stall detection.
---

# Velador — autonomous run for this session

The user just let go of your hand. Your job NOW, in this very turn:

## 1. Distill the objective — from your context, not invented

Write `~/.claude/context-guard/night/request.md` with this exact format:

```
cwd: <this session's working directory, absolute>
sid: <this session's id — run `echo "$CLAUDE_CODE_SESSION_ID"` in Bash and
     paste the exact value>
budget: <cap on autonomous turns>
---
<OBJECTIVE: what must be achieved, 2-4 sentences>
<VERIFIABLE CRITERION: the command or condition that decides it is done>
<IF AN APPROVED PLAN EXISTS IN ~/.claude/plans/: "The plan at <path> is the
 source of truth; re-read it after every compaction." The objective IS the plan.>
<WHAT NOT TO DO: limits the user set during the conversation>
```

- `sid` is what binds the run to THIS conversation: without it, any parallel
  session sitting in the same directory can claim your request at its next
  turn end (it happened). If `$CLAUDE_CODE_SESSION_ID` comes back empty, omit
  the line — the hook then falls back to matching the cwd.
- `budget`: if the user said a number or a duration, use it (one autonomous turn
  ≈ 5-15 min of work). If they said nothing: **0 = no cap** — the run ends when
  the criterion is met, when you are genuinely blocked, or when the stall
  detector acts. Since there is no cap, every ~50 autonomous turns re-evaluate
  honestly: is this advancing toward the criterion, or am I circling in
  productive-looking motion? When in doubt, close with a handoff note instead of
  continuing.
- The objective comes from WHAT YOU ALREADY KNOW in this conversation. Do not
  ask the user what they want — if you are here, you already know. If there is
  genuinely no discernible objective, say so and do NOT write the file.
- The criterion must be checkable by a command or an observable fact, not an
  opinion.

## 2. Confirm in one line and keep working

Confirm to the user: objective, criterion, and budget, in 2-3 lines. Then keep
working on the objective **in this same turn** — do not stop to wait.

At the end of this turn, the `Stop` hook claims the request for this session and
from then on re-injects the objective at every turn end, with the X/Y count and
the exact path of the marker file.

## 3. Rules while running autonomously

- **Closing the run = deleting the marker** whose path the hook gives you every
  turn, plus a short closing note (what got done, what did not, next step). Do
  it when the criterion is met, or when you are genuinely blocked: a credential
  you lack, an access, an external service down, a real human decision.
- After 2 failed attempts at the same thing, change approach materially; if 2
  distinct approaches fail, re-examine the hypothesis and close the run with an
  explanation.
- Do not invent work outside the objective to stay busy.
- The usual rules still hold: never push to `main`, never merge without
  authority, one push per PR only after the full gate, nothing irreversible.
- If the user comes back and writes something, their message rules: if they ask
  to stop or change course, **delete the marker first**, then reply.

## What backs you up (you do not manage it)

The hook cuts the run on its own if the budget runs out or if the stall detector
(git + filesystem) sees turns without progress — in both cases it leaves the
reason in the handoff at `~/.claude/context-guard/night/handoff-<sid>.md`, which
is rewritten every turn no matter what. The user can kill the run with `rm` on
the marker or `touch ~/.claude/context-guard/disabled`.