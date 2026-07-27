# bashselfupdate — Claude Code instructions

A public bash library, not a CLI. Nothing here is executed directly except
`install.sh`; the rest is sourced by the bash tools in `~/tools/`.

Unlike most repos here, this one is written to be used by strangers. Treat the
function names, the README and the header comments as the product — a change
that is merely convenient for font and theme is not automatically right.

It is the bash sibling of `~/tools/goselfupdate` and `~/tools/pyselfupdate`.
The three deliberately share conventions, the state-file schema and the
environment-variable contract. They do **not** share an API, because "update"
means three different operations.

## Layout

| Path | Holds |
| --- | --- |
| `load.bash` | The entry point. Sources everything else |
| `lib/version.sh` | Semantic version comparison, replacing `sort -V` |
| `lib/source.sh` | Reading tags from a remote |
| `lib/update.sh` | `check`, `update`, `changelog` |
| `lib/state.sh` | The shared `autoupdate.json` schema |
| `lib/notify.sh` | The gate, the interval, the notice |
| `install.sh` | Clone-and-pin. The only executable file |

## Constraints that must not regress

- **No `set -euo pipefail` in any sourced file.** These are sourced into the
  caller's shell, and setting shell options there silently changes the error
  handling of the program that sourced them. `install.sh` is executed, not
  sourced, so it does set them.
- **bash 3.2, not bash 4.** macOS ships 3.2 and always will, so `${var^^}`,
  `${var,,}`, `declare -A`, `readarray` and `mapfile` are all unavailable. A
  Homebrew bash hides this locally; the macOS CI job and a grep in the lint job
  both catch it. Same reasoning as the siblings' deliberately low floors.
- **The only hard dependencies are `git` and `jq`.** Both are already required
  by every consumer. No `curl`, no GitHub API, no token.
- **`update` leaves the checkout on a branch, never detached.** This is the bug
  the library exists to stop repeating; `tests/update.bats` pins it twice.
- **The notify path never fails and never prints an error.** `<tool> update`
  prints errors. This is what stops a dev checkout printing an upgrade failure
  on every invocation, and it is a design rule rather than scattered guards.
- **The last-checked timestamp is written before the lookup, not after.** `gh`
  stamps only on success, so an offline user retries on every invocation until
  the window resets. There is a test named for it.
- **Version comparison stays byte-compatible with the siblings.** If they
  disagree, a tool and its siblings disagree about which release is newer.
  `tests/version.bats` asserts the full ordering matrix from semver.org
  section 11, which all three were written against.
- **The state schema is shared across all three libraries.** Adding a field is
  fine; renaming or repurposing one breaks the other two and any dashboard.

## Three traps that cost real time, documented so they are not rediscovered

**A `git describe` suffix is valid semver.** `v1.2.3-4-gabc1234` parses
perfectly — `4-gabc1234` is a legal pre-release identifier — and sorts below
`v1.2.3` exactly as the specification says. So a version *string* cannot answer
"am I on a release", and rejecting one by shape does not work.

`bashselfupdate_current_version` asks git instead. That is the same move
pyselfupdate makes by reading uv's receipt: ask the tool that recorded the fact
rather than inferring it from a string. The Go sibling has the identical trap
with build pseudo-versions.

**One commit can carry several tags, and `describe --exact-match` returns an
arbitrary one.** This was the first implementation, and the end-to-end install
test caught it: a checkout pinned to `v0.2.0` on a commit also tagged `v0.1.0`
reported `v0.1.0`, so every run announced that `v0.2.0` was available — forever,
because updating could never change the answer.

`git tag --points-at HEAD` lists all of them, and taking the highest by this
library's own comparator is the only result that matches what was installed.
Worth remembering that the *unit* tests were green through this; only running
the real installer surfaced it.

**`sort -V` is not semver.** GNU version sort orders `1.0.0-rc.1` *above*
`1.0.0`, so using it would offer a release candidate as the newest stable
release. BSD `sort` on macOS has no `-V` at all. Hence `lib/version.sh`.

## Testing

bats, with `bats-support` and `bats-assert` loaded from `~/.local/lib/`.
Nothing is stubbed: git *is* the mechanism, so tests run against real local
repositories cloned over the filesystem, which exercises the same `ls-remote`,
`fetch` and `checkout` paths a real remote would.

**`make_repo` and `make_checkout` clear the inherited git environment.** `-C`
changes directory but does not override `GIT_INDEX_FILE`, and pre-commit
exports one — so `git add` in a throwaway repository builds a tree from *that*
index and dies on blobs it has never seen. The symptom is a corrupt-object
error naming an unrelated file, and it appears only under the commit hook. This
exact bug was found and fixed in dotfiles the same week.

**Terminal detection is overridden, never faked.** `script` needs a controlling
terminal to allocate a pty, and neither a test runner nor a CI step has one, so
a pty-based test cannot work at all. `BASHSELFUPDATE_INTERACTIVE` is the seam,
and it mirrors pyselfupdate's `notify(interactive=...)` — a real affordance for
a tool piping into a pager, not a test-only backdoor.

**Every skip test also asserts the state file was not written.** That absence is
the only observable proof the remote was never consulted.

## Releasing

Push a conventional commit to main; `go-semantic-release` tags it and writes the
changelog. No binaries are built — a bash library ships as a git tag, and the
tag is what `install.sh` and `bashselfupdate_latest_tag` resolve.

A tag can be moved, unlike a Go module version or a PyPI release, so this is the
one sibling where a bad release is recoverable. Do not rely on that.

## Consumers

`font` and `theme` today. Both currently carry their own copy of this logic,
including the detached-HEAD bug; migrating them is what this library was built
for. Their `install.sh` must adopt `bashselfupdate`'s checkout-onto-a-branch
behaviour at the same time, or a re-run of the installer will still fail.
