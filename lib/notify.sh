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
# Note that the terminal check reads *this* call's stdout. Capturing the reason
# with $(...) therefore reports not-a-tty, because a command substitution is a
# pipe -- ask about a tool that has gone quiet from a terminal, or set
# BASHSELFUPDATE_INTERACTIVE to state the answer.
#
# Usage: bashselfupdate_enabled <tool> <dir>
bashselfupdate_enabled() {
  if _bashselfupdate_gate "$1" "$2"; then
    return 0
  fi
  echo "$BASHSELFUPDATE_SKIP_REASON"
  return 1
}

# The gate itself. Sets BASHSELFUPDATE_SKIP_REASON and returns non-zero when a
# check may not run; prints nothing.
#
# Separate from bashselfupdate_enabled because printing and gating cannot share
# one function. notify has to discard the reason, and the only ways to discard a
# function's stdout -- `>/dev/null` or `$(...)` -- both replace stdout, which is
# exactly what the terminal check below reads. notify redirecting the reason
# away therefore made its own gate answer not-a-tty every time, so notify never
# printed anything unless BASHSELFUPDATE_INTERACTIVE was set. Every test set it,
# which is why the suite was green through it.
_bashselfupdate_gate() {
  local tool="$1" directory="$2"
  local prefix
  prefix=$(_bashselfupdate_env_prefix "$tool")
  BASHSELFUPDATE_SKIP_REASON=""

  # Presence-only, any value including empty -- the NO_COLOR convention -- so
  # that NO_AUTO_UPDATE=0 cannot mean "on". ${VAR+x} is the only spelling of
  # "set, even to the empty string" in bash.
  if [[ -n ${NO_AUTO_UPDATE+x} ]] || eval "[[ -n \${${prefix}_NO_AUTO_UPDATE+x} ]]"; then
    BASHSELFUPDATE_SKIP_REASON=disabled
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
    BASHSELFUPDATE_SKIP_REASON=not-a-tty
    return 1
  fi

  if [[ -n ${CI+x} || -n ${BUILD_NUMBER+x} || -n ${RUN_ID+x} || -n ${GITHUB_ACTIONS+x} || -n ${CODESPACES+x} ]]; then
    BASHSELFUPDATE_SKIP_REASON=ci
    return 1
  fi

  # Failing closed: a checkout that cannot be read, or that sits on an untagged
  # commit, is treated as a dev checkout. A false negative here would print a
  # wrong notice on every command in a working copy.
  local current
  current=$(bashselfupdate_current_version "$directory" 2>/dev/null) || {
    BASHSELFUPDATE_SKIP_REASON=dev-checkout
    return 1
  }
  if ! bashselfupdate_is_valid_version "$current"; then
    BASHSELFUPDATE_SKIP_REASON=dev-checkout
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

  # _bashselfupdate_gate, not bashselfupdate_enabled: the gate has to be
  # evaluated against this caller's stdout, and any way of discarding the
  # reason bashselfupdate_enabled prints would replace it. See the note there.
  if ! _bashselfupdate_gate "$tool" "$directory"; then
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

# Case conversion via tr rather than the parameter expansion that does it in
# one step: that expansion is bash 4.0+, and macOS ships bash 3.2 and always
# will -- so a stranger on a stock Mac would get "bad substitution" on every
# invocation. The siblings keep a deliberately low floor for the same reason;
# this is bash's version of that. See CLAUDE.md for the exact forms to avoid.
_bashselfupdate_env_prefix() {
  local tool="$1"
  tool="${tool//-/_}"
  printf '%s' "$tool" | tr '[:lower:]' '[:upper:]'
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
  local raw
  raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
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
