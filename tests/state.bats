#!/usr/bin/env bats
# The state file's name and location.
#
# The three libraries have to agree byte-for-byte on how the machine is derived.
# If this disagrees with goselfupdate's CanonicalMachine or pyselfupdate's
# canonical_machine, one box's state lands under two names and neither box sees
# the other's -- which is the collision the machine in the name exists to make
# unreachable.

load "$HOME/.local/lib/bats-support/load.bash"
load "$HOME/.local/lib/bats-assert/load.bash"

setup() {
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
}

@test "canonical machine drops the domain and the case" {
  run bashselfupdate_canonical_machine archlinux
  assert_output "archlinux"

  run bashselfupdate_canonical_machine Macmini
  assert_output "macmini"

  run bashselfupdate_canonical_machine macmini.trusted
  assert_output "macmini"

  run bashselfupdate_canonical_machine MBP.local
  assert_output "mbp"

  run bashselfupdate_canonical_machine "  archlinux.lan  "
  assert_output "archlinux"

  run bashselfupdate_canonical_machine box.example.com
  assert_output "box"
}

@test "an unreadable host still yields a well-formed name" {
  run bashselfupdate_canonical_machine ""
  assert_output "unknown"

  run bashselfupdate_canonical_machine "   "
  assert_output "unknown"

  run bashselfupdate_canonical_machine ".leading-dot"
  assert_output "unknown"
}

@test "the filename carries the machine" {
  run bashselfupdate_state_filename archlinux
  assert_output "autoupdate-archlinux.json"
}

@test "two machines write two files" {
  local one two
  one=$(bashselfupdate_state_filename archlinux)
  two=$(bashselfupdate_state_filename macmini)
  [ "$one" != "$two" ]
}

@test "this machine's name is already canonical" {
  local name
  name=$(bashselfupdate_machine)
  run bashselfupdate_canonical_machine "$name"
  assert_output "$name"
}

@test "state lands under the tool and the machine" {
  run bashselfupdate_state_path demo
  assert_output "$XDG_STATE_HOME/demo/autoupdate-$(bashselfupdate_machine).json"
}

@test "a write is read back from the same path" {
  bashselfupdate_state_write demo v1.0.0 v1.1.0 ""

  assert [ -f "$XDG_STATE_HOME/demo/autoupdate-$(bashselfupdate_machine).json" ]
  run bashselfupdate_state_read demo current_version
  assert_output "v1.0.0"
}

@test "another machine's file is not read as this one's" {
  mkdir -p "$XDG_STATE_HOME/demo"
  echo '{"schema":1,"tool":"demo","current_version":"v9.9.9"}' \
    >"$XDG_STATE_HOME/demo/$(bashselfupdate_state_filename someotherbox)"

  run bashselfupdate_state_read demo current_version
  assert_output ""
}
