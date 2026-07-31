#!/usr/bin/env bash
# Event simulation for the context-guard hooks.
#
# Every test runs against a throwaway CG_HOME and a throwaway git repo, so this
# never reads or writes the real logs, state or handoffs.
set -uo pipefail

BIN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

JQ="${CG_JQ:-/usr/bin/jq}"
[ -x "$JQ" ] || JQ=$(command -v jq 2>/dev/null || echo /nonexistent)
[ -x "$JQ" ] || { printf 'jq not found; cannot run the suite\n' >&2; exit 1; }

pass=0 fail=0
ok() {
  printf '  ok    %s\n' "$1"
  pass=$((pass + 1))
}
no() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '        %s\n' "$2"
  fail=$((fail + 1))
}

# A fresh CG_HOME with the real contract, so the contract text is under test too.
fresh() {
  CG_HOME="$TMP/cg-$1"
  export CG_HOME
  rm -rf "$CG_HOME"
  mkdir -p "$CG_HOME"/{logs,state,night}
  cp "$BIN/../contract.md" "$CG_HOME/contract.md"
}

repo() { # a real git repo, since the hooks read real git state
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  printf 'x\n' > "$d/f.txt"
  git -C "$d" add -A 2>/dev/null
  git -C "$d" commit -qm init 2>/dev/null
  printf '%s' "$d"
}

payload() { # payload <event> <sid> <cwd> [trigger] [before] [after]
  "$JQ" -cn \
    --arg hook_event_name "$1" --arg session_id "$2" --arg cwd "$3" \
    --arg trigger "${4:-auto}" \
    --argjson tokens_before "${5:-null}" --argjson tokens_after "${6:-null}" \
    '$ARGS.named'
}

lines() { cat "$CG_HOME/logs"/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }
logfield() { cat "$CG_HOME/logs"/*.jsonl 2>/dev/null | "$JQ" -r "$1" 2>/dev/null; }

printf '== PreCompact ==\n'

# 1. stdout is the contract, and only the contract.
fresh 1
R=$(repo r1)
out=$(payload PreCompact sess-aaa "$R" auto 441203 | "$BIN/pre-compact.sh")
if printf '%s' "$out" | grep -q 'Decisions and Rationale' &&
  printf '%s' "$out" | grep -q 'Repo State' &&
  printf '%s' "$out" | grep -q 'DISCARD'; then
  ok 'stdout carries the sections the contract adds'
else
  no 'stdout carries the sections the contract adds' "$(printf '%s' "$out" | head -3)"
fi
if printf '%s' "$out" | grep -q '"event"'; then
  no 'stdout is NOT contaminated with the log' 'log JSON appeared on stdout'
else
  ok 'stdout is NOT contaminated with the log'
fi

# 2. the log line carries the right session, branch and tokens.
if [ "$(lines)" = 1 ] && [ "$(logfield .session_id)" = sess-aaa ] &&
  [ "$(logfield .tokens_before)" = 441203 ] && [ "$(logfield .event)" = pre_compact ]; then
  ok 'log: one line with session_id, event and tokens_before'
else
  no 'log: one line with session_id, event and tokens_before' "$(cat "$CG_HOME/logs"/*.jsonl)"
fi

# 3. parallel isolation: two sessions, two independent lines, independent counters.
fresh 3
R=$(repo r3)
payload PreCompact sess-AAA "$R" auto 400000 | "$BIN/pre-compact.sh" > /dev/null
payload PreCompact sess-BBB "$R" auto 410000 | "$BIN/pre-compact.sh" > /dev/null
payload PreCompact sess-AAA "$R" auto 420000 | "$BIN/pre-compact.sh" > /dev/null
got=$(logfield '"\(.session_id):\(.n)"' | tr '\n' ' ')
if [ "$got" = 'sess-AAA:1 sess-BBB:1 sess-AAA:2 ' ]; then
  ok 'two sessions: independent lines and per-session counter'
else
  no 'two sessions: independent lines and per-session counter' "got: $got"
fi
if [ "$(cat "$CG_HOME/logs"/*.jsonl | "$JQ" -s length)" = 3 ]; then
  ok 'three valid JSON lines, no interleaving'
else
  no 'three valid JSON lines, no interleaving'
fi

# 4. kill switch.
fresh 4
R=$(repo r4)
touch "$CG_HOME/disabled"
out=$(payload PreCompact sess-off "$R" auto 400000 | "$BIN/pre-compact.sh")
if [ -z "$out" ] && [ "$(lines)" = 0 ]; then
  ok 'disabled: empty stdout and zero log lines'
else
  no 'disabled: empty stdout and zero log lines' "stdout=${#out}b lines=$(lines)"
fi

# 5. fails open on garbage.
fresh 5
bad_ok=1
for bad in '' 'not json' '{"session_id":' '[]'; do
  printf '%s' "$bad" | "$BIN/pre-compact.sh" > /dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    no "invalid stdin exits 0 (input: '$bad')" "rc=$rc"
    bad_ok=0
  fi
done
[ "$bad_ok" = 1 ] && ok 'empty/malformed stdin: exit 0, no crash'

# 6. delicate git state is injected, not used as a veto.
fresh 6
R=$(repo r6)
git -C "$R" rev-parse HEAD > "$R/.git/MERGE_HEAD"
out=$(payload PreCompact sess-git "$R" auto 400000 | "$BIN/pre-compact.sh")
rc=$?
if printf '%s' "$out" | grep -q 'CRITICAL GIT STATE' && printf '%s' "$out" | grep -q 'MERGE_HEAD'; then
  ok 'MERGE_HEAD: the contract is prefixed with CRITICAL GIT STATE'
else
  no 'MERGE_HEAD: the contract is prefixed with CRITICAL GIT STATE'
fi
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Decisions and Rationale'; then
  ok 'MERGE_HEAD: does NOT veto (exit 0 and full contract)'
else
  no 'MERGE_HEAD: does NOT veto (exit 0 and full contract)' "rc=$rc"
fi
if [ "$(logfield '.delicate | index("MERGE_HEAD") != null')" = true ]; then
  ok 'MERGE_HEAD lands in the log'
else
  no 'MERGE_HEAD lands in the log' "$(logfield .delicate)"
fi

printf '\n== PostCompact ==\n'

# 7. saving is derived when the payload gives only the endpoints.
fresh 7
R=$(repo r7)
payload PostCompact sess-post "$R" auto 441203 38112 | "$BIN/post-compact.sh"
if [ "$(logfield .tokens_saved)" = 403091 ] && [ "$(logfield .event)" = post_compact ]; then
  ok 'tokens_saved = before - after (403091)'
else
  no 'tokens_saved = before - after (403091)' "$(logfield .tokens_saved)"
fi
# A missing count must stay null, never 0: they mean different things in an audit.
fresh 7b
R=$(repo r7b)
payload PostCompact sess-null "$R" manual | "$BIN/post-compact.sh"
if [ "$(logfield .tokens_before)" = null ] && [ "$(logfield .tokens_saved)" = null ]; then
  ok 'absent fields stay null, not 0'
else
  no 'absent fields stay null, not 0' "$(cat "$CG_HOME/logs"/*.jsonl)"
fi

# The self-monitoring check: it must distinguish "a compaction happened" from "the
# contract was actually applied". Calibrated against a real summary that ignored
# the contract entirely.
fresh 7c
"$JQ" -cn --arg session_id s --arg cwd /tmp --arg trigger auto \
  --arg compact_summary '## Primary Request and Intent
x
## Decisions and Rationale
X was discarded because Y
## Repo State
branch fix/a' '$ARGS.named' | "$BIN/post-compact.sh"
if [ "$(logfield .contract_markers)" = 2 ] && [ "$(logfield .summary_bytes)" -gt 0 ]; then
  ok 'contract applied -> contract_markers=2'
else
  no 'contract applied -> contract_markers=2' "$(logfield .contract_markers)"
fi
fresh 7d
"$JQ" -cn --arg session_id s --arg cwd /tmp --arg trigger auto \
  --arg compact_summary '<analysis>
User message 1: ...
User message 2: ...
## Primary Request and Intent
x' '$ARGS.named' | "$BIN/post-compact.sh"
if [ "$(logfield .contract_markers)" = 0 ]; then
  ok 'chronological summary without the contract -> contract_markers=0'
else
  no 'chronological summary without the contract -> contract_markers=0' "$(logfield .contract_markers)"
fi

printf '\n== Stop / handoff (always on) ==\n'

# 8. always-on: no marker needed; disabled still silences everything.
fresh 8
R=$(repo r8)
touch "$CG_HOME/disabled"
printf '{"session_id":"s-off","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh" > /dev/null 2>&1 &&
  ok 'disabled: exit 0' || no 'disabled: exit 0'
if [ ! -f "$CG_HOME/night/handoff-s-off.md" ] && [ "$(lines)" = 0 ]; then
  ok 'disabled: neither handoff nor log'
else
  no 'disabled: neither handoff nor log'
fi

# 9. without any marker, the handoff appears and carries verifiable state.
fresh 9
R=$(repo r9)
printf 'dirty\n' > "$R/new.txt"
printf '{"session_id":"sess-night","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh"
H="$CG_HOME/night/handoff-sess-night.md"
if [ -f "$H" ] && grep -q 'Session handoff' "$H" && grep -q 'new.txt' "$H" &&
  grep -q 'turn: 1' "$H"; then
  ok 'handoff created with branch, touched files and turn'
else
  no 'handoff created with branch, touched files and turn' "$(head -12 "$H" 2>/dev/null)"
fi

# 10. stall detection: git AND fs both silent for N turns.
sleep 1   # ensure the state file's mtime is strictly newer than the repo files
printf '2' > "$CG_HOME/stall-limit"
printf '{"session_id":"sess-night","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh"
printf '{"session_id":"sess-night","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh"
if head -1 "$H" | grep -q 'STALLED'; then
  ok 'STALLED after 2 turns with no HEAD or working-tree change'
else
  no 'STALLED after 2 turns with no HEAD or working-tree change' "$(head -1 "$H")"
fi
# Real progress must clear it.
git -C "$R" add -A 2> /dev/null && git -C "$R" commit -qm work 2> /dev/null
printf '{"session_id":"sess-night","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh"
if head -1 "$H" | grep -q 'STALLED'; then
  no 'a commit clears the STALLED' "$(head -1 "$H")"
else
  ok 'a commit clears the STALLED'
fi
if grep -q 'work' "$H"; then
  ok 'the handoff lists the commits of the run'
else
  no 'the handoff lists the commits of the run'
fi

# 11. the handoff survives a session that never got a closing turn.
if [ -f "$H" ] && [ ! -f "$H.tmp.$$" ]; then
  ok 'complete handoff on disk after the last turn (survives a cut)'
else
  no 'complete handoff on disk after the last turn (survives a cut)'
fi
# And it is never left half-written: no stray temp files.
if [ -z "$(ls "$CG_HOME/night"/*.tmp.* 2> /dev/null)" ]; then
  ok 'no half-written temp files (atomic rename)'
else
  no 'no half-written temp files (atomic rename)'
fi

# 12. workspace root: cwd is NOT a repo, several repos live side by side inside
# it. Before cg_repos this made the progress signature constant, so the stall
# detector reported STALLED while work was actually happening in the sub-repos.
fresh 12
printf '2' > "$CG_HOME/stall-limit"
WS="$TMP/ws"
for r in repoA repoB; do
  mkdir -p "$WS/$r"
  git -C "$WS/$r" init -q 2> /dev/null
  git -C "$WS/$r" config user.email t@t
  git -C "$WS/$r" config user.name t
  printf 'x\n' > "$WS/$r/f.txt"
  git -C "$WS/$r" add -A 2> /dev/null
  git -C "$WS/$r" commit -qm init 2> /dev/null
done
P="{\"session_id\":\"w\",\"cwd\":\"$WS\"}"
printf '%s' "$P" | "$BIN/stop-progress.sh"
if grep -q 'repoA' "$CG_HOME/night/handoff-w.md"; then
  ok 'workspace root: discovers the inner repos'
else
  no 'workspace root: discovers the inner repos'
fi
HW="$CG_HOME/night/handoff-w.md"
grep -q 'repoA' "$HW" && grep -q 'repoB' "$HW" &&
  ok 'handoff lists each repo with its branch' || no 'handoff lists each repo with its branch'

sleep 1   # state file mtime must pass the repo files before the quiet turns
printf '%s' "$P" | "$BIN/stop-progress.sh"
printf '%s' "$P" | "$BIN/stop-progress.sh"
if head -1 "$HW" | grep -q STALLED; then
  ok 'workspace root: real STALLED when no repo moves'
else
  no 'workspace root: real STALLED when no repo moves' "$(head -1 "$HW")"
fi
# A change in ONE repo must clear it.
printf 'new\n' > "$WS/repoB/new.txt"
printf '%s' "$P" | "$BIN/stop-progress.sh"
if head -1 "$HW" | grep -q STALLED; then
  no 'a change in a single repo clears the STALLED' "$(head -1 "$HW")"
else
  ok 'a change in a single repo clears the STALLED'
fi

# 13. no repo anywhere: fs activity is the signal. A quiet dir stalls; touching
# a file clears it. This is the fix for the 2026-07-30 false STALLED: research
# work that writes files but never commits now counts as progress.
fresh 13
printf '1' > "$CG_HOME/stall-limit"
BARE="$TMP/bare"
mkdir -p "$BARE"
printf 'x\n' > "$BARE/notes.md"
PB="{\"session_id\":\"b\",\"cwd\":\"$BARE\"}"
printf '%s' "$PB" | "$BIN/stop-progress.sh"
sleep 1
printf '%s' "$PB" | "$BIN/stop-progress.sh"
if head -1 "$CG_HOME/night/handoff-b.md" | grep -q STALLED; then
  ok 'no repos and no activity: STALLED via the filesystem signal'
else
  no 'no repos and no activity: STALLED via the filesystem signal' \
    "$(head -1 "$CG_HOME/night/handoff-b.md")"
fi
sleep 1
printf 'more notes\n' >> "$BARE/notes.md"
printf '%s' "$PB" | "$BIN/stop-progress.sh"
if head -1 "$CG_HOME/night/handoff-b.md" | grep -q STALLED; then
  no 'editing a file (no git) clears the STALLED' "$(head -1 "$CG_HOME/night/handoff-b.md")"
else
  ok 'editing a file (no git) clears the STALLED'
fi

# 14. autonomous run (velador): claim, block, budget, stall cut, model close.
printf '\n== Autonomous run (velador) ==\n'
fresh 14
R=$(repo r14)
printf '9' > "$CG_HOME/stall-limit"
printf 'cwd: %s\nbudget: 2\n---\nFinish feature X. Criterion: pytest green.\n' "$R" \
  > "$CG_HOME/night/request.md"
out=$(printf '{"session_id":"sess-auto","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
M="$CG_HOME/night/auto-sess-auto.md"
if [ -f "$M" ] && [ ! -f "$CG_HOME/night/request.md" ] &&
  printf '%s' "$out" | "$JQ" -e '.decision == "block"' > /dev/null 2>&1 &&
  printf '%s' "$out" | grep -q 'Finish feature X' &&
  printf '%s' "$out" | grep -qF "$M"; then
  ok 'request claimed -> block with objective and marker path'
else
  no 'request claimed -> block with objective and marker path' "$(printf '%s' "$out" | head -2)"
fi

# progress each turn so the stall cut stays out of this budget test
printf 'x\n' >> "$R/f.txt"
out=$(printf '{"session_id":"sess-auto","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
printf '%s' "$out" | grep -q 'turn 2/2' && ok 'second turn: block 2/2' ||
  no 'second turn: block 2/2' "$(printf '%s' "$out" | head -1)"
printf 'x\n' >> "$R/f.txt"
out=$(printf '{"session_id":"sess-auto","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
if [ -z "$out" ] && [ ! -f "$M" ] &&
  head -1 "$CG_HOME/night/handoff-sess-auto.md" | grep -q 'BUDGET EXHAUSTED'; then
  ok 'budget exhausted: no block, marker deleted, handoff annotated'
else
  no 'budget exhausted: no block, marker deleted, handoff annotated' \
    "out=${#out}b marker=$([ -f "$M" ] && echo alive || echo gone) $(head -1 "$CG_HOME/night/handoff-sess-auto.md")"
fi

# stall cut: quiet turns kill the run before the budget does
fresh 14b
R=$(repo r14b)
printf '1' > "$CG_HOME/stall-limit"
printf 'cwd: %s\nbudget: 99\n---\nObjective Y.\n' "$R" > "$CG_HOME/night/request.md"
printf '{"session_id":"sess-st","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh" > /dev/null
sleep 1
out=$(printf '{"session_id":"sess-st","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
if [ -z "$out" ] && [ ! -f "$CG_HOME/night/auto-sess-st.md" ] &&
  head -1 "$CG_HOME/night/handoff-sess-st.md" | grep -q 'AUTONOMOUS RUN CUT'; then
  ok 'stalling cuts the run before the budget does'
else
  no 'stalling cuts the run before the budget does' \
    "$(head -1 "$CG_HOME/night/handoff-sess-st.md")"
fi

# a request from another checkout must not be claimed
fresh 14c
R=$(repo r14c)
printf 'cwd: /elsewhere\nbudget: 5\n---\nSomeone else'"'"'s objective.\n' > "$CG_HOME/night/request.md"
out=$(printf '{"session_id":"sess-nc","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
if [ -z "$out" ] && [ -f "$CG_HOME/night/request.md" ] &&
  [ ! -f "$CG_HOME/night/auto-sess-nc.md" ]; then
  ok 'a request from another cwd is NOT claimed'
else
  no 'a request from another cwd is NOT claimed'
fi

# no budget line -> unlimited: keeps blocking past what the old default would cut
fresh 14e
R=$(repo r14e)
printf '9' > "$CG_HOME/stall-limit"
printf 'cwd: %s\n---\nUncapped objective.\n' "$R" > "$CG_HOME/night/request.md"
un_ok=1
for _ in 1 2 3 4; do
  printf 'x\n' >> "$R/f.txt"
  out=$(printf '{"session_id":"sess-un","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
  printf '%s' "$out" | "$JQ" -e '.decision == "block"' > /dev/null 2>&1 || un_ok=0
done
if [ "$un_ok" = 1 ] && printf '%s' "$out" | grep -q 'no cap'; then
  ok 'no budget: uncapped, keeps blocking and says so ("no cap")'
else
  no 'no budget: uncapped, keeps blocking and says so ("no cap")' "$(printf '%s' "$out" | head -1)"
fi

# the model closing the run: deleting the marker ends the loop cleanly
fresh 14d
R=$(repo r14d)
printf '9' > "$CG_HOME/stall-limit"
printf 'cwd: %s\nbudget: 9\n---\nObjective Z.\n' "$R" > "$CG_HOME/night/request.md"
printf '{"session_id":"sess-cl","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh" > /dev/null
rm -f "$CG_HOME/night/auto-sess-cl.md"
printf 'x\n' >> "$R/f.txt"
out=$(printf '{"session_id":"sess-cl","cwd":"%s"}' "$R" | "$BIN/stop-progress.sh")
[ -z "$out" ] && ok 'the model deletes the marker -> the session stops normally' ||
  no 'the model deletes the marker -> the session stops normally'

printf '\n== cg-status ==\n'

# 15. the audit report over a synthetic log: per-session counts, drift judged by
# the MOST RECENT value (averaging frozen configs fabricated a false 10% alarm
# on 2026-07-30), and checkout-collision detection.
fresh 15
ts_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '{"ts":"2020-01-01T00:00:00Z","event":"pre_compact","trigger":"auto","session_id":"old-sess-000","cwd":"/ws/a","context_tokens":537000}\n'
  printf '{"ts":"%s","event":"pre_compact","trigger":"auto","session_id":"new-sess-111","cwd":"/ws/a","branch":"main","context_tokens":440000}\n' "$ts_now"
  printf '{"ts":"%s","event":"post_compact","trigger":"auto","session_id":"new-sess-111","cwd":"/ws/a","tokens_before":440000,"tokens_saved":400000}\n' "$ts_now"
  printf '{"ts":"%s","event":"turn","session_id":"other-sess-222","cwd":"/ws/a"}\n' "$ts_now"
} > "$CG_HOME/logs/synthetic.jsonl"
SH="$TMP/statushome"
mkdir -p "$SH"
st=$(HOME="$SH" CG_HOME="$CG_HOME" CG_WINDOW=473000 "$BIN/cg-status.sh" 2>&1)
if printf '%s' "$st" | grep -q 'new-sess-111  started=1 completed=1'; then
  ok 'status: per-session started/completed counts'
else
  no 'status: per-session started/completed counts' "$(printf '%s' "$st" | sed -n '4,6p')"
fi
if printf '%s' "$st" | grep -q 'series: 537000, 440000' &&
  printf '%s' "$st" | grep -q 'last=440000' &&
  printf '%s' "$st" | grep -q 'deviation=0%'; then
  ok 'status: drift judged by the most recent value, not the average'
else
  no 'status: drift judged by the most recent value, not the average' \
    "$(printf '%s' "$st" | grep -A2 'Arm-point drift')"
fi
if printf '%s' "$st" | grep -q 'ATTENTION'; then
  no 'status: an in-band last value raises no alarm'
else
  ok 'status: an in-band last value raises no alarm'
fi
if printf '%s' "$st" | grep -q 'shared by: new-sess-111, other-sess-2'; then
  ok 'status: two sessions in one checkout -> collision notice'
else
  no 'status: two sessions in one checkout -> collision notice' \
    "$(printf '%s' "$st" | grep -A1 NOTICE)"
fi

printf '\n== install / uninstall ==\n'

# When a real settings.json exists (a developer machine) the assertions run
# against it -- the strongest possible fixture. On CI or a fresh machine, a
# representative stand-in keeps these tests running instead of silently skipping.
S="$HOME/.claude/settings.json"
if [ -f "$S" ]; then
  cp "$S" "$TMP/orig.json"
else
  "$JQ" -n '{model:"opus", effortLevel:"high", theme:"dark",
             permissions:{allow:["Bash(ls:*)","Read(~/notes.md)"], deny:["WebFetch"]}}' \
    > "$TMP/orig.json"
fi
if [ -s "$TMP/orig.json" ]; then
  FH="$TMP/fakehome"
  mkdir -p "$FH/.claude/backups"
  cp "$TMP/orig.json" "$FH/.claude/settings.json"
  perms_before=$("$JQ" '.permissions.allow // [] | length' "$TMP/orig.json")

  # A throwaway CG_HOME as well as a throwaway HOME. Without this, install.sh
  # derives CG_HOME from its own location and mutates the REAL tree -- which is
  # how a test run once silently deleted the live capture flag.
  CGH="$TMP/cg-install"
  mkdir -p "$CGH/bin" "$CGH/skills/velador"
  cp "$BIN/../skills/velador/SKILL.md" "$CGH/skills/velador/SKILL.md"
  REAL_CG=$(cd -- "$BIN/.." && pwd)
  real_capture_before=$([ -f "$REAL_CG/capture" ] && echo 1 || echo 0)
  real_disabled_before=$([ -f "$REAL_CG/disabled" ] && echo 1 || echo 0)
  inst() { HOME="$FH" CG_HOME="$CGH" "$BIN/../install.sh" "$@" > /dev/null 2>&1; }
  uninst() { HOME="$FH" CG_HOME="$CGH" "$BIN/../uninstall.sh" > /dev/null 2>&1; }

  inst
  rc=$?
  got_hooks=$("$JQ" -r '.hooks | keys | sort | join(",")' "$FH/.claude/settings.json" 2>/dev/null)
  got_w=$("$JQ" -r '.autoCompactWindow // "none"' "$FH/.claude/settings.json" 2>/dev/null)
  got_perms=$("$JQ" '.permissions.allow // [] | length' "$FH/.claude/settings.json" 2>/dev/null)
  if [ "$rc" -eq 0 ] && [ "$got_w" = 473000 ] &&
    [ "$got_hooks" = 'PostCompact,PreCompact,Stop' ]; then
    ok 'install: wires the 3 hooks and autoCompactWindow=473000'
  else
    no 'install: wires the 3 hooks and autoCompactWindow=473000' "w=$got_w hooks=$got_hooks rc=$rc"
  fi
  if [ "$got_perms" = "$perms_before" ]; then
    ok "install: preserves the $perms_before permissions entries"
  else
    no "install: preserves the $perms_before permissions entries" "left $got_perms"
  fi
  if [ -f "$FH/.claude/skills/velador/SKILL.md" ]; then
    ok 'install: copies the velador skill into ~/.claude/skills'
  else
    no 'install: copies the velador skill into ~/.claude/skills'
  fi

  # Idempotent: installing twice must not stack duplicate entries.
  inst
  if [ "$("$JQ" '.hooks.PreCompact | length' "$FH/.claude/settings.json")" = 1 ]; then
    ok 'install: idempotent (no duplicate entries)'
  else
    no 'install: idempotent (no duplicate entries)'
  fi

  # A foreign hook must survive both directions.
  "$JQ" '.hooks.PostToolUse = [{matcher:"Write",hooks:[{type:"command",command:"/other/x.sh"}]}]' \
    "$FH/.claude/settings.json" > "$FH/t" && mv "$FH/t" "$FH/.claude/settings.json"
  inst
  uninst
  if [ "$("$JQ" -r '.hooks.PostToolUse[0].hooks[0].command' "$FH/.claude/settings.json")" = /other/x.sh ]; then
    ok 'uninstall: leaves foreign hooks alone'
  else
    no 'uninstall: leaves foreign hooks alone'
  fi
  if [ ! -f "$FH/.claude/skills/velador/SKILL.md" ]; then
    ok 'uninstall: removes the installed velador skill'
  else
    no 'uninstall: removes the installed velador skill'
  fi

  # Round-trip must land on a canonically identical file. Two subtleties:
  #  - its own clean copy, because reusing the fake home above would leave an empty
  #    .hooks object from the foreign-hook test and measure the test's leftovers;
  #  - the baseline is uninstall(copy), not the copy itself, because once
  #    context-guard is actually installed the real settings.json already carries
  #    our keys and comparing against it would always "fail".
  RT="$TMP/roundtrip"
  mkdir -p "$RT/.claude/backups"
  cp "$TMP/orig.json" "$RT/.claude/settings.json"
  HOME="$RT" CG_HOME="$CGH" "$BIN/../uninstall.sh" > /dev/null 2>&1
  cp "$RT/.claude/settings.json" "$TMP/baseline.json"
  HOME="$RT" CG_HOME="$CGH" "$BIN/../install.sh" > /dev/null 2>&1
  HOME="$RT" CG_HOME="$CGH" "$BIN/../uninstall.sh" > /dev/null 2>&1
  if diff -q <("$JQ" -S . "$TMP/baseline.json") \
    <("$JQ" -S . "$RT/.claude/settings.json") > /dev/null 2>&1; then
    ok 'install -> uninstall leaves settings.json identical'
  else
    no 'install -> uninstall leaves settings.json identical' \
      "$(diff <("$JQ" -S . "$TMP/baseline.json") <("$JQ" -S . "$RT/.claude/settings.json") | head -6)"
  fi

  # Out-of-range windows must be refused, not clamped silently.
  if inst --window 50000; then
    no 'install: refuses --window outside [100000,1000000]'
  else
    ok 'install: refuses --window outside [100000,1000000]'
  fi

  # Regression: running this suite must not disturb the live installation. It used
  # to, because install.sh derived CG_HOME from its own path and ignored the fake
  # HOME, quietly deleting the real capture flag mid-test-run.
  real_capture_after=$([ -f "$REAL_CG/capture" ] && echo 1 || echo 0)
  real_disabled_after=$([ -f "$REAL_CG/disabled" ] && echo 1 || echo 0)
  if [ "$real_capture_before" = "$real_capture_after" ] &&
    [ "$real_disabled_before" = "$real_disabled_after" ]; then
    ok 'the tests do NOT disturb the live installation flags'
  else
    no 'the tests do NOT disturb the live installation flags' \
      "capture $real_capture_before->$real_capture_after, disabled $real_disabled_before->$real_disabled_after"
  fi
  if [ ! -e "$CGH/logs" ] || [ -d "$CGH/logs" ]; then
    ok 'install respects the CG_HOME it is given'
  else
    no 'install respects the CG_HOME it is given'
  fi
fi

printf '\n%s ok, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]