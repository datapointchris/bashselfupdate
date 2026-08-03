#!/usr/bin/env bats
# Version parsing and precedence.
#
# The ordering matrix comes from https://semver.org section 11, which is the
# authority all three libraries were written against. If this disagrees with
# goselfupdate's semver.go or pyselfupdate's version.py, a tool and its siblings
# disagree about which release is newer.

load "$HOME/.local/lib/bats-support/load.bash"
load "$HOME/.local/lib/bats-assert/load.bash"

setup() {
  # shellcheck source=../lib/version.sh
  source "$BATS_TEST_DIRNAME/../lib/version.sh"
}

@test "accepts a version with one, two or three components" {
  for version in v1 1.2 v1.2.3 1.2.3; do
    run bashselfupdate_is_valid_version "$version"
    assert_success
  done
}

@test "accepts a pre-release and build metadata" {
  for version in v1.2.3-rc.1 1.2.3+build v1.2.3-rc.1+build.5; do
    run bashselfupdate_is_valid_version "$version"
    assert_success
  done
}

@test "rejects anything that is not a version" {
  for version in "" v dev latest 1.2.3.4 a.b.c 1.2.3- "1.2.3-rc..1" "1.2.3-rc!"; do
    run bashselfupdate_is_valid_version "$version"
    assert_failure
  done
}

@test "rejects the leading zeros the specification disallows" {
  for version in 01.2.3 1.02.3 1.2.03 1.2.3-rc.01; do
    run bashselfupdate_is_valid_version "$version"
    assert_failure
  done
}

@test "a git describe suffix is valid semver, which is why the gate cannot use one" {
  # Documenting a trap, not an accident. `git describe --tags` on a commit past
  # the last tag produces this, and `4-gabc1234` is a legal pre-release
  # identifier -- so it parses, and it sorts below v1.2.3 exactly as the
  # specification says it should.
  #
  # A version string therefore cannot answer "am I on a release", and
  # bashselfupdate_current_version uses `git describe --exact-match` instead.
  # The same trap exists in the Go sibling, where a build pseudo-version is also
  # valid semver.
  run bashselfupdate_is_valid_version "v1.2.3-4-gabc1234"
  assert_success
  assert_equal "$(bashselfupdate_compare_versions v1.2.3-4-gabc1234 v1.2.3)" "-1"
}

@test "compares major, minor and patch" {
  assert_equal "$(bashselfupdate_compare_versions v1.0.0 v2.0.0)" "-1"
  assert_equal "$(bashselfupdate_compare_versions v2.0.0 v1.0.0)" "1"
  assert_equal "$(bashselfupdate_compare_versions v1.1.0 v1.2.0)" "-1"
  assert_equal "$(bashselfupdate_compare_versions v1.0.1 v1.0.2)" "-1"
}

@test "treats equal versions as equal however they are spelled" {
  assert_equal "$(bashselfupdate_compare_versions v1.2.3 1.2.3)" "0"
  assert_equal "$(bashselfupdate_compare_versions 1.2 1.2.0)" "0"
  assert_equal "$(bashselfupdate_compare_versions 1.2.3+a 1.2.3+b)" "0"
}

@test "follows the specification's precedence ordering" {
  local ordered=(
    1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta
    1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0 1.0.1 1.1.0 2.0.0
  )
  local i j
  for ((i = 0; i < ${#ordered[@]}; i++)); do
    for ((j = i + 1; j < ${#ordered[@]}; j++)); do
      assert_equal "$(bashselfupdate_compare_versions "${ordered[i]}" "${ordered[j]}")" "-1"
      assert_equal "$(bashselfupdate_compare_versions "${ordered[j]}" "${ordered[i]}")" "1"
    done
  done
}

@test "compares numeric pre-release identifiers numerically, not as strings" {
  # The case `sort -V` and naive string comparison both get wrong.
  assert_equal "$(bashselfupdate_compare_versions 1.0.0-beta.2 1.0.0-beta.11)" "-1"
}

@test "ranks a pre-release below its release" {
  # The case GNU `sort -V` gets backwards, which is why this library does not
  # use it.
  assert_equal "$(bashselfupdate_compare_versions 1.0.0-rc.1 1.0.0)" "-1"
}

@test "ranks numeric identifiers below alphanumeric ones" {
  assert_equal "$(bashselfupdate_compare_versions 1.0.0-1 1.0.0-alpha)" "-1"
}

@test "sorts invalid versions below valid ones" {
  assert_equal "$(bashselfupdate_compare_versions nonsense 1.0.0)" "-1"
  assert_equal "$(bashselfupdate_compare_versions 1.0.0 nonsense)" "1"
  assert_equal "$(bashselfupdate_compare_versions nonsense rubbish)" "0"
}
