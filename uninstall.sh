#!/usr/bin/env bash
# Remove context-guard.
#
#   ./uninstall.sh           un-wire the hooks and the threshold, keep the logs
#   ./uninstall.sh --purge   also delete the whole ~/.claude/context-guard tree
#   ./uninstall.sh --restore restore the most recent settings.json backup verbatim
#
# The default path surgically removes only what install.sh added, using jq on the
# live file, so anything else in settings.json is untouched. --restore is the
# blunt instrument for when you want the file exactly as it was.
set -uo pipefail

# Overridable so the test suite never risks --purge-ing the real tree.
CG_HOME="${CG_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
SETTINGS="$HOME/.claude/settings.json"
BACKUPS="$HOME/.claude/backups"
SKILLS="$HOME/.claude/skills"
JQ="${CG_JQ:-/usr/bin/jq}"
[ -x "$JQ" ] || JQ=$(command -v jq 2> /dev/null || echo /nonexistent)
PURGE=0
RESTORE=0

while [ $# -gt 0 ]; do
  case $1 in
  --purge) PURGE=1 ;;
  --restore) RESTORE=1 ;;
  -h | --help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
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

if [ "$RESTORE" = 1 ]; then
  last=$(ls -1t "$BACKUPS"/settings.json.*.bak 2> /dev/null | head -1)
  [ -n "$last" ] || die "no backups in $BACKUPS"
  "$JQ" -e . "$last" > /dev/null 2>&1 || die "backup $last is not valid JSON"
  cp "$SETTINGS" "$SETTINGS.pre-restore.bak"
  cp "$last" "$SETTINGS" || die "could not restore"
  printf 'restored from %s\n' "$last"
  printf '(the previous state was kept at %s.pre-restore.bak)\n' "$SETTINGS"
else
  # Safety net before the surgical edit, same as install.
  cp "$SETTINGS" "$BACKUPS/settings.json.$(date -u +%Y%m%dT%H%M%SZ).pre-uninstall.bak" 2> /dev/null

  tmp="$SETTINGS.cg.$$"
  "$JQ" '
    # By script basename, not by directory: a relocated CG_HOME would otherwise
    # leave our hooks wired up after an "successful" uninstall.
    def is_ours:
      test("/(pre-compact|post-compact|stop-progress)\\.sh$") or test("context-guard");
    def strip_cg:
      map(select([(.hooks // [])[] | .command // ""] | any(is_ours) | not));
    del(.autoCompactWindow)
    | if (.hooks | type) == "object" then
        .hooks |= with_entries(.value |= strip_cg)
        # Drop hook events left empty, and the hooks key itself if nothing remains.
        | .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
  ' "$SETTINGS" > "$tmp" || die "jq failed; $SETTINGS was left untouched"

  "$JQ" -e . "$tmp" > /dev/null 2>&1 || {
    rm -f "$tmp"
    die "invalid result; $SETTINGS was left untouched"
  }

  # Refuse to proceed if the permission list changed.
  b=$("$JQ" '.permissions.allow // [] | length' "$SETTINGS")
  a=$("$JQ" '.permissions.allow // [] | length' "$tmp")
  [ "$b" = "$a" ] || {
    rm -f "$tmp"
    die "permissions.allow changed ($b -> $a); aborting"
  }

  mv -f "$tmp" "$SETTINGS" || die "could not write $SETTINGS"
  printf 'removed from settings.json: autoCompactWindow and the context-guard hooks\n'
fi

# Remove the installed copy of the velador skill (the canonical one lives in
# the repo). Only the exact directory install.sh created.
if [ -f "$SKILLS/velador/SKILL.md" ]; then
  rm -rf "$SKILLS/velador"
  printf 'removed skill: %s/velador\n' "$SKILLS"
fi

"$JQ" -r '
  "  autoCompactWindow: \(.autoCompactWindow // "not set")",
  "  permissions.allow: \(.permissions.allow // [] | length) entries",
  "  hooks: \(if has("hooks") then (.hooks | keys | join(", ")) else "(none)" end)"
' "$SETTINGS"

if [ "$PURGE" = 1 ]; then
  # Say what is being destroyed before destroying it.
  n=$(cat "$CG_HOME/logs"/*.jsonl 2> /dev/null | wc -l | tr -d ' ')
  h=$(ls -1 "$CG_HOME/night"/handoff-*.md 2> /dev/null | wc -l | tr -d ' ')
  printf '\n--purge will delete %s: %s log line(s) and %s handoff(s).\n' "$CG_HOME" "$n" "$h"
  printf 'Ctrl-C within 5s to cancel.'
  for _ in 1 2 3 4 5; do
    sleep 1
    printf '.'
  done
  printf '\n'
  rm -rf "$CG_HOME" && printf 'deleted %s\n' "$CG_HOME"
else
  printf '\nlogs and handoffs kept at %s\n' "$CG_HOME"
  printf 'to delete them too: %s/uninstall.sh --purge\n' "$CG_HOME"
fi

printf '\nSessions already open keep the old config: open a new one.\n'