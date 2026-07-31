#!/usr/bin/env bash
# Emit the standard autonomous-run goal, pointed at the newest plan file, and put
# it on the clipboard. This exists because the one thing /goal automation cannot
# remove is the per-session declaration "this session runs unattended" -- but the
# goal's CONTENT is derivable: this workflow always ends planning with an approved
# plan file on disk, and "execute the plan, stop when blocked" is a constant.
#
#   cg-goal.sh            newest plan modified in the last 12h (an overnight run
#                         starts right after planning; older plans are stale)
#   cg-goal.sh <path>     a specific plan file
#   cg-goal.sh --turns N  override the 80-turn ceiling
set -uo pipefail

PLANS="$HOME/.claude/plans"
TURNS=80
PLAN=""

while [ $# -gt 0 ]; do
  case $1 in
  --turns)
    shift
    TURNS=${1:-80}
    ;;
  *) PLAN=$1 ;;
  esac
  shift
done
case $TURNS in '' | *[!0-9]*) TURNS=80 ;; esac

if [ -z "$PLAN" ]; then
  recent=$(find "$PLANS" -maxdepth 1 -name '*.md' -mmin -720 -print0 2>/dev/null |
    xargs -0 ls -t 2>/dev/null)
  PLAN=$(printf '%s\n' "$recent" | head -1)
  n=$(printf '%s\n' "$recent" | grep -c . 2>/dev/null)
  # With parallel conversations, "newest" can be ANOTHER session's plan. Never
  # guess silently: list the candidates so the wrong pick is visible before the
  # goal is pasted, not after a night of executing someone else's plan.
  if [ "${n:-0}" -gt 1 ]; then
    printf 'WARNING: %s plans from the last 12h — pick the one from THIS conversation:\n' "$n" >&2
    printf '%s\n' "$recent" | sed 's/^/  /' >&2
    printf 'Using the newest. If it is not yours: cg-goal.sh <plan.md>\n\n' >&2
  fi
fi
if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
  printf 'No plan from the last 12h in %s\n' "$PLANS" >&2
  printf 'With no plan on disk there is no objective a script can derive: the\n' >&2
  printf 'objective lives only in the conversation. Options:\n' >&2
  printf '  1. Ask the session to write its plan (plan mode) and re-run this.\n' >&2
  printf '  2. Pass an explicit path: cg-goal.sh <plan.md>\n' >&2
  printf '  3. Write the /goal by hand (templates/night-run.md).\n' >&2
  exit 1
fi

GOAL="/goal Execute the plan in $PLAN in full, in order. If you lose the detail after a \
compaction, re-read that file: it is the source of truth, not your memory. Done = the whole \
plan with its gates green. Stop if a credential, an access, or a real human decision is \
missing, if the plan requires waiting on something external, or after $TURNS turns."

printf '%s\n' "$GOAL"
if command -v pbcopy > /dev/null 2>&1; then
  printf '%s' "$GOAL" | pbcopy
  printf '\n(copied to the clipboard — paste it into the conversation and go to sleep)\n' >&2
fi