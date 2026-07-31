# claude-context-guard

> This README is the canonical document. A Spanish translation is available at
> [README.es.md](README.es.md).

Lowers the context ceiling of every Claude Code conversation from **~784,000 to ~440,000
tokens** on 1M-context models — independently per session, auditable, and fully reversible.
No clicks, no `tmux send-keys`, no external supervisor process.

The centerpiece is **a single settings key**. Everything else is a preservation contract and
evidence.

**Why bother?** With `autoCompactWindow` unset, Claude Code lets a 1M-model conversation grow
to ~784K tokens before auto-compacting. Every turn near that ceiling drags the full context
with it — slower and vastly more expensive. Capping compaction at ~440K roughly halves the
context each turn pays for, and the preservation contract keeps the summary from losing the
decisions that matter.

Born and validated on the Claude Code plugin inside **TRAE IDE** (macOS); works with any host
that shares `~/.claude/` (CLI, VS Code extension).

## Status

`v0.0.1` — early but production-measured by its author:

- 12 automatic compactions landed between **435,080 and 440,004 tokens** (target 440K,
  max deviation 1.1%) across 7 independent sessions.
- Preservation contract applied in 18/19 summaries (`contract_markers: 2` in the log).
- Summaries stayed at 13–24 KB regardless of transcript size (3.8 MB to 42 MB).
- Deterministic handoffs covered 87 sessions, including sessions killed mid-run.

Feedback and issues are very welcome — that is the point of publishing this early.

## Requirements

- Claude Code ≥ 2.1.x (the bundled binary of the TRAE/VS Code extension counts).
- `jq` (macOS ships it; on Linux `apt install jq`).
- macOS is tested daily; Linux passes the test suite in CI but has not been used in anger.

## Install

```sh
git clone https://github.com/pablojacobi/claude-context-guard ~/.claude/context-guard
~/.claude/context-guard/install.sh
```

`install.sh` backs up `~/.claude/settings.json` to `~/.claude/backups/`, merges with `jq`
onto the existing object (never rewrites it), verifies no key was lost, and aborts on any
discrepancy. It also copies the `velador` skill to `~/.claude/skills/`.

**Hooks and the threshold are read when a session starts.** Conversations already open keep
the old config: open a new one.

Verify:

```sh
~/.claude/context-guard/tests/run-tests.sh        # 49 assertions, throwaway sandbox
~/.claude/context-guard/tests/threshold-math.sh   # formula canary
~/.claude/context-guard/bin/cg-status.sh          # read-only audit
```

Uninstall (leaves settings exactly as they were):

```sh
~/.claude/context-guard/uninstall.sh              # or --restore for the textual backup
```

## How it works

### Layer 0 — the threshold (does 90% of the work)

`autoCompactWindow: 473000` in `~/.claude/settings.json`. The binary's formula promises
`min(eff × 0.8, eff − 13000)`, but what we **measured** in production (2026-07-30, two
sessions: 534,878 and 536,796 with window=570000) is that only the reactive term rules:

```
actual arm point ≈ autoCompactWindow − 20,000 − 13,000
```

With `473000` on a 1M model → **arms at ~440,000**. If the remote fraction ever returned to
0.2, the point drops to 362,400: the calibration fails toward the aggressive side, never the
lax one.

`min()` bounds by model, so the same key works on a 200K model (arms at 144,000) with no
per-model configuration.

### Layer 1 — the preservation contract

`contract.md` is emitted on **stdout of the `PreCompact` hook**, and the binary uses it as
the compaction instructions for the summarizer.

It lives here and not in `CLAUDE.md` for cost reasons: a global `~/.claude/CLAUDE.md` is
loaded into the system prompt of *every* session and charges tokens on every turn — exactly
what we are trying to reduce. Hook stdout costs **zero until a compaction happens**.

The contract *adds to* the summarizer's built-in template instead of competing with it
(a from-scratch replacement was tried and lost 0/7 against the built-in structure). It adds
`Decisions and Rationale` and `Repo State` sections, demands the verifiable success
criterion and literal current errors, and carries an explicit discard list — decisions
survive, logs do not.

If delicate git state is detected (`MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`,
`index.lock`, a rebase in progress), a `CRITICAL GIT STATE` block is prefixed with the
branch, the exact step, and the next action.

**Why it does not veto the compaction:** compacting only rewrites conversational memory
between turns — it cannot interrupt a running tool or a git operation. Deferring it would
not protect the rebase; it would only let the session keep climbing. The real risk is
*losing the note* about the state, so it is detected and injected, not blocked.

### Layer 2 — evidence

One JSON line per event in `logs/YYYY-MM.jsonl`, with `session_id`, `cwd`, branch, worktree,
trigger, token counts and a per-session counter. No transcripts, no secrets.

Isolation: a one-line sub-4KB `printf` to an `O_APPEND` fd is atomic, and the counter lives
in a per-session file, so parallel conversations never interleave or perturb each other.

`post-compact.sh` also checks the summary itself (the `PostCompact` payload carries it) for
the contract's marker sections — so the log distinguishes "a compaction happened" from "the
contract was actually applied".

### Layer 3 — always-on handoffs, and the velador

The `Stop` hook rewrites `night/handoff-<session_id>.md` on every turn of **every** session
— there is no mode to arm. Asking the model to "write a handoff when you finish" fails in
exactly the case that matters: when it gets stuck or cut off at 4am. As a by-product of the
hook, "there is always a handoff" is true by construction.

Stalls are detected deterministically: N turns where no HEAD moved, the dirty file set did
not change, **and** no file under the cwd was modified (the filesystem signal exists because
git-only detection once flagged a session that was legitimately researching without
committing).

**Autonomous runs (velador — experimental, not yet validated in a live run):** tell the
conversation "leave it running until it's done" (or in Spanish: "déjalo corriendo"). The
`velador` skill makes the model distill its own objective, success criterion and optional
turn budget into `night/request.md`; the hook claims it for that session and from then on
re-injects the objective at every turn end, forcing continuation until the model deletes the
marker (criterion met or genuinely blocked), the budget runs out, or the stall detector
cuts. **No turn cap by default** (real runs can legitimately last a day); a number in your
phrase becomes a hard cap. The count is visible in every re-injection and in the handoff.
`/goal` + `bin/cg-goal.sh` remain as the alternative with an external judge
(`templates/night-run.md`).

## Operation

| What | How |
|---|---|
| Audit | `bin/cg-status.sh` |
| Kill everything in 1s | `touch ~/.claude/context-guard/disabled` |
| Turn it back on | `rm ~/.claude/context-guard/disabled` |
| Change the threshold | `./install.sh --window 400000` |
| Per-session handoffs | always on; 14-day retention |
| Adjust the stall limit | `echo 8 > stall-limit` (default 6) |
| Update | `git pull && ./install.sh --repair` |
| Uninstall | `./uninstall.sh` (or `--restore` for the textual backup) |
| Also delete logs | `./uninstall.sh --purge` |

Logs rotate monthly. To keep 3 months:

```sh
find ~/.claude/context-guard/logs -name '*.jsonl' -mtime +90 -delete
```

## Honest disclaimers — read before trusting this

1. **`autoCompactWindow` is not in Anthropic's public docs.** It is a valid `settings.json`
   key (verified in the binary, exposed in `/config` in 100K steps) but it can change
   between versions without notice. `tests/threshold-math.sh` is the canary.
2. **The arm point depends on remote config** (server-side gates): it already moved once
   (the binary's 0.2 fraction vs ~0 actually served). Detected by comparing the logged
   `context_tokens` against the expected value; `cg-status.sh` warns at >5% deviation.
3. **`PreCompact` stdout → summarizer instructions is undocumented.** If it silently stops
   working, the contract is lost. Always-on mitigation: `post-compact.sh` counts the
   contract's markers in the actual summary; a sustained `contract_markers: 0` means the
   mechanism died. Documented fallback: move the contract into `~/.claude/CLAUDE.md`, at the
   cost of tokens every turn.
4. **Session config is frozen per process, not forever**: resuming a conversation (or
   restarting the IDE) re-reads settings; a session already past the new threshold compacts
   immediately on resume. Expect one out-of-band data point in the drift series when that
   happens.
5. **Another `PreCompact` hook that prints to stdout would contaminate the contract**,
   because the binary concatenates every hook's stdout. `install.sh` deliberately preserves
   foreign hooks; if you add one on that event, keep its stdout empty.
6. **No hook can stop a session that insists on continuing.** `Stop` can only force the
   opposite. Hard limits live in the budget/stall cut and your permissions `deny` list.
7. **The handoff is deterministic, not omniscient.** It captures git and progress state, not
   the model's reasoning. If a session dies having committed nothing, it will say "no
   verifiable progress" — which is the useful truth, not a fabricated reconstruction.
8. **Progress is measured by git + file activity under the cwd.** A session that only reads
   still counts as stalled; raise `stall-limit` if that bothers you.
9. **The velador is experimental.** Every other layer has live production measurements
   behind it; the velador has a full test-suite cycle but no real overnight run yet.
10. **Compaction does not refund tokens already spent.** It lowers the ceiling: the saving
    comes from not cruising at 780K, not from a rebate.

## After a week, check

- Logged `context_tokens` vs 440,000: deviation >5% ⇒ the remote fraction moved ⇒ adjust
  `autoCompactWindow` proportionally (`cg-status.sh` computes it).
- More than 3-4 compactions/day on a single task ⇒ the window is too small for your workflow
  ⇒ raise it.
- Read the first 2-3 post-compaction turns: if the session re-reads files it did not need or
  re-asks something already decided, a `contract.md` field needs reinforcing.
- `STALLED` during legitimate exploration ⇒ raise `stall-limit`.

## Files

```
install.sh · uninstall.sh · README.md · README.es.md · contract.md · CHANGELOG.md · LICENSE
bin/lib.sh              helpers; everything fails open
bin/pre-compact.sh      contract via stdout + log        (stdout = ONLY the contract)
bin/post-compact.sh     tokens before/after/saved + contract check
bin/stop-progress.sh    deterministic handoff + stall + velador loop (always on)
bin/cg-status.sh        read-only audit
bin/cg-goal.sh          standard goal pointed at the newest plan -> clipboard
skills/velador/         autonomous runs by natural phrase (installed to ~/.claude/skills)
templates/night-run.md  the /goal alternative
tests/run-tests.sh      49 assertions over simulated events, throwaway sandbox
tests/threshold-math.sh formula canary
logs/ state/ night/     runtime, chmod 700, git-ignored
disabled                absent by default; touch -> everything no-ops
capture                 raw-payload capture mode (./install.sh --capture)
stall-limit             turns without progress before STALLED (default 6)
```

## Roadmap

- First live validation of the velador (v0.1 gate).
- Broader host validation: plain CLI and VS Code extension are expected to work (same
  `~/.claude/`), reports welcome.
- Linux field testing (CI-green today, unproven in daily use).

## License

MIT.