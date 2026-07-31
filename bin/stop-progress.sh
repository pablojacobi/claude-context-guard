#!/usr/bin/env bash
# Stop hook: writes a per-session handoff, deterministically, on every turn.
#
# Always on -- there is no mode to arm. Asking the model to "write a handoff when
# you finish" fails in exactly the case that matters: when it gets stuck, gets cut
# off, or hits a turn limit at 4am with nobody watching. So the handoff is a
# by-product of this hook, rewritten every turn, which makes "there is always a
# handoff" true by construction. Whenever any session stops, for any reason, its
# last snapshot is already on disk at night/handoff-<session_id>.md.
#
# Progress has two signals, in order:
#   git  -- any HEAD moved, or any repo's dirty set changed
#   fs   -- any file under cwd modified since the previous turn (bounded find)
# Only when BOTH are silent does the stall counter advance. This exists because
# git-only detection cried STALLED on a session that was legitimately researching
# without committing (2026-07-30, 9 turns "stalled" while working).
#
# Nothing here is periodic: it is driven by end-of-turn. Cost per turn is a few
# git status calls plus one short-circuited find. The kill switch (touch
# $CG_HOME/disabled) still silences everything.
set -uo pipefail

CG_BIN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 0
# shellcheck source=lib.sh
. "$CG_BIN/lib.sh" 2>/dev/null || exit 0

# Consume stdin so the caller never sees a broken pipe.
payload=$(cat 2>/dev/null || true)

cg_disabled && exit 0

cg_capture stop "$payload"

sid=$(cg_field "$payload" .session_id)
cwd=$(cg_field "$payload" .cwd)
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD

mkdir -p "$CG_NIGHT" 2>/dev/null
safe=$(cg_safe "$sid")
state="$CG_NIGHT/progress-$safe"
handoff="$CG_NIGHT/handoff-$safe.md"

# Retention: a handoff only matters while its session is alive or recent. Old
# trios are garbage-collected opportunistically; the dir stays small, so this
# find costs microseconds.
find "$CG_NIGHT" -type f \( -name 'handoff-*' -o -name 'progress-*' -o -name 'base-*' \
  -o -name 'auto-*' \) -mtime +14 -delete 2>/dev/null

# Track every repo under this cwd, not just cwd itself: at a workspace root there
# is no repo, and the sub-repos are where the work lands.
repos=$(cg_repos "$cwd")
sigsrc=""
report=""
delicate_all=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  rb=$(cg_branch "$r")
  rh=$(cg_head "$r")
  rs=$(git -c core.fsmonitor=false -C "$r" status --porcelain 2>/dev/null || true)
  rd=$(cg_git_delicate "$r")
  rsh=$(printf '%s' "$rs" | cksum 2>/dev/null | cut -d' ' -f1)
  dirty=$(printf '%s' "$rs" | grep -c . 2>/dev/null)
  case $dirty in '' | *[!0-9]*) dirty=0 ;; esac
  sigsrc="$sigsrc|${r##*/}:$rh:$rsh"
  [ -n "$rd" ] && delicate_all="$delicate_all ${r##*/}:$rd"
  report="$report$(printf '\n- \x60%s\x60 branch \x60%s\x60 HEAD \x60%s\x60 · %s uncommitted file(s)%s' \
    "${r##*/}" "${rb:-?}" "${rh:-?}" "$dirty" "$([ -n "$rd" ] && printf ' · **%s**' "$rd")")"
done << EOF
$repos
EOF

sig=$(printf '%s' "$sigsrc" | cksum 2>/dev/null | cut -d' ' -f1)

# Filesystem activity since the previous turn. The state file's mtime IS the
# previous turn's end, so -newer against it needs no extra bookkeeping. Bounded
# and pruned; -print -quit short-circuits at the first hit, so the common case
# (active session) touches almost nothing.
fs_act=""
if [ -f "$state" ]; then
  fs_act=$(find "$cwd" -maxdepth 4 \
    \( -name .git -o -name node_modules -o -name .venv -o -name __pycache__ \
    -o -name dist -o -name build -o -name .next \) -prune \
    -o -type f -newer "$state" -print -quit 2>/dev/null)
fi

turn=0 stall=0 prev_sig=""
if [ -f "$state" ]; then
  IFS='|' read -r prev_sig turn stall < "$state" 2>/dev/null || true
  case $turn in '' | *[!0-9]*) turn=0 ;; esac
  case $stall in '' | *[!0-9]*) stall=0 ;; esac
fi
turn=$((turn + 1))

activity=none
if [ -z "$prev_sig" ]; then
  activity=first_turn
elif [ "$sig" != "$prev_sig" ]; then
  activity=git
elif [ -n "$fs_act" ]; then
  activity=fs
fi
if [ "$activity" = none ]; then
  stall=$((stall + 1))
else
  stall=0
fi
printf '%s|%s|%s' "$sig" "$turn" "$stall" > "$state" 2>/dev/null

limit=$(cat "$CG_HOME/stall-limit" 2>/dev/null || printf '6')
case $limit in '' | *[!0-9]*) limit=6 ;; esac

# ---- autonomous run (velador) ------------------------------------------------
# The model, instructed by the velador skill, writes night/request.md during its
# turn; the first Stop of a session whose cwd matches claims it. From then on,
# every turn end re-injects the objective and forces continuation -- until the
# model deletes the marker (objective met / genuinely blocked), the budget runs
# out, or the stall detector cuts it. The hook is the only party with a hard
# stop; the model is the only party who knows the objective. Each does its part.
req="$CG_NIGHT/request.md"
marker="$CG_NIGHT/auto-$safe.md"
countf="$CG_NIGHT/auto-count-$safe"
if [ -f "$req" ]; then
  if [ -n "$(find "$req" -mmin +60 2>/dev/null)" ]; then
    rm -f "$req"   # nobody claimed it within the hour: stale, likely orphaned
  else
    rcwd=$(sed -n 's/^cwd: //p' "$req" 2>/dev/null | head -1)
    rsid=$(sed -n 's/^sid: //p' "$req" 2>/dev/null | head -1)
    # Identity first: an `sid:` line (from $CLAUDE_CODE_SESSION_ID, written by
    # the velador skill) binds the request to exactly one session. cwd alone
    # cannot -- two parallel sessions sitting in the same checkout are
    # indistinguishable, and on 2026-07-31 a bystander session claimed the
    # premiere run's request precisely that way. A request carrying an sid for
    # a DIFFERENT session is left in place for its rightful owner's next Stop.
    # Requests without an sid (hand-written) fall back to the cwd match.
    if [ -n "$rsid" ]; then
      if [ "$rsid" = "$sid" ]; then
        mv -f "$req" "$marker" 2>/dev/null && printf '0' > "$countf"
      fi
    elif [ "$rcwd" = "$cwd" ]; then
      mv -f "$req" "$marker" 2>/dev/null && printf '0' > "$countf"
    fi
  fi
fi

auto_line=""
auto_cut=""
auto_block=""
if [ -f "$marker" ]; then
  # budget: 0 (or absent) = no cap, by explicit user decision (2026-07-30):
  # legitimate runs can last a whole day. With no cap, the remaining
  # deterministic stops are the stall detector and the kill switch; the count
  # stays visible in every re-injection so the self-judge and the audit see it.
  budget=$(sed -n 's/^budget: //p' "$marker" 2>/dev/null | head -1)
  case $budget in '' | *[!0-9]*) budget=0 ;; esac
  lc=$(cat "$countf" 2>/dev/null || printf '0')
  case $lc in '' | *[!0-9]*) lc=0 ;; esac
  btxt=$([ "$budget" -gt 0 ] && printf '%s/%s' "$lc" "$budget" || printf '%s (no cap)' "$lc")
  if [ "$stall" -ge "$limit" ]; then
    rm -f "$marker" "$countf"
    auto_cut="AUTONOMOUS RUN CUT: $stall turns with no verifiable progress (was at $btxt)"
  elif [ "$budget" -gt 0 ] && [ "$lc" -ge "$budget" ]; then
    rm -f "$marker" "$countf"
    auto_cut="BUDGET EXHAUSTED: $budget autonomous turns; the objective remains open"
  else
    lc=$((lc + 1))
    printf '%s' "$lc" > "$countf"
    btxt=$([ "$budget" -gt 0 ] && printf '%s/%s' "$lc" "$budget" || printf '%s (no cap)' "$lc")
    objective=$(sed -n '/^---$/,$p' "$marker" 2>/dev/null | sed '1d')
    [ -n "$objective" ] || objective=$(cat "$marker" 2>/dev/null)
    auto_line="- autonomous run: turn $btxt"
    auto_block=$("$CG_JQ" -cn \
      --arg reason "Autonomous run (turn $btxt). Objective: $objective
Continue working toward the objective. If the success criterion is already met, or you are genuinely blocked (a credential you lack, access, an external service, a human decision), delete $marker and write a short closing note: what got done, what did not, next step. Never push to main, merge, or perform irreversible operations." \
      '{decision: "block", reason: $reason}')
  fi
fi

# Baseline HEADs, so the handoff can show what this session actually committed.
base="$CG_NIGHT/base-$safe"
[ -f "$base" ] && [ -s "$base" ] || printf '%s' "$sigsrc" > "$base" 2>/dev/null

# Write via a temp file and rename so a reader never catches a half-written
# handoff -- including a reader that shows up right after the session died.
tmp="$handoff.tmp.$$"
{
  if [ -n "$auto_cut" ]; then
    printf '# %s\n\n---\n\n' "$auto_cut"
  fi
  if [ "$stall" -ge "$limit" ]; then
    printf '# STALLED: %s turns with no verifiable progress\n\n' "$stall"
    printf 'Across %s turns no HEAD moved, the set of uncommitted files did not\n' "$stall"
    printf 'change, and no file under the cwd was modified. Treat this as a stuck\n'
    printf 'session: review which strategies were already tried before retrying\n'
    printf 'the same one.\n\n---\n\n'
  fi

  # Formats must never lead with "-": bash printf reads that as an option.
  printf '# Session handoff\n\n'
  printf '%s\n' "- ts: $(cg_ts)"
  printf '%s\n' "- session_id: \`$sid\`"
  printf '%s\n' "- cwd: \`$cwd\`"
  printf '%s\n' "- turn: $turn · turns without progress: $stall (limit $limit) · last activity: $activity"
  [ -n "$auto_line" ] && printf '%s\n' "$auto_line"
  [ -n "$delicate_all" ] && printf '%s\n' "- **delicate git state:$delicate_all**"

  printf '\n## Repos\n'
  if [ -n "$report" ]; then
    printf '%s\n' "$report"
  else
    printf '\n(none under this cwd; progress is measured by file activity)\n'
  fi

  printf '\n## Commits made this session\n\n```\n'
  found=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    bh=$(printf '%s' "$(cat "$base" 2>/dev/null)" |
      tr '|' '\n' | grep "^${r##*/}:" | cut -d: -f2)
    ch=$(cg_head "$r")
    if [ -n "$bh" ] && [ -n "$ch" ] && [ "$bh" != "$ch" ]; then
      printf '%s:\n' "${r##*/}"
      git -c core.fsmonitor=false -C "$r" log --oneline "$bh..HEAD" 2>/dev/null
      found=1
    fi
  done << EOF
$repos
EOF
  [ "$found" = 1 ] || printf '(none: no HEAD has moved since the session started)\n'
  printf '```\n'

  printf '\n## Working tree\n\n```\n'
  found=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    rs=$(git -c core.fsmonitor=false -C "$r" status --porcelain 2>/dev/null || true)
    if [ -n "$rs" ]; then
      printf '%s:\n%s\n' "${r##*/}" "$rs"
      found=1
    fi
  done << EOF
$repos
EOF
  [ "$found" = 1 ] || printf '(all clean)\n'
  printf '```\n'

  printf '\n---\n\nDeterministic snapshot: it captures git and progress state, not the\n'
  printf 'model'"'"'s reasoning. If it says "no verifiable progress", that is the fact.\n'
} > "$tmp" 2>/dev/null && mv -f "$tmp" "$handoff" 2>/dev/null

# One JSONL line per turn would drown the compaction events now that this runs
# for every session. Log only what the audit actually reads: the first turn (the
# session exists), stall-threshold crossings, delicate git states, and every
# autonomous-run turn (those are exactly the ones to audit in the morning).
if [ "$turn" -eq 1 ] || [ "$stall" -eq "$limit" ] || [ -n "$delicate_all" ] ||
  [ -n "$auto_line" ] || [ -n "$auto_cut" ]; then
  cg_log "$(cg_json \
    --arg ts "$(cg_ts)" \
    --arg event turn \
    --arg session_id "$sid" \
    --arg cwd "$cwd" \
    --arg activity "$activity" \
    --argjson delicate "$(cg_arr "$delicate_all")" \
    --argjson turn "$turn" \
    --argjson stalled_turns "$stall" \
    --argjson stalled "$([ "$stall" -ge "$limit" ] && printf true || printf false)" \
    --arg auto "${auto_line:+active}${auto_cut:+cut}")"
fi

# The block decision is the LAST thing on stdout, and the only thing ever printed
# there: it is what forces the session to continue the autonomous run.
[ -n "$auto_block" ] && printf '%s\n' "$auto_block"

exit 0