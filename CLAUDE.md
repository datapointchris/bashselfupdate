# bashselfupdate — Claude Code instructions

A public bash library, not a CLI. Nothing here is executed directly except
`install.sh`; the rest is sourced by the bash tools in `~/tools/`.

Unlike most repos here, this one is written to be used by strangers. Treat the
function names, the README and the header comments as the product — a change
that is merely convenient for font and theme is not automatically right.

It is the bash sibling of `~/tools/goselfupdate` and `~/tools/pyselfupdate`.
The three deliberately share conventions and version precedence. All three now
have a notify layer — goselfupdate's is `autoupdate/autoupdate.go`. The
state-file schema and the environment-variable contract are shared across all
three, so a rename in one breaks the other two; see
`standards/release.md` § Self-update. They do **not** share an API,
because "update" means three different operations.

## Layout

| Path | Holds |
| --- | --- |
| `load.bash` | The entry point. Sources everything else |
| `lib/version.sh` | Semantic version comparison, replacing `sort -V` |
| `lib/source.sh` | Reading tags from a remote |
| `lib/update.sh` | `check`, `update`, `changelog` |
| `lib/state.sh` | The shared `autoupdate-<machine>.json` schema, and the machine derivation that names it |
| `lib/notify.sh` | The gate, the interval, the notice |
| `install.sh` | Clone-and-pin. The only executable file |

## Constraints that must not regress

The shell rules this library obeys — no `set -euo pipefail` in a sourced file,
bash 3.2 rather than 4 — are `standards/shell.md`. The self-update rules
it obeys — notify never fails or prints, the timestamp is stamped before the
lookup, the state schema is shared across all three siblings, version
comparison stays byte-compatible — are `standards/release.md` §
Self-update. Neither is restated here. What is specific to this repo:

- **`install.sh` is executed, not sourced**, so it *does* set `-euo pipefail`;
  everything under `lib/` is sourced and must not.
- **The only hard dependencies are `git` and `jq`.** Both are already required
  by every consumer. No `curl`, no GitHub API, no token — which is also what
  keeps this a zero-third-party-dependency library.
- **`update` leaves the checkout on a branch, never detached.** This is the bug
  the library exists to stop repeating; `tests/update.bats` pins it twice.
- **The machine in the state filename is derived identically in all three
  siblings** — bare hostname, domain dropped, lowercased, `unknown` when it
  cannot be read. A library deriving it differently puts one box's state under
  two names, and neither box then sees the other's. `tests/state.bats` asserts
  the same cases goselfupdate and pyselfupdate assert.
- `tests/version.bats` is where the shared ordering matrix is asserted for the
  bash implementation.

## Where the three version traps are handled

`release.md` § Versioning derives why each of these is a trap. What this
library does about them:

- **`bashselfupdate_current_version` asks git, never a version string** — a
  `git describe` suffix is valid semver, so no string test can answer "am I on
  a release". Same move pyselfupdate makes by reading uv's receipt.
- **It uses `git tag --points-at HEAD`, not `describe --exact-match`**, and
  takes the highest by this library's own comparator. The unit tests were green
  through this bug; only the end-to-end install test caught it.
- **`lib/version.sh` exists because `sort -V` is not semver** — and because BSD
  `sort` on macOS has no `-V` at all.

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

`font` and `theme`. Both migrated: each `install.sh` calls `install_bashselfupdate`
then `bashselfupdate_checkout_latest`, and each `bin/` entry point sources
`load.bash` and calls `bashselfupdate_notify`, `_update`, `_current_version`,
`_describe` and `_changelog`. Neither keeps a copy of the update logic any more.

The checkout-onto-a-branch behavior is the part that had to land with the
migration rather than after it — without it a re-run of the installer leaves a
detached HEAD and fails.
