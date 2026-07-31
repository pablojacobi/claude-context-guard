#!/usr/bin/env bash
# Canary for the compaction threshold formula.
#
# The formula was read out of the bundled binary (2.1.220):
#
#   effWindow = min(modelMax, autoCompactWindow) - min(maxOutputTokens, 20000)
#   armPoint  = min(effWindow * (1 - bufferFraction), effWindow - 13000)
#
# Two of those constants are not ours to control: bufferFraction defaults to 0.2
# but is served by remote config (gates tengu_amber_rokovoko / _moleskin), and
# the whole mechanism is undocumented publicly. This script does not prove the
# threshold is right -- it pins what we BELIEVE, so a version bump or a remote
# change shows up as a failing assertion instead of a silent surprise. The
# empirical check is tokens_before in the log; see cg-status.sh.
set -uo pipefail

RESERVE=20000     # min(maxOutputTokens, 20000) -- 20000 for every 1M model
BLOCK_GAP=13000   # effWindow - 13000 clamp
BUFFER_PCT=20     # (1 - 0.2)
MIN_PROACTIVE=200000  # bRe: below this, the proactive path is disabled entirely

JQ="${CG_JQ:-/usr/bin/jq}"
[ -x "$JQ" ] || JQ=$(command -v jq 2>/dev/null || echo /nonexistent)

pass=0 fail=0

arm() { # arm <autoCompactWindow> <modelMax> -- the formula as read from the binary
  local w=$1 m=$2 eff a b
  eff=$(((w < m ? w : m) - RESERVE))
  a=$((eff * (100 - BUFFER_PCT) / 100))
  b=$((eff - BLOCK_GAP))
  printf '%s' "$((a < b ? a : b))"
}

# MEASURED behaviour, 2026-07-30, two independent production sessions:
#   window=570000 -> compacted at 534878 and 536796 tokens
# That is, the `eff - 13000` term (537000) wins, not `eff * 0.8` (440000).
# The 0.2 fraction the binary ships as a fallback is NOT what the service
# serves: it comes from remote config (tengu_amber_rokovoko / _moleskin) and in
# practice is ~0. Calibrate against this, not the optimistic formula.
arm_measured() { # arm_measured <autoCompactWindow> <modelMax>
  local w=$1 m=$2 eff
  eff=$(((w < m ? w : m) - RESERVE))
  printf '%s' "$((eff - BLOCK_GAP))"
}

expect() { # expect <label> <actual> <wanted>
  if [ "$2" = "$3" ]; then
    printf '  ok    %-46s %s\n' "$1" "$2"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-46s %s (expected %s)\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

printf '== Arm-point formula ==\n'
expect 'window=570000 model=1M  -> target' "$(arm 570000 1000000)" 440000
expect 'window=570000 model=200K -> min() bounds it' "$(arm 570000 200000)" 144000
expect 'window=200000 model=1M  -> Phase 3 test' "$(arm 200000 1000000)" 144000
expect 'window=1000000 model=1M -> status quo' "$(arm 1000000 1000000)" 784000

printf '\n== MEASURED model (the one that rules) ==\n'
expect 'window=570000 -> observed in production' "$(arm_measured 570000 1000000)" 537000
printf '        production measured 534878 and 536796 across two sessions\n'
expect 'window=473000 -> calibrated to the target' "$(arm_measured 473000 1000000)" 440000

printf '\n== Target band 425K-450K, under the measured model ==\n'
a=$(arm_measured 473000 1000000)
if [ "$a" -ge 425000 ] && [ "$a" -le 450000 ]; then
  printf '  ok    %s inside [425000, 450000]\n' "$a"
  pass=$((pass + 1))
else
  printf '  FAIL  %s OUTSIDE [425000, 450000]\n' "$a"
  fail=$((fail + 1))
fi
# If the remote fraction went back to 0.2 the point drops to 362400: more
# aggressive than the target, never laxer. The calibration fails safe.
printf '  note  if the remote fraction returned to 0.2: %s (more aggressive, not less)\n' \
  "$(arm 473000 1000000)"

printf '\n== Guards ==\n'
if [ 570000 -ge "$MIN_PROACTIVE" ]; then
  printf '  ok    570000 >= bRe(%s): proactive path enabled\n' "$MIN_PROACTIVE"
  pass=$((pass + 1))
else
  printf '  FAIL  570000 < bRe(%s)\n' "$MIN_PROACTIVE"
  fail=$((fail + 1))
fi
printf '  note  100000 < bRe(%s): do NOT use it to test the proactive path;\n' "$MIN_PROACTIVE"
printf '        you would test the reactive fallback while believing otherwise.\n'

printf '\n== Actually configured value ==\n'
s="$HOME/.claude/settings.json"
if [ -f "$s" ] && [ -x "$JQ" ]; then
  w=$("$JQ" -r '.autoCompactWindow // "auto"' "$s" 2>/dev/null)
  if [ "$w" = auto ] || [ "$w" = null ]; then
    printf '  autoCompactWindow not set -> arms at %s (status quo)\n' "$(arm 1000000 1000000)"
  else
    printf "  autoCompactWindow=%s -> arms at ~%s (measured model)\n" "$w" "$(arm_measured "$w" 1000000)"
  fi
else
  printf '  (no settings.json)\n'
fi
if [ -n "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ]; then
  printf '  ATTENTION: CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s takes PRECEDENCE over settings\n' \
    "$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
fi

printf '\n%s ok, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]