#!/usr/bin/env bats
# The gate, the interval, the state file and the notice.
#
# Most of these assert that nothing happened. The gate is the part where a wrong
# pass is invisible, so each skip also asserts that the state file was not
# written -- which is the only observable proof the remote was never consulted.

load "$HOME/.local/lib/bats-support/load.bash"
load "$HOME/.local/lib/bats-assert/load.bash"

setup() {
  load helpers
  source "$BATS_TEST_DIRNAME/../lib/version.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/source.sh"
  source "$BATS_TEST_DIRNAME/../lib/update.sh"
  source "$BATS_TEST_DIRNAME/../lib/notify.sh"

  clear_gate_environment
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"

  ORIGIN=$(make_repo "$BATS_TEST_TMPDIR/origin" v1.0.0 v1.1.0)
  CHECKOUT=$(make_checkout "$ORIGIN" "$BATS_TEST_TMPDIR/checkout" v1.0.0)
  STATE="$XDG_STATE_HOME/demo/autoupdate.json"
}

# The gate requires both streams to be terminals, which neither a test runner nor
# a CI step provides -- `script` needs a controlling terminal to copy attributes
# from, and there is none. So terminal detection is overridden rather than faked,
# which is the same seam pyselfupdate exposes as notify(interactive=...) and is a
# real affordance for a tool writing into a pager.
notify_interactively() {
  BASHSELFUPDATE_INTERACTIVE=1 bashselfupdate_notify demo "$CHECKOUT"
}

@test "notifies when a newer release exists" {
  run notify_interactively
  assert_success
  assert_output --partial "demo v1.1.0 available (running v1.0.0)"
  assert_output --partial 'run `demo update`'
}

@test "says nothing when already current" {
  git -C "$CHECKOUT" checkout -B release v1.1.0 --quiet

  run notify_interactively
  assert_success
  refute_output --partial "available"
}

@test "does not check twice inside the interval" {
  notify_interactively 2>/dev/null
  local first
  first=$(jq -r .checked_at_epoch "$STATE")

  run notify_interactively
  refute_output --partial "available"
  assert_equal "$(jq -r .checked_at_epoch "$STATE")" "$first"
}

@test "checks again once the interval has elapsed" {
  notify_interactively 2>/dev/null

  DEMO_AUTO_UPDATE_INTERVAL=0s run notify_interactively
  assert_output --partial "available"
}

@test "writes the state file with both timestamp forms" {
  notify_interactively 2>/dev/null

  assert_equal "$(jq -r .schema "$STATE")" "1"
  assert_equal "$(jq -r .tool "$STATE")" "demo"
  assert_equal "$(jq -r .current_version "$STATE")" "v1.0.0"
  assert_equal "$(jq -r .latest_version "$STATE")" "v1.1.0"
  assert_equal "$(jq -r .last_error "$STATE")" ""
  # The epoch field is what lets this implementation do interval arithmetic at
  # all: BSD date cannot parse the ISO-8601 field without -j -f gymnastics.
  [[ "$(jq -r .checked_at_epoch "$STATE")" =~ ^[0-9]+$ ]]
  [[ "$(jq -r .checked_at "$STATE")" == *Z ]]
}

@test "records the failure and stays silent when the remote is unreachable" {
  git -C "$CHECKOUT" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist"

  run notify_interactively
  assert_success
  assert_output "" # the notify path never prints an error
}

@test "a failed check still consumes its interval" {
  # gh stamps only on success, so a rate-limited or offline user retries on
  # every single invocation until the window resets. Stamping first is the only
  # ordering that actually bounds the request rate.
  git -C "$CHECKOUT" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist"
  notify_interactively 2>/dev/null

  [[ -f "$STATE" ]]
  [[ "$(jq -r .checked_at_epoch "$STATE")" =~ ^[0-9]+$ ]]

  run jq -r .last_error "$STATE"
  assert_output --partial "could not read tags"
}

@test "the fleet kill switch is presence-only" {
  # Any value, including 0 and the empty string, the way NO_COLOR works.
  for value in "" 0 false 1; do
    rm -f "$STATE"
    NO_AUTO_UPDATE="$value" run notify_interactively
    refute_output --partial "available"
    [[ ! -f "$STATE" ]]
  done
}

@test "the per-tool kill switch is presence-only" {
  for value in "" 0 false 1; do
    rm -f "$STATE"
    DEMO_NO_AUTO_UPDATE="$value" run notify_interactively
    refute_output --partial "available"
    [[ ! -f "$STATE" ]]
  done
}

@test "CI is never notified" {
  for variable in CI BUILD_NUMBER RUN_ID GITHUB_ACTIONS CODESPACES; do
    rm -f "$STATE"
    env "$variable=1" bash -c "
      source '$BATS_TEST_DIRNAME/../lib/version.sh'
      source '$BATS_TEST_DIRNAME/../lib/state.sh'
      source '$BATS_TEST_DIRNAME/../lib/source.sh'
      source '$BATS_TEST_DIRNAME/../lib/update.sh'
      source '$BATS_TEST_DIRNAME/../lib/notify.sh'
      bashselfupdate_notify demo '$CHECKOUT'
    " >/dev/null 2>&1
    [[ ! -f "$STATE" ]]
  done
}

@test "a non-terminal is never notified" {
  # No pty here: this is the plain bats environment, where neither stream is a
  # terminal, which is exactly the `tool list > out 2>&1` case.
  run bashselfupdate_notify demo "$CHECKOUT"
  assert_success
  assert_output ""
  [[ ! -f "$STATE" ]]
}

@test "a dev checkout is never notified" {
  add_release "$CHECKOUT" v9.9.9
  git -C "$CHECKOUT" tag -d v9.9.9 >/dev/null

  run notify_interactively
  refute_output --partial "available"
  [[ ! -f "$STATE" ]]
}

@test "enabled reports why a tool has gone quiet" {
  NO_AUTO_UPDATE=1 run bashselfupdate_enabled demo "$CHECKOUT"
  assert_failure
  assert_output "disabled"

  run bashselfupdate_enabled demo "$CHECKOUT"
  assert_failure
  assert_output "not-a-tty"
}

@test "enabled reports a dev checkout" {
  add_release "$CHECKOUT" v9.9.9
  git -C "$CHECKOUT" tag -d v9.9.9 >/dev/null

  # Terminal detection runs before the checkout is inspected, so it has to be
  # satisfied first or this would report not-a-tty and prove nothing.
  BASHSELFUPDATE_INTERACTIVE=1 run bashselfupdate_enabled demo "$CHECKOUT"
  assert_failure
  assert_output "dev-checkout"
}

@test "enabled reports a directory that is not a checkout at all" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"

  BASHSELFUPDATE_INTERACTIVE=1 run bashselfupdate_enabled demo "$BATS_TEST_TMPDIR/plain"
  assert_failure
  assert_output "dev-checkout"
}

@test "terminal detection can be forced off as well as on" {
  # The affordance is symmetric: a tool piping into a pager passes 0.
  BASHSELFUPDATE_INTERACTIVE=0 run bashselfupdate_enabled demo "$CHECKOUT"
  assert_failure
  assert_output "not-a-tty"
}

@test "state survives a corrupt file rather than failing the caller" {
  mkdir -p "$(dirname "$STATE")"
  echo 'not json {{{' >"$STATE"

  run bashselfupdate_state_read demo checked_at_epoch
  assert_success
  assert_output ""

  run bashselfupdate_state_is_due demo 86400
  assert_success
}

@test "state is due when it has never been written" {
  run bashselfupdate_state_is_due demo 86400
  assert_success
}

@test "interval accepts every documented spelling" {
  assert_equal "$(_bashselfupdate_parse_interval 30s)" "30"
  assert_equal "$(_bashselfupdate_parse_interval 30m)" "1800"
  assert_equal "$(_bashselfupdate_parse_interval 24h)" "86400"
  assert_equal "$(_bashselfupdate_parse_interval 7d)" "604800"
  assert_equal "$(_bashselfupdate_parse_interval 90)" "90"
}

@test "an unparseable interval falls back to the default rather than failing" {
  run _bashselfupdate_parse_interval "soon"
  assert_failure

  AUTO_UPDATE_INTERVAL=soon run _bashselfupdate_interval demo
  assert_output "86400"
}

@test "a per-tool interval outranks the fleet interval" {
  AUTO_UPDATE_INTERVAL=99d DEMO_AUTO_UPDATE_INTERVAL=30m run _bashselfupdate_interval demo
  assert_output "1800"
}

@test "the environment prefix uppercases and normalises the tool name" {
  assert_equal "$(_bashselfupdate_env_prefix my-tool)" "MY_TOOL"
  assert_equal "$(_bashselfupdate_env_prefix demo)" "DEMO"
}
