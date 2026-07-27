#!/usr/bin/env bash
# Entry point. Source this and nothing else:
#
#   source "${XDG_LIB_HOME:-$HOME/.local/lib}/bashselfupdate/load.bash"
#
# Named load.bash because that is the convention bats-support and bats-assert
# established for a sourced bash library, and the one this machine's other
# installed libraries already follow.
#
# Deliberately no `set -euo pipefail`: this file is sourced into the caller's
# shell, and setting shell options there would silently change the error
# handling of the program that sourced it.

BASHSELFUPDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/version.sh
source "$BASHSELFUPDATE_DIR/lib/version.sh"
# shellcheck source=lib/state.sh
source "$BASHSELFUPDATE_DIR/lib/state.sh"
# shellcheck source=lib/source.sh
source "$BASHSELFUPDATE_DIR/lib/source.sh"
# shellcheck source=lib/update.sh
source "$BASHSELFUPDATE_DIR/lib/update.sh"
# shellcheck source=lib/notify.sh
source "$BASHSELFUPDATE_DIR/lib/notify.sh"

# This library's own version, so a consumer can report what it loaded.
bashselfupdate_version() {
  bashselfupdate_current_version "$BASHSELFUPDATE_DIR"
}
