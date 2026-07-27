#!/usr/bin/env bats
# Reading tags and moving a checkout, against real local git repositories.
#
# Nothing is stubbed: git is the whole mechanism here, so faking it would test
# nothing. A local repository cloned over the filesystem exercises the same
# ls-remote, fetch and checkout paths a real remote would.

load "$HOME/.local/lib/bats-support/load.bash"
load "$HOME/.local/lib/bats-assert/load.bash"

setup() {
  load helpers
  source "$BATS_TEST_DIRNAME/../lib/version.sh"
  source "$BATS_TEST_DIRNAME/../lib/source.sh"
  source "$BATS_TEST_DIRNAME/../lib/update.sh"

  ORIGIN=$(make_repo "$BATS_TEST_TMPDIR/origin" v1.0.0 v1.1.0)
  CHECKOUT=$(make_checkout "$ORIGIN" "$BATS_TEST_TMPDIR/checkout" v1.0.0)
}

@test "current_version reports the tag a checkout sits on" {
  run bashselfupdate_current_version "$CHECKOUT"
  assert_success
  assert_output "v1.0.0"
}

@test "current_version fails on an untagged commit" {
  add_release "$CHECKOUT" v9.9.9
  git -C "$CHECKOUT" tag -d v9.9.9 >/dev/null

  run bashselfupdate_current_version "$CHECKOUT"
  assert_failure
}

@test "describe still reports something on an untagged commit" {
  add_release "$CHECKOUT" v9.9.9
  git -C "$CHECKOUT" tag -d v9.9.9 >/dev/null

  run bashselfupdate_describe "$CHECKOUT"
  assert_success
  assert_output --partial "v1.0.0-"
}

@test "current_version fails outside a git checkout" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run bashselfupdate_current_version "$BATS_TEST_TMPDIR/plain"
  assert_failure
}

@test "remote_tags lists every published tag without fetching" {
  run bashselfupdate_remote_tags "$CHECKOUT"
  assert_success
  assert_line "v1.0.0"
  assert_line "v1.1.0"
}

@test "remote_tags strips the peeled entries an annotated tag adds" {
  git -C "$ORIGIN" tag -a v1.2.0 -m annotated >/dev/null

  run bashselfupdate_remote_tags "$CHECKOUT"
  assert_success
  refute_output --partial "^{}"
  assert_equal "$(bashselfupdate_remote_tags "$CHECKOUT" | grep -c '^v1\.2\.0$')" "1"
}

@test "latest_tag picks the newest by precedence, not by string order" {
  add_release "$ORIGIN" v1.9.0
  add_release "$ORIGIN" v1.10.0

  run bashselfupdate_latest_tag "$CHECKOUT"
  assert_success
  assert_output "v1.10.0"
}

@test "latest_tag ranks a pre-release below its release" {
  add_release "$ORIGIN" v2.0.0-rc.1

  run bashselfupdate_latest_tag "$CHECKOUT"
  assert_success
  assert_output "v1.1.0"
}

@test "latest_tag ignores tags that are not versions" {
  add_release "$ORIGIN" v2.0.0
  git -C "$ORIGIN" tag "vNext" >/dev/null

  run bashselfupdate_latest_tag "$CHECKOUT"
  assert_success
  assert_output "v2.0.0"
}

@test "latest_tag fails when nothing is published" {
  local empty
  empty=$(make_repo "$BATS_TEST_TMPDIR/untagged")
  git -C "$empty" commit --allow-empty --quiet -m initial
  local clone
  clone=$(make_checkout "$empty" "$BATS_TEST_TMPDIR/untagged-clone" HEAD 2>/dev/null || true)

  run bashselfupdate_latest_tag "$BATS_TEST_TMPDIR/untagged-clone"
  assert_failure
}

@test "check reports the pair when behind" {
  run bashselfupdate_check "$CHECKOUT"
  assert_success
  assert_output "v1.0.0 v1.1.0"
}

@test "check says nothing when current" {
  git -C "$CHECKOUT" checkout -B release v1.1.0 --quiet

  run bashselfupdate_check "$CHECKOUT"
  assert_success
  assert_output ""
}

@test "check says nothing when running ahead of the newest release" {
  add_release "$CHECKOUT" v3.0.0
  git -C "$CHECKOUT" checkout -B release v3.0.0 --quiet

  run bashselfupdate_check "$CHECKOUT"
  assert_success
  assert_output ""
}

@test "update moves the checkout to the newest tag and reports the move" {
  run bashselfupdate_update "$CHECKOUT"
  assert_success
  assert_output "v1.0.0 v1.1.0"
  assert_equal "$(bashselfupdate_current_version "$CHECKOUT")" "v1.1.0"
}

@test "update leaves the checkout on a branch, never detached" {
  # The bug this library exists to stop repeating: `git checkout <tag>` detaches
  # HEAD, and a detached checkout has no upstream, so any installer that later
  # runs `git pull` fails with "You are not currently on a branch".
  bashselfupdate_update "$CHECKOUT"

  run git -C "$CHECKOUT" symbolic-ref --short HEAD
  assert_success
  assert_output "release"
}

@test "a checkout stays pullable after an update" {
  bashselfupdate_update "$CHECKOUT"

  run git -C "$CHECKOUT" rev-parse --abbrev-ref --symbolic-full-name HEAD
  assert_success
  refute_output "HEAD"
}

@test "update is a no-op when already current" {
  bashselfupdate_update "$CHECKOUT"

  run bashselfupdate_update "$CHECKOUT"
  assert_success
  assert_output ""
}

@test "update picks up a release published after the checkout was made" {
  bashselfupdate_update "$CHECKOUT"
  add_release "$ORIGIN" v2.0.0

  run bashselfupdate_update "$CHECKOUT"
  assert_success
  assert_output "v1.1.0 v2.0.0"
}

@test "update fails rather than half-applying when the remote is gone" {
  git -C "$CHECKOUT" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist"

  run bashselfupdate_update "$CHECKOUT"
  assert_failure
  assert_equal "$(bashselfupdate_current_version "$CHECKOUT")" "v1.0.0"
}

@test "changelog lists the commit subjects between two tags" {
  bashselfupdate_update "$CHECKOUT"

  run bashselfupdate_changelog "$CHECKOUT" v1.0.0 v1.1.0
  assert_success
  assert_output "release v1.1.0"
}

@test "changelog is silent between identical tags" {
  run bashselfupdate_changelog "$CHECKOUT" v1.0.0 v1.0.0
  assert_success
  assert_output ""
}

@test "changelog is silent rather than failing on an unknown tag" {
  run bashselfupdate_changelog "$CHECKOUT" v0.0.1 v9.9.9
  assert_success
  assert_output ""
}

@test "latest_tag offers a pre-release when explicitly allowed" {
  add_release "$ORIGIN" v2.0.0-rc.1

  BASHSELFUPDATE_ALLOW_PRERELEASE=1 run bashselfupdate_latest_tag "$CHECKOUT"
  assert_success
  assert_output "v2.0.0-rc.1"
}

@test "a build-metadata hyphen is not mistaken for a pre-release" {
  run bashselfupdate_is_prerelease "1.2.3+build-5"
  assert_failure
  run bashselfupdate_is_prerelease "1.2.3-rc.1"
  assert_success
}

@test "current_version picks the highest of several tags on one commit" {
  # `git describe --exact-match` returns an arbitrary one of them, which made a
  # checkout pinned to v0.2.0 report v0.1.0 and announce an update forever.
  git -C "$CHECKOUT" tag v0.9.0 >/dev/null
  git -C "$CHECKOUT" tag v2.5.0 >/dev/null

  run bashselfupdate_current_version "$CHECKOUT"
  assert_success
  assert_output "v2.5.0"
}

@test "current_version ignores non-version tags on the current commit" {
  git -C "$CHECKOUT" tag "stable" >/dev/null
  git -C "$CHECKOUT" tag "latest" >/dev/null

  run bashselfupdate_current_version "$CHECKOUT"
  assert_success
  assert_output "v1.0.0"
}

@test "current_version fails when only non-version tags point at the commit" {
  git -C "$CHECKOUT" tag -d v1.0.0 >/dev/null
  git -C "$CHECKOUT" tag "stable" >/dev/null

  run bashselfupdate_current_version "$CHECKOUT"
  assert_failure
}
