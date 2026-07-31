#!/usr/bin/env bash
# PostCompact hook: records what the compaction actually cost and saved.
#
# This is the only place that produces falsifiable evidence about the arm point.
# The 0.2 buffer fraction that decides when compaction fires comes from remote
# config, so it can move without anything changing locally. Comparing the logged
# tokens_before against the expected 440,000 is the only way to notice.
#
# PostCompact cannot block anything; its output is informational, so unlike
# pre-compact.sh there is no stdout discipline to keep here.
set -uo pipefail

CG_BIN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 0
# shellcheck source=lib.sh
. "$CG_BIN/lib.sh" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null || true)

cg_disabled && exit 0
cg_capture post-compact "$payload"

sid=$(cg_field "$payload" .session_id)
cwd=$(cg_field "$payload" .cwd)
trigger=$(cg_field "$payload" .trigger .compaction_trigger)
before=$(cg_field "$payload" .tokens_before .estimated_tokens_before)
after=$(cg_field "$payload" .tokens_after .estimated_tokens_after)
saved=$(cg_field "$payload" .tokens_saved)

# Derive the saving when the payload reports only the endpoints.
if [ -z "$saved" ] && [ "$(cg_num "$before")" != null ] && [ "$(cg_num "$after")" != null ]; then
  saved=$((before - after))
  [ "$saved" -ge 0 ] || saved=""
fi

[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD

# The payload carries the summary itself in `compact_summary` (verified against a
# real TRAE compaction), so the contract can be checked directly -- no transcript
# parsing, no undocumented format to depend on. This is what caught the contract
# silently not being applied in the first place, so it stays on by default.
summary=$(cg_field "$payload" .compact_summary)
markers=""
sbytes=""
if [ -n "$summary" ]; then
  sbytes=${#summary}
  # grep -c already prints 0 when it finds nothing (and exits 1), so a `|| printf 0`
  # would append a second zero and make the field unparseable. Normalise instead.
  # The two sections the contract ADDS to the built-in template. Detecting these,
  # rather than the template's own section names, is what makes the check mean
  # "the contract was applied" instead of "a compaction happened".
  markers=$(printf '%s' "$summary" |
    grep -c -E 'Decisions and Rationale|Repo State' 2>/dev/null)
  case $markers in '' | *[!0-9]*) markers=0 ;; esac
fi

cg_log "$(cg_json \
  --arg ts "$(cg_ts)" \
  --arg event post_compact \
  --arg session_id "$sid" \
  --arg cwd "$cwd" \
  --arg branch "$(cg_branch "$cwd")" \
  --arg worktree "$(cg_worktree "$cwd")" \
  --arg trigger "$trigger" \
  --argjson tokens_before "$(cg_num "$before")" \
  --argjson tokens_after "$(cg_num "$after")" \
  --argjson tokens_saved "$(cg_num "$saved")" \
  --argjson contract_markers "$(cg_num "$markers")" \
  --argjson summary_bytes "$(cg_num "$sbytes")" \
  --argjson n "$(cg_peek "$sid")")"

exit 0