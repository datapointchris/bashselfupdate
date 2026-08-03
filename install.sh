#!/usr/bin/env bash
# Installs bashselfupdate as a sourceable library.
#
#   curl -fsSL https://raw.githubusercontent.com/datapointchris/bashselfupdate/main/install.sh | bash
#   bash install.sh v1.2.0     # pin a version
#
# Bash has no package manager worth depending on, so a library is a git
# checkout in a known place. `~/.local/lib/<name>/` with a `load.bash` is the
# convention bats-support and bats-assert established, and reusing it means a
# consumer's source line looks like every other bash library it already loads.

set -euo pipefail

# Overridable so a fork can install itself, and so CI can exercise this script
# against the commit under test rather than against whatever is on main.
REPO_URL="${BASHSELFUPDATE_REPO_URL:-https://github.com/datapointchris/bashselfupdate.git}"
INSTALL_DIR="${BASHSELFUPDATE_INSTALL_DIR:-${XDG_LIB_HOME:-$HOME/.local/lib}/bashselfupdate}"
RELEASE_BRANCH="release"
REQUESTED_TAG="${1:-}"

info() { echo "[info] $*"; }
success() { echo "[ok] $*"; }
error() { echo "[error] $*" >&2; }

if ! command -v git &>/dev/null; then
  error "git is required but not installed"
  exit 1
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Updating existing installation in $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch --tags --force --quiet origin
else
  info "Cloning into $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi

# Resolve the tag to install. Without an argument this takes the newest, using
# the library's own comparator rather than `sort -V` -- which orders a
# pre-release above its release -- or git's --sort=v:refname.
#
# Sourced from $INSTALL_DIR, which at this point still holds the version being
# replaced. That is why this script uses only these two files and spells the
# checkout out below: see the note there.
# shellcheck source=lib/version.sh
source "$INSTALL_DIR/lib/version.sh"
# shellcheck source=lib/source.sh
source "$INSTALL_DIR/lib/source.sh"

# Checked out onto a branch, never a detached HEAD. A detached checkout has no
# upstream, so re-running this installer -- or any `git pull` against it --
# fails afterwards with "You are not currently on a branch". That bug shipped in
# two tools before this library existed, and pinning it here is most of the
# reason the library exists.
# Spelled out here rather than calling bashselfupdate_checkout_latest, which is
# the function every *consumer's* installer should use. This script is the
# bootstrap: it sources from $INSTALL_DIR, which still holds the version being
# replaced, so depending on a function to install the version that defines it
# fails on exactly the upgrade that introduces it. A bootstrap cannot call
# forward into what it is bootstrapping. The two version.sh/source.sh functions
# above are the minimum it needs and have been stable since v1.0.0.
if [[ -n "$REQUESTED_TAG" ]]; then
  TAG="$REQUESTED_TAG"
else
  if ! TAG=$(bashselfupdate_latest_tag "$INSTALL_DIR"); then
    error "no v* release tags found in $REPO_URL"
    exit 1
  fi
fi

if ! git -C "$INSTALL_DIR" checkout -B "$RELEASE_BRANCH" "$TAG" --quiet; then
  error "could not check out $TAG"
  exit 1
fi

success "bashselfupdate $TAG installed to $INSTALL_DIR"
echo
echo "Source it from your tool:"
echo "  source \"\${XDG_LIB_HOME:-\$HOME/.local/lib}/bashselfupdate/load.bash\""
