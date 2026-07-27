#!/usr/bin/env bash
# Telling the user a newer release exists, and nothing else.
#
# This layer never updates. `<tool> update` updates, and `<tool> update` is
# where errors are printed; a failure here is recorded in the state file and
# swallowed. That single rule is what keeps a dev checkout from printing an
# upgrade failure on every invocation.

BASHSELFUPDATE_DEFAULT_INTERVAL=86400

# Whether a check may run at all, ignoring the interval.
#
# Echoes the skip reason and returns non-zero when it may not, so a caller can
# report why a tool has gone quiet. Returns 0 and echoes nothing when it may.
#
# Usage: bashselfupdate_enabled <tool> <dir>
bashselfupdate_enabled() {
  local tool="$1" directory="$2"
  local prefix
  prefix=$(_bashselfupdate_env_prefix "$tool")

  # Presence-only, any value including empty -- the NO_COLOR convention -- so
  # that NO_AUTO_UPDATE=0 cannot mean "on". ${VAR+x} is the only spelling of
  # "set, even to the empty string" in bash.
  if [[ -n ${NO_AUTO_UPDATE+x} ]] || eval "[[ -n \${${prefix}_NO_AUTO_UPDATE+x} ]]"; then
    echo disabled
    return 1
  fi

  # Both streams, so `tool list > out 2>&1` stays clean. `tool list | jq` is
  # also suppressed, which is the conservative reading and matches gh.
  #
  # BASHSELFUPDATE_INTERACTIVE overrides the detection: set it to 0 from a tool
  # that already knows it is writing somewhere a human will not read -- into a
  # pager, a log, a structured-output mode -- since nothing about the streams
  # themselves reveals that. It is also the only way to test the rest of this
  # gate, because allocating a pty requires a controlling terminal that neither
  # a test runner nor a CI step has.
  if ! _bashselfupdate_is_interactive; then
    echo not-a-tty
    return 1
  fi

  if [[ -n ${CI+x} || -n ${BUILD_NUMBER+x} || -n ${RUN_ID+x} || -n ${GITHUB_ACTIONS+x} || -n ${CODESPACES+x} ]]; then
    echo ci
    return 1
  fi

  # Failing closed: a checkout that cannot be read, or that sits on an untagged
  # commit, is treated as a dev checkout. A false negative here would print a
  # wrong notice on every command in a working copy.
  local current
  current=$(bashselfupdate_current_version "$directory" 2>/dev/null) || {
    echo dev-checkout
    return 1
  }
  if ! bashselfupdate_is_valid_version "$current"; then
    echo dev-checkout
    return 1
  fi

  return 0
}

# Checks at most once per interval and prints one line when behind.
#
# Never fails: the caller's command must not break because an update notice
# could not be produced. Always returns 0.
#
# Usage: bashselfupdate_notify <tool> <dir> [remote]
bashselfupdate_notify() {
  local tool="$1" directory="$2" remote="${3:-origin}"

  # The reason is discarded here; bashselfupdate_enabled exists so a *caller*
  # can report why a tool has gone quiet, and notify's whole contract is silence.
  if ! bashselfupdate_enabled "$tool" "$directory" >/dev/null; then
    return 0
  fi

  local interval
  interval=$(_bashselfupdate_interval "$tool")
  bashselfupdate_state_is_due "$tool" "$interval" || return 0

  local current
  current=$(bashselfupdate_current_version "$directory" 2>/dev/null) || return 0

  # Stamped before the network call, not after. gh stamps only on success, so a
  # rate-limited or offline user retries on every single invocation until the
  # window resets. An interval exists to bound the request rate, and only this
  # ordering actually does that.
  bashselfupdate_state_write "$tool" "$current" "" ""

  local latest
  if ! latest=$(bashselfupdate_latest_tag "$directory" "$remote" 2>/dev/null) || [[ -z "$latest" ]]; then
    bashselfupdate_state_write "$tool" "$current" "" "could not read tags from $remote"
    return 0
  fi

  bashselfupdate_state_write "$tool" "$current" "$latest" ""

  if [[ "$(bashselfupdate_compare_versions "$latest" "$current")" == "1" ]]; then
    # The backticked command is built here rather than inlined in the format
    # string: single quotes are correct for a printf format, but shellcheck reads
    # the backticks inside them as an unexpanded command substitution (SC2016).
    local suggestion="\`${tool} update\`"
    printf '%s %s available (running %s) — run %s\n' "$tool" "$latest" "$current" "$suggestion" >&2
  fi
  return 0
}

_bashselfupdate_is_interactive() {
  case "${BASHSELFUPDATE_INTERACTIVE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -t 1 && -t 2 ]]
}

_bashselfupdate_env_prefix() {
  local tool="$1"
  tool="${tool//-/_}"
  echo "${tool^^}"
}

# Seconds between checks. A per-tool variable outranks the fleet one, and both
# accept 30s, 45m, 12h, 7d or a bare number of seconds.
_bashselfupdate_interval() {
  local tool="$1"
  local prefix raw parsed
  prefix=$(_bashselfupdate_env_prefix "$tool")

  raw=$(eval "echo \${${prefix}_AUTO_UPDATE_INTERVAL:-}")
  [[ -n "$raw" ]] || raw="${AUTO_UPDATE_INTERVAL:-}"
  [[ -n "$raw" ]] || {
    echo "$BASHSELFUPDATE_DEFAULT_INTERVAL"
    return 0
  }

  if parsed=$(_bashselfupdate_parse_interval "$raw"); then
    echo "$parsed"
  else
    echo "$BASHSELFUPDATE_DEFAULT_INTERVAL"
  fi
}

_bashselfupdate_parse_interval() {
  local raw="${1,,}"
  local number="${raw%[smhd]}"
  local unit="${raw:${#number}}"

  [[ "$number" =~ ^[0-9]+$ ]] || return 1

  case "$unit" in
    s | '') echo "$number" ;;
    m) echo $((number * 60)) ;;
    h) echo $((number * 3600)) ;;
    d) echo $((number * 86400)) ;;
    *) return 1 ;;
  esac
}
