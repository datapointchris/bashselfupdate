#!/usr/bin/env bash
# Shared helpers. Sourced by every test file.

# Creates a git repository with one commit per tag, and echoes its path.
#
# The inherited git environment is cleared first. `-C` changes directory but
# does not override GIT_INDEX_FILE, and pre-commit exports one pointing at its
# staged index of whatever repository is being committed -- so `git add` here
# would build a tree from *that* index inside this throwaway repository and die
# on blobs it has never seen. The symptom is a corrupt-object error naming an
# unrelated file, and it only appears under the commit hook.
#
# Usage: make_repo <path> <tag>...
make_repo() {
  local path="$1"
  shift

  (
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES
    mkdir -p "$path"
    git -C "$path" init --quiet --initial-branch=main
    git -C "$path" config user.email test@example.invalid
    git -C "$path" config user.name Test
    git -C "$path" config commit.gpgsign false

    local tag
    for tag in "$@"; do
      echo "$tag" >"$path/VERSION"
      git -C "$path" add VERSION
      git -C "$path" commit --quiet -m "release $tag"
      git -C "$path" tag "$tag"
    done
  )
  echo "$path"
}

# Clones a repository so the clone has a real remote to read tags from, and
# checks it out at a tag the way the installer does.
#
# Usage: make_checkout <origin> <path> <tag>
make_checkout() {
  local origin="$1" path="$2" tag="$3"

  (
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES
    git clone --quiet "$origin" "$path"
    # A clone inherits none of the source repository's local config, so a later
    # add_release into it fails with "empty ident name" on any machine without a
    # global git identity -- which is every CI runner.
    git -C "$path" config user.email test@example.invalid
    git -C "$path" config user.name Test
    git -C "$path" config commit.gpgsign false
    git -C "$path" checkout -B release "$tag" --quiet
  )
  echo "$path"
}

# Adds a tagged commit to an existing repository.
add_release() {
  local path="$1" tag="$2"

  (
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES
    echo "$tag" >"$path/VERSION"
    git -C "$path" add VERSION
    git -C "$path" commit --quiet -m "release $tag"
    git -C "$path" tag "$tag"
  )
}

# Adds an untagged commit, putting the branch ahead of its last release the way
# any repository sits between releases.
add_untagged_commit() {
  local path="$1"

  (
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES
    echo "unreleased" >>"$path/VERSION"
    git -C "$path" add VERSION
    git -C "$path" commit --quiet -m "work after the last release"
  )
}

# Every variable the gate reads. Cleared in setup so a developer's own shell --
# an exported CI=1, a NO_AUTO_UPDATE left over from debugging -- cannot make the
# suite pass or fail for the wrong reason.
clear_gate_environment() {
  unset NO_AUTO_UPDATE AUTO_UPDATE_INTERVAL CI BUILD_NUMBER RUN_ID \
    GITHUB_ACTIONS CODESPACES DEMO_NO_AUTO_UPDATE DEMO_AUTO_UPDATE_INTERVAL
}

# The same inherited git environment make_repo guards against, cleared for the
# test itself rather than for one helper. make_repo and make_checkout unset it
# inside their own subshells, which leaves every `git -C "$CHECKOUT" ...` in a
# test body still reading pre-commit's staged index: git compares the throwaway
# checkout against a tree from another repository, decides VERSION is modified,
# and refuses to switch branches. Standalone runs pass and the commit hook
# fails, which is the same only-under-the-hook symptom documented above.
clear_git_environment() {
  unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES
}
