#!/usr/bin/env bash
# Wire context-guard into ~/.claude/settings.json.
#
#   ./install.sh            install (or re-install) everything
#   ./install.sh --capture  same, plus record the raw hook payloads so the real
#                           field names can be verified (docs and binary disagree).
#                           Additive: the hooks still do their normal job.
#   ./install.sh --repair   re-wire the hooks, leaving the threshold as it is
#   ./install.sh --window N use N instead of the calibrated default 473000
#
# The settings file being edited may hold permission entries, the model, the
# effort level and anything else the user configured, so it is backed up first
# and then merged with jq on the existing object -- never rewritten. Any
# pre-existing hook from something else is kept:
# only entries pointing at context-guard are replaced, which makes this
# idempotent.
set -uo pipefail

# Overridable so the test suite can point at a throwaway tree. Without this the
# script would mutate the real install (flags, chmod) even when driven with a fake
# HOME, which is how a test run silently cleared capture mode once.
CG_HOME="${CG_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
SETTINGS="$HOME/.claude/settings.json"
BACKUPS="$HOME/.claude/backups"
SKILLS="$HOME/.claude/skills"
JQ="${CG_JQ:-/usr/bin/jq}"
[ -x "$JQ" ] || JQ=$(command -v jq 2> /dev/null || echo /nonexistent)
WINDOW=473000  # calibrated against measured production behavior (2026-07-30), not the binary's formula
CAPTURE=0
REPAIR=0

while [ $# -gt 0 ]; do
  case $1 in
  --capture) CAPTURE=1 ;;
  --repair) REPAIR=1 ;;
  --window)
    shift
    WINDOW=${1:-473000}
    ;;
  -h | --help)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  esac
  shift
done

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

[ -x "$JQ" ] || die "jq not found (looked at $JQ and in PATH)"
[ -f "$SETTINGS" ] || die "$SETTINGS does not exist"
"$JQ" -e . "$SETTINGS" > /dev/null 2>&1 || die "$SETTINGS is not valid JSON; touching nothing"

case $WINDOW in '' | *[!0-9]*) die "--window must be an integer" ;; esac
if [ "$WINDOW" -lt 100000 ] || [ "$WINDOW" -gt 1000000 ]; then
  die "--window outside the range the schema accepts: [100000, 1000000]"
fi

chmod +x "$CG_HOME"/bin/*.sh "$CG_HOME"/tests/*.sh 2> /dev/null
mkdir -p "$CG_HOME"/{logs,state,night} "$BACKUPS" 2> /dev/null
chmod 700 "$CG_HOME"/{logs,state,night} 2> /dev/null

# The velador skill (autonomous runs) ships in the repo but Claude Code loads
# skills from ~/.claude/skills, so it is copied there. A copy, not a symlink:
# some hosts resolve skill dirs without following links. --repair re-copies.
if [ -f "$CG_HOME/skills/velador/SKILL.md" ]; then
  mkdir -p "$SKILLS/velador" 2> /dev/null
  cp "$CG_HOME/skills/velador/SKILL.md" "$SKILLS/velador/SKILL.md" ||
    die "could not copy the velador skill to $SKILLS/velador"
fi

# --- what the settings looked like before, so the merge can be proven safe ----
before_perms=$("$JQ" '[.permissions.allow // [] | length] | first' "$SETTINGS")
before_model=$("$JQ" -r '.model // "unset"' "$SETTINGS")
before_effort=$("$JQ" -r '.effortLevel // "unset"' "$SETTINGS")
before_keys=$("$JQ" -r 'keys | join(",")' "$SETTINGS")

BACKUP="$BACKUPS/settings.json.$(date -u +%Y%m%dT%H%M%SZ).bak"
cp "$SETTINGS" "$BACKUP" || die "could not back up to $BACKUP"
printf 'backup: %s\n' "$BACKUP"

# --- merge --------------------------------------------------------------------
tmp="$SETTINGS.cg.$$"
"$JQ" \
  --argjson window "$WINDOW" \
  --arg bin "$CG_HOME/bin" \
  --argjson repair "$REPAIR" '
  # Drop only our own entries, so hooks installed by anything else survive.
  # Identified by script basename, not by the directory: matching "context-guard"
  # in the path would silently fail to find them if CG_HOME is relocated, and
  # uninstall would leave dead hooks wired up.
  def is_ours:
    test("/(pre-compact|post-compact|stop-progress)\\.sh$") or test("context-guard");
  def strip_cg:
    map(select([(.hooks // [])[] | .command // ""] | any(is_ours) | not));
  def entry($script; $t):
    { matcher: "*",
      hooks: [ { type: "command", command: ($bin + "/" + $script), timeout: $t } ] };

  (if $repair == 1 then . else .autoCompactWindow = $window end)
  | .hooks = ((.hooks // {})
      | .PreCompact  = (((.PreCompact  // []) | strip_cg) + [entry("pre-compact.sh"; 20)])
      | .PostCompact = (((.PostCompact // []) | strip_cg) + [entry("post-compact.sh"; 20)])
      | .Stop        = (((.Stop        // []) | strip_cg) + [entry("stop-progress.sh"; 15)]))
' "$SETTINGS" > "$tmp" || die "the jq merge failed; $SETTINGS was left untouched"

"$JQ" -e . "$tmp" > /dev/null 2>&1 || {
  rm -f "$tmp"
  die "the result is not valid JSON; $SETTINGS was left untouched"
}

# --- prove nothing was lost before committing the change ----------------------
after_perms=$("$JQ" '[.permissions.allow // [] | length] | first' "$tmp")
after_model=$("$JQ" -r '.model // "unset"' "$tmp")
after_effort=$("$JQ" -r '.effortLevel // "unset"' "$tmp")

[ "$before_perms" = "$after_perms" ] ||
  {
    rm -f "$tmp"
    die "permissions.allow changed from $before_perms to $after_perms; aborting"
  }
[ "$before_model" = "$after_model" ] || {
  rm -f "$tmp"
  die "model changed; aborting"
}
[ "$before_effort" = "$after_effort" ] || {
  rm -f "$tmp"
  die "effortLevel changed; aborting"
}

# Every key that existed must still exist.
for k in ${before_keys//,/ }; do
  "$JQ" -e --arg k "$k" 'has($k)' "$tmp" > /dev/null 2>&1 ||
    {
      rm -f "$tmp"
      die "key '$k' was lost; aborting"
    }
done

mv -f "$tmp" "$SETTINGS" || die "could not write $SETTINGS"

# --- capture mode -------------------------------------------------------------
if [ "$CAPTURE" = 1 ]; then
  touch "$CG_HOME/capture"
  printf '\nCAPTURE MODE active.\n'
  printf 'The hooks will record raw payloads in logs/payload-samples/.\n'
  printf 'Run /compact in your Claude Code panel, then:\n'
  printf '  ls %s/logs/payload-samples/\n' "$CG_HOME"
  printf '  rm %s/capture    # to leave capture mode\n' "$CG_HOME"
else
  rm -f "$CG_HOME/capture"
fi

# --- report -------------------------------------------------------------------
printf '\nsettings.json:\n'
"$JQ" -r '
  "  autoCompactWindow: \(.autoCompactWindow // "not set")",
  "  permissions.allow: \(.permissions.allow // [] | length) entries (intact)",
  "  model: \(.model // "unset")  effortLevel: \(.effortLevel // "unset")",
  "  hooks: \(.hooks | keys | join(", "))"
' "$SETTINGS"

w=$("$JQ" -r '.autoCompactWindow // 1000000' "$SETTINGS")
# The MEASURED model, not the binary's formula: in production the reactive term
# `effWindow - 13000` wins, because the remotely-served fraction is ~0 rather
# than the 0.2 local fallback. Measured 2026-07-30: window=570000 compacted at
# 534878 and 536796 across two independent sessions.
printf '\nexpected arm point: ~%s tokens (on a 1M model, measured)\n' "$((w - 20000 - 13000))"
printf '\nkill switch:  touch %s/disabled\n' "$CG_HOME"
printf 'uninstall:    %s/uninstall.sh\n' "$CG_HOME"
printf 'audit:        %s/bin/cg-status.sh\n' "$CG_HOME"
printf '\nNOTE: hooks and the threshold are read when a session STARTS.\n'
printf 'Conversations already open in your IDE keep the old config: open a new one.\n'