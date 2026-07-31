#!/usr/bin/env bash
# Shared helpers for the context-guard hooks.
#
# Sourced by every hook. The rule for everything in here: fail open. A problem
# with instrumentation must never block a compaction, stall a turn, or corrupt a
# session. Every function returns 0 and degrades to an empty value.
#
# CG_HOME is overridable so the test suite can run against a throwaway tree.
set -uo pipefail

CG_HOME="${CG_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CG_LOGS="$CG_HOME/logs"
# shellcheck disable=SC2034  # used by the hooks that source this file
CG_NIGHT="$CG_HOME/night"
CG_STATE="$CG_HOME/state"
CG_JQ="${CG_JQ:-/usr/bin/jq}"

[ -x "$CG_JQ" ] || CG_JQ=$(command -v jq 2>/dev/null || echo /nonexistent)

# --- switches ----------------------------------------------------------------

# touch $CG_HOME/disabled to make every hook a no-op, without editing settings.
cg_disabled() { [ -f "$CG_HOME/disabled" ]; }

# touch $CG_HOME/capture to record raw hook payloads. Used once, in Phase 1, to
# verify the real field names instead of trusting either the docs or the binary.
cg_capture_on() { [ -f "$CG_HOME/capture" ]; }

# --- payload -----------------------------------------------------------------

# Read the first field that is actually present. The docs and the binary
# disagree on several names (trigger vs compaction_trigger, tokens_before vs
# estimated_tokens_before), so every read lists its known aliases.
#   cg_field "$payload" .session_id
#   cg_field "$payload" .trigger .compaction_trigger
cg_field() {
  local payload=$1 expr="" f
  shift
  for f in "$@"; do
    [ -n "$expr" ] && expr="$expr // "
    expr="$expr$f"
  done
  printf '%s' "$payload" | "$CG_JQ" -r "($expr) // empty" 2>/dev/null || true
}

cg_capture() {
  local event=$1 payload=$2
  cg_capture_on || return 0
  mkdir -p "$CG_LOGS/payload-samples" 2>/dev/null
  local f
  f="$CG_LOGS/payload-samples/$event-$(cg_ts_file).json"
  printf '%s\n' "$payload" > "$f" 2>/dev/null
  chmod 600 "$f" 2>/dev/null
  return 0
}

# --- time --------------------------------------------------------------------

cg_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
cg_ts_file() { date -u +%Y%m%dT%H%M%SZ; }
cg_month() { date -u +%Y-%m; }

# --- logging -----------------------------------------------------------------

# Append one JSON line. A single printf of a sub-4KB line to an O_APPEND fd is
# atomic on macOS, so parallel sessions never interleave and no lock is needed.
cg_log() {
  local line=$1 file
  file="$CG_LOGS/$(cg_month).jsonl"
  mkdir -p "$CG_LOGS" 2>/dev/null
  printf '%s\n' "$line" >> "$file" 2>/dev/null
  chmod 600 "$file" 2>/dev/null
  return 0
}

# Build a compact JSON object via jq so values are always escaped correctly.
# Usage: cg_json --arg session_id "$sid" --argjson n 3
cg_json() { "$CG_JQ" -cn '$ARGS.named' "$@" 2>/dev/null || true; }

# A JSON number, or null when the field was absent or non-numeric. Never 0:
# a missing token count and a count of zero must not look the same in the audit.
cg_num() {
  case ${1:-} in
  '' | *[!0-9]*) printf 'null' ;;
  *) printf '%s' "$1" ;;
  esac
}

# A JSON array from a space-separated list. The empty case needs its own branch:
# `jq -R` reads lines, so empty input yields zero lines and NO output at all --
# it exits 0 while printing nothing, which would then make --argjson reject an
# empty string and take the whole log line down with it.
cg_arr() {
  local s=${1:-}
  [ -n "$s" ] || { printf '[]'; return 0; }
  out=$(printf '%s' "$s" | "$CG_JQ" -R 'split(" ") | map(select(length > 0))' 2>/dev/null)
  [ -n "$out" ] || out='[]'
  printf '%s' "$out"
}

# --- per-session counters ----------------------------------------------------

# One file per session id: no shared mutable state, so a busy session can never
# perturb another's count.
cg_bump() {
  local sid=$1 f n
  [ -n "$sid" ] || { printf '0'; return 0; }
  mkdir -p "$CG_STATE" 2>/dev/null
  f="$CG_STATE/compactions-$(cg_safe "$sid")"
  n=$(cat "$f" 2>/dev/null || printf '0')
  case $n in '' | *[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s' "$n" > "$f" 2>/dev/null
  printf '%s' "$n"
}

# Read the counter without advancing it: PreCompact owns the increment, so
# PostCompact reports the same n for the same compaction.
cg_peek() {
  local sid=$1 n
  [ -n "$sid" ] || { printf '0'; return 0; }
  n=$(cat "$CG_STATE/compactions-$(cg_safe "$sid")" 2>/dev/null || printf '0')
  case $n in '' | *[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Session ids are uuids, but never build a path from unvalidated input.
cg_safe() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }

# --- git ---------------------------------------------------------------------

cg_git_dir() {
  local dir=$1 gd
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  gd=$(git -C "$dir" rev-parse --git-dir 2>/dev/null) || return 0
  case $gd in
  /*) printf '%s' "$gd" ;;
  *) printf '%s/%s' "$dir" "$gd" ;;
  esac
}

# Which repo(s) to track for a given cwd. A session often sits at a workspace
# root that is NOT a repo itself -- several independent repos living side by
# side inside it. Returning nothing there would make the progress signature a
# constant, and the stall detector would cry STALLED while work was happening.
cg_repos() {
  local dir=$1 d
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  if git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
    printf '%s\n' "$dir"
    return 0
  fi
  for d in "$dir"/*/; do
    [ -d "${d}.git" ] || continue
    printf '%s\n' "${d%/}"
  done
}

cg_branch() { git -C "${1:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true; }
cg_head() { git -C "${1:-.}" rev-parse --short HEAD 2>/dev/null || true; }

cg_worktree() {
  local top
  top=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || return 0
  printf '%s' "${top##*/}"
}

# Git states that must survive a compaction verbatim, because they are the one
# thing that cannot be re-derived by re-reading files. Detected, never blocked:
# compaction only rewrites conversation memory between turns, so deferring it
# would not protect the rebase -- losing the note about it is the real risk.
cg_git_delicate() {
  local dir=$1 gd out="" m
  gd=$(cg_git_dir "$dir") || return 0
  [ -n "$gd" ] || return 0
  for m in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG index.lock; do
    [ -e "$gd/$m" ] && out="$out $m"
  done
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    out="$out REBASE_IN_PROGRESS"
  fi
  printf '%s' "${out# }"
}