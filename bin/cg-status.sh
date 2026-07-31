#!/usr/bin/env bash
# Read-only audit report. Touches nothing; safe to run at any time.
#
# Answers the three questions the logs exist to answer:
#   1. Is the arm point still where we configured it? (drift in the remote fraction)
#   2. How much is each session compacting, independently of the others?
#   3. Are two agents pointed at the same checkout right now?
set -uo pipefail

CG_BIN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$CG_BIN/lib.sh"

WINDOW=${CG_WINDOW:-473000}
HOURS=${CG_HOURS:-24}
# The MEASURED model: in production the reactive term `effWindow - 13000` wins,
# not the binary's `* 0.8` (the remotely-served fraction is ~0). Measured
# 2026-07-30 across two sessions: 534878 and 536796.
EXPECTED=$((WINDOW - 20000 - 13000))

logs=$(ls -1 "$CG_LOGS"/*.jsonl 2>/dev/null || true)
if [ -z "$logs" ]; then
  printf 'No logs yet in %s\n' "$CG_LOGS"
  printf 'If you expected events: is %s/disabled present?\n' "$CG_HOME"
  exit 0
fi

printf '== Configured threshold ==\n'
printf 'autoCompactWindow = %s  ->  expected arm point ~%s tokens\n\n' "$WINDOW" "$EXPECTED"

printf '== Compactions per session (last %sh) ==\n' "$HOURS"
# Iniciadas y completadas se cuentan aparte: una compactación que arrancó y no
# cerró es justamente la señal de que el mecanismo falló, y colapsarlas en un
# solo número la escondería.
# shellcheck disable=SC2086
cat $logs 2>/dev/null | "$CG_JQ" -rs --argjson h "$HOURS" '
  (now - ($h * 3600)) as $cut
  | map(select((.ts // "" | fromdateiso8601? // 0) >= $cut))
  | map(select(.event == "post_compact" or .event == "pre_compact"))
  | group_by(.session_id)
  | map({
      sid: (.[0].session_id // "?" | .[0:12]),
      cwd: ([.[] | .cwd // empty] | last // "?"),
      branch: ([.[] | select((.branch // "") != "") | .branch] | last // "?"),
      started: ([.[] | select(.event == "pre_compact")] | length),
      done: ([.[] | select(.event == "post_compact")] | length),
      before: ([.[] | select(.event == "post_compact") | .tokens_before // empty]),
      saved: ([.[] | select(.event == "post_compact") | .tokens_saved // empty])
    })
  | sort_by(-.started)
  | if length == 0 then "  (no events in the window)" else
      .[] | "  \(.sid)  started=\(.started) completed=\(.done)  \(.branch)  \(.cwd)"
        + (if .started > .done
           then "\n           NOTE: \(.started - .done) unfinished; PostCompact failed,"
                + " or a manual /compact was cancelled by the user."
           else "" end)
        + (if (.before | length) > 0
           then "\n           tokens_before: \(.before | join(", "))"
                + "  saved: \(.saved | join(", "))"
           else "" end)
    end
' 2>/dev/null || printf '  (could not aggregate the log)\n'

printf '\n== Arm-point drift ==\n'
# shellcheck disable=SC2086
# context_tokens is written by PRE_compact (the peak before summarising), not post.
# The payload carries no token counts: it comes from reading the transcript usage.
# Judged by the MOST RECENT value, not the average: after a threshold change,
# sessions with different frozen configs coexist, and averaging them against a
# single expected value fabricates false deviations (happened 2026-07-30: 537K
# and 440K averaged screamed "10% off" with both nailed to their own target).
cat $logs 2>/dev/null | "$CG_JQ" -rs --argjson exp "$EXPECTED" '
  [ .[] | select(.event == "pre_compact" and .trigger == "auto")
        | {ts, v: ((.context_tokens // .tokens_before) // empty)}
        | select(.v != null) ]
  | if length == 0 then
      "  (no automatic compaction with a token measurement yet)"
    else
      sort_by(.ts) as $s | ($s | last | .v) as $cur
      | "  series: " + ($s | map(.v | tostring) | join(", "))
        + "\n  last=\($cur)  expected=\($exp)  deviation=\((($cur - $exp) / $exp * 100) | floor)%"
        + " (older sessions may carry a previous threshold, frozen at start)"
        + (if ((($cur - $exp) / $exp) | fabs) > 0.05
           then "\n  ATTENTION: the LAST compaction deviates >5% from expected;"
                + " if that session started under the current threshold, the remote fraction moved."
           else "" end)
    end
' 2>/dev/null || printf '  (could not compute)\n'

printf '\n== Live IDE sessions ==\n'
found=0
for f in "$HOME"/.claude/ide/*.lock; do
  [ -f "$f" ] || continue
  found=1
  # Only pid / ideName / workspaceFolders. The lock also holds an auth token for
  # the loopback IDE server, which must never be echoed anywhere.
  "$CG_JQ" -r '"  pid=\(.pid)  \(.ideName // "?")  \(.workspaceFolders | join(", "))"' \
    "$f" 2>/dev/null || true
done
[ "$found" = 1 ] || printf '  (none)\n'

printf '\n== Checkout collisions ==\n'
# shellcheck disable=SC2086
cat $logs 2>/dev/null | "$CG_JQ" -rs --argjson h "$HOURS" '
  (now - ($h * 3600)) as $cut
  | map(select((.ts // "" | fromdateiso8601? // 0) >= $cut))
  | map(select((.cwd // "") != "" and (.session_id // "") != ""))
  | group_by(.cwd)
  | map(select(([.[].session_id] | unique | length) > 1))
  | if length == 0 then "  (none: each session in its own checkout)" else
      .[] | "  NOTICE  \(.[0].cwd)\n          shared by: "
            + ([.[].session_id] | unique | map(.[0:12]) | join(", "))
            + "\n          Use separate worktrees: two agents in the same checkout"
            + " trample the same git index."
    end
' 2>/dev/null || printf '  (could not compute)\n'

printf '\n== Per-session handoffs (always on) ==\n'
found=0
for f in "$CG_NIGHT"/handoff-*.md; do
  [ -f "$f" ] || continue
  found=1
  printf '  %s  (%s)' "${f##*/}" "$(date -r "$f" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  head -1 "$f" 2>/dev/null | grep -q STALLED && printf '  <- STALLED'
  printf '\n'
done
[ "$found" = 1 ] || printf '  (none)\n'
printf '  retention: 14 days; global kill switch: touch %s/disabled\n' "$CG_HOME"