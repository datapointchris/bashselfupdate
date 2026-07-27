#!/usr/bin/env bash
# Semantic version comparison.
#
# Implemented here rather than shelled out to `sort -V`, which implements GNU
# version sort rather than semver: it orders 1.0.0-rc.1 *above* 1.0.0, where the
# specification puts a pre-release below the release it precedes. BSD sort on
# macOS does not have -V at all. Precedence follows https://semver.org section
# 11, matching goselfupdate's semver.go and pyselfupdate's version.py so that
# the three never disagree about which of two releases is newer.
#
# Sourced, never executed: no `set -euo pipefail` here, because that would
# impose this file's error handling on whatever sources it.

# A version, with an optional leading v and one to three numeric components.
# Build metadata is accepted and ignored; a pre-release is validated.
bashselfupdate_is_valid_version() {
  local text="${1#v}"
  [[ -n "$text" ]] || return 1

  text="${text%%+*}"

  local prerelease=""
  if [[ "$text" == *-* ]]; then
    prerelease="${text#*-}"
    text="${text%%-*}"
    _bashselfupdate_is_valid_prerelease "$prerelease" || return 1
  fi

  [[ "$text" =~ ^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]] || return 1

  # Leading zeros are disallowed by the specification, so 01.2.3 is not a
  # version. Checked per component because the pattern above cannot express it.
  local component
  local IFS='.'
  for component in $text; do
    [[ "${#component}" -gt 1 && "${component:0:1}" == "0" ]] && return 1
  done
  return 0
}

# True when a version carries a pre-release identifier.
#
# Build metadata is stripped first: 1.2.3+build-5 has a hyphen but no
# pre-release, and treating it as one would hide a real release.
bashselfupdate_is_prerelease() {
  local text="${1#v}"
  text="${text%%+*}"
  [[ "$text" == *-* ]]
}

_bashselfupdate_is_valid_prerelease() {
  local prerelease="$1"
  [[ -n "$prerelease" ]] || return 1

  local identifier
  local IFS='.'
  for identifier in $prerelease; do
    [[ -n "$identifier" ]] || return 1
    [[ "$identifier" =~ ^[0-9A-Za-z-]+$ ]] || return 1
    if [[ "$identifier" =~ ^[0-9]+$ && "${#identifier}" -gt 1 && "${identifier:0:1}" == "0" ]]; then
      return 1
    fi
  done
  return 0
}

# Echoes -1, 0 or 1 as $1 is less than, equal to, or greater than $2.
# Invalid versions sort below valid ones.
bashselfupdate_compare_versions() {
  local left="${1#v}" right="${2#v}"
  local left_valid=0 right_valid=0

  bashselfupdate_is_valid_version "$1" && left_valid=1
  bashselfupdate_is_valid_version "$2" && right_valid=1

  if [[ "$left_valid" -eq 0 && "$right_valid" -eq 0 ]]; then
    echo 0
    return 0
  fi
  if [[ "$left_valid" -eq 0 ]]; then
    echo -1
    return 0
  fi
  if [[ "$right_valid" -eq 0 ]]; then
    echo 1
    return 0
  fi

  local left_core="${left%%+*}" right_core="${right%%+*}"
  local left_pre="" right_pre=""
  [[ "$left_core" == *-* ]] && left_pre="${left_core#*-}" && left_core="${left_core%%-*}"
  [[ "$right_core" == *-* ]] && right_pre="${right_core#*-}" && right_core="${right_core%%-*}"

  local index
  for index in 1 2 3; do
    local left_part right_part
    left_part=$(_bashselfupdate_field "$left_core" "$index")
    right_part=$(_bashselfupdate_field "$right_core" "$index")
    if ((left_part < right_part)); then
      echo -1
      return 0
    fi
    if ((left_part > right_part)); then
      echo 1
      return 0
    fi
  done

  _bashselfupdate_compare_prerelease "$left_pre" "$right_pre"
}

# The Nth dot-separated component of a core version, or 0 when absent, so that
# "1.2" and "1.2.0" compare equal.
_bashselfupdate_field() {
  local value="$1" position="$2"
  local field
  field=$(cut -d. -f"$position" <<<"$value")
  [[ -n "$field" ]] || field=0
  echo "$field"
}

# A version with a pre-release ranks below the same version without one,
# numeric identifiers compare numerically and rank below alphanumeric ones, and
# where all preceding identifiers are equal the longer list wins.
_bashselfupdate_compare_prerelease() {
  local left="$1" right="$2"

  [[ "$left" == "$right" ]] && {
    echo 0
    return 0
  }
  [[ -z "$left" ]] && {
    echo 1
    return 0
  }
  [[ -z "$right" ]] && {
    echo -1
    return 0
  }

  local -a left_parts right_parts
  IFS='.' read -r -a left_parts <<<"$left"
  IFS='.' read -r -a right_parts <<<"$right"

  local shortest=${#left_parts[@]}
  ((${#right_parts[@]} < shortest)) && shortest=${#right_parts[@]}

  local index result
  for ((index = 0; index < shortest; index++)); do
    result=$(_bashselfupdate_compare_identifier "${left_parts[index]}" "${right_parts[index]}")
    if [[ "$result" != "0" ]]; then
      echo "$result"
      return 0
    fi
  done

  if ((${#left_parts[@]} < ${#right_parts[@]})); then
    echo -1
  elif ((${#left_parts[@]} > ${#right_parts[@]})); then
    echo 1
  else
    echo 0
  fi
}

_bashselfupdate_compare_identifier() {
  local left="$1" right="$2"
  local left_numeric=0 right_numeric=0
  [[ "$left" =~ ^[0-9]+$ ]] && left_numeric=1
  [[ "$right" =~ ^[0-9]+$ ]] && right_numeric=1

  if ((left_numeric && right_numeric)); then
    # Compared as integers rather than strings so that 2 ranks below 11.
    if ((10#$left < 10#$right)); then
      echo -1
    elif ((10#$left > 10#$right)); then
      echo 1
    else
      echo 0
    fi
    return 0
  fi
  ((left_numeric)) && {
    echo -1
    return 0
  }
  ((right_numeric)) && {
    echo 1
    return 0
  }

  if [[ "$left" < "$right" ]]; then
    echo -1
  elif [[ "$left" > "$right" ]]; then
    echo 1
  else
    echo 0
  fi
}
