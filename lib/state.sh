#!/usr/bin/env bash
# The per-tool state file.
#
# One schema, shared byte-for-byte with goselfupdate and pyselfupdate, so any
# tool can read any other tool's state and one dashboard can glob
# ~/.local/state/*/autoupdate.json with no per-tool knowledge.
#
# State, not config and not cache: it persists across runs, it is not authored
# by the user, and deleting it changes behaviour rather than merely costing a
# recompute. That is XDG_STATE_HOME by the Base Directory specification, and it
# is where gh puts the same thing.

BASHSELFUPDATE_SCHEMA=1

bashselfupdate_state_path() {
  local tool="$1"
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/${tool}/autoupdate.json"
}

# Echoes one field, or an empty string when the file is absent or unreadable.
#
# A corrupt file reads as empty rather than failing: the file is a throttle, and
# breaking a user's command because the throttle cannot be read would be worse
# than checking one extra time.
bashselfupdate_state_read() {
  local tool="$1" field="$2"
  local path
  path=$(bashselfupdate_state_path "$tool")

  [[ -f "$path" ]] || return 0
  jq -r --arg field "$field" '.[$field] // "" | tostring' "$path" 2>/dev/null || true
}

# Writes the state file, replacing it wholesale.
#
# Written to a temporary file in the same directory and renamed, so a reader
# sees either the whole previous file or the whole new one rather than a
# half-written mixture of the two.
#
# There is deliberately no "skip reason" field: a gate that declines to check
# does not write this file at all, which is what makes "no state file"
# observable proof that the network was never touched.
#
# Usage: bashselfupdate_state_write <tool> <current> <latest> <error>
bashselfupdate_state_write() {
  local tool="$1" current="${2:-}" latest="${3:-}" error="${4:-}"
  local path directory now epoch
  path=$(bashselfupdate_state_path "$tool")
  directory=$(dirname "$path")

  mkdir -p "$directory" 2>/dev/null || return 0

  epoch=$(date -u +%s)
  # -u and an explicit format rather than --iso-8601, which BSD date on macOS
  # does not have. The epoch field exists so nothing here ever has to parse one
  # back.
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local temporary="${directory}/.autoupdate.json.tmp.$$"
  if jq -n \
    --argjson schema "$BASHSELFUPDATE_SCHEMA" \
    --arg tool "$tool" \
    --arg checked_at "$now" \
    --argjson checked_at_epoch "$epoch" \
    --arg current_version "$current" \
    --arg latest_version "$latest" \
    --arg last_error "$error" \
    '{schema: $schema, tool: $tool, checked_at: $checked_at,
      checked_at_epoch: $checked_at_epoch, current_version: $current_version,
      latest_version: $latest_version, last_error: $last_error}' \
    >"$temporary" 2>/dev/null; then
    mv -f "$temporary" "$path" 2>/dev/null || rm -f "$temporary"
  else
    rm -f "$temporary"
  fi
  return 0
}

# True when the tool has not been checked within the interval.
#
# Reads checked_at_epoch rather than checked_at: BSD date on macOS cannot parse
# ISO-8601 without -j -f gymnastics, and that redundant field exists precisely
# so this comparison is one subtraction.
bashselfupdate_state_is_due() {
  local tool="$1" interval_seconds="$2"
  local last now
  last=$(bashselfupdate_state_read "$tool" checked_at_epoch)
  [[ -n "$last" && "$last" =~ ^[0-9]+$ ]] || return 0

  now=$(date -u +%s)
  ((now - last >= interval_seconds))
}
