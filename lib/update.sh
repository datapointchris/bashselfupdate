#!/usr/bin/env bash
# Checking for and applying updates.
#
# A bash tool's install is a git checkout, so updating it is moving that
# checkout to the newest published tag. There is no download, no archive and no
# checksum: git's transport already authenticates and verifies what it fetches.

BASHSELFUPDATE_RELEASE_BRANCH="release"

# Echoes "<current> <latest>" when a newer tag exists, nothing when current.
# Returns non-zero when the checkout or the remote cannot be read.
bashselfupdate_check() {
  local directory="$1"
  local remote="${2:-origin}"

  local current latest
  current=$(bashselfupdate_current_version "$directory") || return 1
  bashselfupdate_is_valid_version "$current" || return 1

  latest=$(bashselfupdate_latest_tag "$directory" "$remote") || return 1

  if [[ "$(bashselfupdate_compare_versions "$latest" "$current")" == "1" ]]; then
    echo "$current $latest"
  fi
  return 0
}

# Moves a checkout to the newest published tag.
#
# Echoes "<from> <to>" when it moved, nothing when already current.
#
# Checks out onto a branch rather than a detached HEAD. A plain `git checkout
# <tag>` detaches, and a detached checkout has no upstream -- so any installer
# that re-runs `git pull` to update fails afterwards with "You are not currently
# on a branch". That bug shipped in font and theme and is the reason this
# function exists rather than each tool spelling it out.
bashselfupdate_update() {
  local directory="$1"
  local remote="${2:-origin}"

  local before
  before=$(bashselfupdate_current_version "$directory") || return 1

  git -C "$directory" fetch --tags --force --quiet "$remote" 2>/dev/null || return 1

  local latest
  latest=$(bashselfupdate_latest_tag "$directory" "$remote") || return 1

  if [[ "$before" == "$latest" ]]; then
    return 0
  fi
  if bashselfupdate_is_valid_version "$before" \
    && [[ "$(bashselfupdate_compare_versions "$latest" "$before")" != "1" ]]; then
    return 0
  fi

  git -C "$directory" checkout -B "$BASHSELFUPDATE_RELEASE_BRANCH" "$latest" --quiet 2>/dev/null || return 1

  echo "$before $latest"
}

# Commit subjects between two tags, one per line, newest last.
#
# Read from the local checkout, which already has both tags after the fetch
# `bashselfupdate_update` performs. Silent on failure: a missing changelog must
# never fail an update that already succeeded.
bashselfupdate_changelog() {
  local directory="$1" from="$2" to="$3"

  [[ -n "$from" && -n "$to" && "$from" != "$to" ]] || return 0
  bashselfupdate_is_valid_version "$from" || return 0

  git -C "$directory" log --format='%s' "${from}..${to}" 2>/dev/null || true
}
