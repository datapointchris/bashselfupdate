#!/usr/bin/env bash
# Where releases come from.
#
# Tags are read with `git ls-remote`, not the GitHub API. That is the one place
# the bash implementation is genuinely simpler than its siblings rather than
# merely different: no token, no rate limit, no JSON, and it works against any
# git remote rather than only GitHub. goselfupdate and pyselfupdate need the API
# because they have to find a release *asset*; a bash tool's release is the tag.

# Echoes the tag a checkout is sitting exactly on, or returns non-zero.
#
# --exact-match, not a bare `git describe`, and this is the whole dev-checkout
# gate. It is tempting to describe the checkout and reject the result by its
# shape, but `git describe` on an untagged commit produces `v1.2.3-4-gabc1234`,
# which is a *perfectly valid* semantic version: `4-gabc1234` is a legal
# pre-release identifier, so it parses and sorts below v1.2.3. A version string
# cannot answer "am I on a release".
#
# git can. `--points-at HEAD` lists only tags on the current commit and lists
# nothing at all otherwise, which is the question actually being asked. This
# mirrors pyselfupdate reading uv's receipt rather than inspecting a version:
# ask the tool that recorded the fact.
#
# `--points-at`, not `describe --exact-match`, because one commit can carry
# several tags and describe returns an arbitrary one of them. A checkout pinned
# to v0.2.0 on a commit also tagged v0.1.0 reported v0.1.0, so every run
# announced that v0.2.0 was available -- forever. Taking the highest by this
# library's own comparator is the only answer that matches what was installed.
bashselfupdate_current_version() {
  local directory="$1"

  local best="" tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    bashselfupdate_is_valid_version "$tag" || continue
    if [[ -z "$best" ]] || [[ "$(bashselfupdate_compare_versions "$tag" "$best")" == "1" ]]; then
      best="$tag"
    fi
  done < <(git -C "$directory" tag --points-at HEAD 2>/dev/null)

  [[ -n "$best" ]] || return 1
  echo "$best"
}

# Echoes a human-readable description of a checkout, tagged or not.
#
# For reporting only -- `v1.2.3-4-gabc1234` on an untagged commit. Never feed
# this to the gate; see bashselfupdate_current_version for why.
bashselfupdate_describe() {
  local directory="$1"
  git -C "$directory" describe --tags --always 2>/dev/null
}

# Echoes every v* tag the remote publishes, one per line.
#
# --refs strips the ^{} peeled entries an annotated tag adds, which would
# otherwise appear as a second, identically named candidate.
bashselfupdate_remote_tags() {
  local directory="$1"
  local remote="${2:-origin}"

  git -C "$directory" ls-remote --tags --refs "$remote" 'v*' 2>/dev/null \
    | awk '{print $2}' | sed 's|^refs/tags/||'
}

# Echoes the newest tag the remote publishes, or nothing.
#
# Sorted with this library's own comparator rather than `sort -V` or git's
# `--sort=-v:refname`. GNU version sort orders 1.0.0-rc.1 *above* 1.0.0, where
# the specification puts a pre-release below the release it precedes, and BSD
# sort on macOS has no -V at all. Picking the maximum by comparison is O(n) and
# keeps all three libraries agreeing on what "newest" means.
#
# Pre-releases are skipped unless BASHSELFUPDATE_ALLOW_PRERELEASE is set. This
# matches the siblings, where the same default is spelled `AllowPrerelease` and
# `allow_prerelease` -- and GitHub's own /releases/latest, which excludes them.
# Precedence alone would happily offer v2.0.0-rc.1 to someone on v1.1.0.
bashselfupdate_latest_tag() {
  local directory="$1"
  local remote="${2:-origin}"

  local best="" tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    bashselfupdate_is_valid_version "$tag" || continue
    if [[ -z ${BASHSELFUPDATE_ALLOW_PRERELEASE+x} ]] && bashselfupdate_is_prerelease "$tag"; then
      continue
    fi
    if [[ -z "$best" ]] || [[ "$(bashselfupdate_compare_versions "$tag" "$best")" == "1" ]]; then
      best="$tag"
    fi
  done < <(bashselfupdate_remote_tags "$directory" "$remote")

  [[ -n "$best" ]] || return 1
  echo "$best"
}
