#!/usr/bin/env bash
# PreCompact hook: supplies the preservation contract, and logs the compaction.
#
# CRITICAL: stdout of a PreCompact hook becomes the compaction's custom
# instructions -- the binary joins the stdout of every successful, non-blocking
# PreCompact hook and hands it to the summariser. So stdout carries the contract
# and NOTHING else. All logging goes to the log file; any noise here would
# contaminate the instructions the summariser receives.
#
# This hook never blocks a compaction. Compaction only rewrites conversation
# memory between turns -- it cannot interrupt a running tool or a git operation,
# so deferring it would not protect a rebase. What it would do is let the
# session keep climbing. Delicate git state is therefore detected and injected
# into the contract, not used as a veto.
set -uo pipefail

CG_BIN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 0
# shellcheck source=lib.sh
. "$CG_BIN/lib.sh" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null || true)

cg_disabled && exit 0
cg_capture pre-compact "$payload"

sid=$(cg_field "$payload" .session_id)
cwd=$(cg_field "$payload" .cwd)
trigger=$(cg_field "$payload" .trigger .compaction_trigger)
# Kept with aliases in case a future version adds them, but as of 2.1.220 the real
# payload carries NO token counts at all -- verified against a live TRAE compaction.
tokens=$(cg_field "$payload" .estimated_tokens_before .tokens_before)

transcript=$(cg_field "$payload" .transcript_path)
tbytes=""
[ -n "$transcript" ] && [ -f "$transcript" ] &&
  tbytes=$(stat -f%z "$transcript" 2>/dev/null || printf '')

# transcript_bytes turned out to be USELESS as a drift proxy: measured 42MB and
# 582KB at the same arm point, because the file is the full historical log (tool
# results land there in full) while the live context is a fraction of it. Keep it
# as a rough size marker, but the real signal is the token count below.
#
# That means parsing the transcript JSONL -- an internal format that can change.
# It is bounded (tail only), wrapped so any failure yields null, and it is the ONLY
# source of truth available: the hook payload carries no token counts at all.
ctx=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  ctx=$(tail -n 300 "$transcript" 2>/dev/null | grep -F '"usage"' 2>/dev/null |
    "$CG_JQ" -rs '
      [ .[]? | select(.message?.usage != null)
        | ((.message.usage.input_tokens // 0)
         + (.message.usage.cache_read_input_tokens // 0)
         + (.message.usage.cache_creation_input_tokens // 0)) ]
      | if length == 0 then empty else max end' 2>/dev/null || printf '')
fi

[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD
branch=$(cg_branch "$cwd")
worktree=$(cg_worktree "$cwd")
head=$(cg_head "$cwd")
delicate=$(cg_git_delicate "$cwd")

contract=$(cat "$CG_HOME/contract.md" 2>/dev/null || true)
# With no contract there is nothing useful to say: emit nothing rather than
# handing the summariser a fragment.
[ -n "$contract" ] || exit 0

out=""
if [ -n "$delicate" ]; then
  step=""
  gd=$(cg_git_dir "$cwd")
  if [ -n "$gd" ] && [ -f "$gd/rebase-merge/msgnum" ]; then
    step=" (step $(cat "$gd/rebase-merge/msgnum" 2>/dev/null)/$(cat "$gd/rebase-merge/end" 2>/dev/null))"
  fi
  out=$(
    printf '## CRITICAL GIT STATE — preserve verbatim\n\n'
    printf 'There is a half-finished git operation in `%s`' "$cwd"
    printf ' (branch `%s`, HEAD `%s`)%s: %s.\n\n' "$branch" "$head" "$step" "$delicate"
    printf 'Preserve in the summary, literally: the exact step it stopped at, which\n'
    printf 'files are in conflict or half-applied, and what the next action is\n'
    printf '(continue, abort, or resolve). This state CANNOT be reconstructed by\n'
    printf 're-reading files, so it is the first thing that must survive.\n\n'
  )
fi

printf '%s%s\n' "$out" "$contract"

n=$(cg_bump "$sid")
cg_log "$(cg_json \
  --arg ts "$(cg_ts)" \
  --arg event pre_compact \
  --arg session_id "$sid" \
  --arg cwd "$cwd" \
  --arg branch "$branch" \
  --arg worktree "$worktree" \
  --arg head "$head" \
  --arg trigger "$trigger" \
  --argjson delicate "$(cg_arr "$delicate")" \
  --argjson tokens_before "$(cg_num "$tokens")" \
  --argjson transcript_bytes "$(cg_num "$tbytes")" \
  --argjson context_tokens "$(cg_num "$ctx")" \
  --argjson contract_bytes "$((${#out} + ${#contract}))" \
  --argjson n "$n")"

exit 0