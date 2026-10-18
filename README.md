# bashselfupdate

Update notification and self-update for a bash tool installed as a git
checkout. A tool sources it for two things, and uses either one alone. The
notice tells the user that a newer release exists, at most once a day by
default. The `update` command moves the tool's checkout to that release.

A bash tool distributed as a git clone has no other way to learn of a newer
release, so it drifts silently. This library reads release tags from the tool's
own git remote and moves the checkout between them. It never clones the tool.
The tool's installer does that, then calls this library to put the clone on a
release.

Its boundary with its siblings is the install shape. goselfupdate replaces a Go
binary. pyselfupdate reinstalls a `uv tool`. This one moves a git checkout.

## Install

```bash
# the newest release
curl -fsSL https://raw.githubusercontent.com/datapointchris/bashselfupdate/main/install.sh | bash

# one release, pinned, from the tags git ls-remote lists
curl -fsSL https://raw.githubusercontent.com/datapointchris/bashselfupdate/main/install.sh | bash -s -- <tag>
git ls-remote --tags --refs https://github.com/datapointchris/bashselfupdate 'v*'
```

The installer clones to `${XDG_LIB_HOME:-~/.local/lib}/bashselfupdate`. It
checks the release out onto a branch named `release`. A directory under
`~/.local/lib/` holding a `load.bash` is the layout `bats-support` and
`bats-assert` established for a sourced bash library. Your tool's `source` line
then looks like every other one it already has.

Bash has no package manager worth depending on. So the library is a pinned git
checkout in a known place, which is exactly what the tools it serves are.

Re-running the installer fetches and moves the existing checkout. A directory
at the install path that is not a git checkout is deleted and cloned fresh.
`BASHSELFUPDATE_INSTALL_DIR` overrides the path. `BASHSELFUPDATE_REPO_URL`
installs from a fork.

It requires `git`, `jq` and bash 3.2 or later, on Linux or macOS. Bash 3.2 is
the one macOS ships, so a stock Mac needs no Homebrew bash. The library itself
calls no `curl`, no GitHub API and needs no token.

## Starting from scratch

A tool calls the library from three places: its entry point, its `update`
command and its installer. `$MYTOOL_APP_DIR` is the tool's own git checkout.

```bash
# bin/mytool, before the command is dispatched
source "${XDG_LIB_HOME:-$HOME/.local/lib}/bashselfupdate/load.bash"  # the one file to source; it loads the rest
if [[ "${1:-}" != update ]]; then
  bashselfupdate_notify mytool "$MYTOOL_APP_DIR"   # at most once a day; one stderr line when behind
fi

# bin/mytool, the update command
bashselfupdate_update "$MYTOOL_APP_DIR"            # "<from> <to>" when it moved, nothing when current

# install.sh, once the library is installed and sourced, where it ran git pull
bashselfupdate_checkout_latest "$MYTOOL_APP_DIR"   # the newest release from any state; echoes the tag
```

Then, from a terminal, with the tool published at two releases or more:

```bash
git -C "$MYTOOL_APP_DIR" checkout -B release <older tag>   # stand the tool on an older release
MYTOOL_AUTO_UPDATE_INTERVAL=0 mytool                        # the notice, with the daily throttle off
mytool update                                               # moves it; a second run prints nothing
```

**When the notice does not appear, ask `bashselfupdate_enabled` first.** It
prints why the check was skipped: `disabled`, `not-a-tty`, `ci` or
`dev-checkout`. It prints nothing when the check would run. Call it from a
terminal, never inside `$(...)`. A command substitution is a pipe, so a
captured answer always reads `not-a-tty`.

```bash
bash -c 'source "${XDG_LIB_HOME:-$HOME/.local/lib}/bashselfupdate/load.bash" && bashselfupdate_enabled mytool "$1"' _ "$MYTOOL_APP_DIR"
```

`update` refuses a checkout that does not sit exactly on a release tag, so a
working copy never updates itself. An installer needs the opposite, which is
why it calls `checkout_latest`.

## `bashselfupdate_notify` — one line a day on stderr, and never a failure

```bash
bashselfupdate_notify mytool "$MYTOOL_APP_DIR"            # gate, throttle, then one line if behind
bashselfupdate_notify mytool "$MYTOOL_APP_DIR" upstream   # tags from a remote other than origin
```

The line it prints:

```text
mytool v1.4.0 available (running v1.3.2) — run `mytool update`
```

It never fails, never updates anything and never prints an error. It always
returns 0. A failed lookup is recorded in the state file and swallowed. An
update notice must not be able to break the command the user actually typed.
`mytool update` is where errors are printed.

Nothing is printed when any of these hold. They are checked in this order, and
`bashselfupdate_enabled` prints the reason for the first four.

| Condition | `enabled` prints | Why |
| --- | --- | --- |
| `NO_AUTO_UPDATE` or `MYTOOL_NO_AUTO_UPDATE` is set | `disabled` | Opted out |
| stdout or stderr is not a terminal | `not-a-tty` | `mytool list > out 2>&1` must stay clean |
| `CI`, `BUILD_NUMBER`, `RUN_ID`, `GITHUB_ACTIONS` or `CODESPACES` is set | `ci` | Not a human |
| The checkout does not sit exactly on a release tag | `dev-checkout` | A working copy, not a release |
| A check already ran within the interval | nothing | One lookup per day, not per invocation |

The opt-out is presence-only, so any value counts. `NO_AUTO_UPDATE=0` disables
it, the same way [`NO_COLOR`](https://no-color.org) works. The per-tool prefix
is the tool's name uppercased, with hyphens as underscores: `my-tool` reads
`MY_TOOL_NO_AUTO_UPDATE`.

`AUTO_UPDATE_INTERVAL` sets the interval for every tool.
`MYTOOL_AUTO_UPDATE_INTERVAL` sets it for one, and outranks the first. Both take
`30s`, `45m`, `12h`, `7d` or a bare number of seconds. A value that does not
parse falls back to 24 hours.

`mytool list | jq` is suppressed too, because stdout is a pipe. Set
`BASHSELFUPDATE_INTERACTIVE=0` when your tool knows it writes somewhere a human
will not read: a pager, a log, a structured-output mode. Nothing about the
streams reveals that. `BASHSELFUPDATE_INTERACTIVE=1` forces the opposite
answer.

## `bashselfupdate_update` — moves a checkout that sits on a release, and refuses one that does not

```bash
bashselfupdate_check "$MYTOOL_APP_DIR"                     # "<current> <latest>" when behind, nothing when current
bashselfupdate_update "$MYTOOL_APP_DIR"                    # "<from> <to>" when it moved, nothing when current
bashselfupdate_changelog "$MYTOOL_APP_DIR" "$from" "$to"   # commit subjects between two tags, newest first
```

A worked `mytool update`:

```bash
update)
  if ! bashselfupdate_current_version "$MYTOOL_APP_DIR" >/dev/null; then
    echo "✗ not on a release: $(bashselfupdate_describe "$MYTOOL_APP_DIR")" >&2
    exit 1
  fi
  if ! moved=$(bashselfupdate_update "$MYTOOL_APP_DIR"); then
    echo "✗ could not reach the remote or find a release" >&2
    exit 1
  fi
  if [[ -z "$moved" ]]; then
    echo "✓ already at $(bashselfupdate_current_version "$MYTOOL_APP_DIR")"
    exit 0
  fi
  read -r from to <<<"$moved"
  echo "✓ updated: $from → $to"
  bashselfupdate_changelog "$MYTOOL_APP_DIR" "$from" "$to" | sed 's/^/  • /'
  ;;
```

`update` returns one non-zero for three causes: a checkout off a release tag,
an unreachable remote, and a remote with no releases. The first is what anyone
running the tool from a clone hits. "Could not reach the remote" would mislead
them. So the worked command asks `bashselfupdate_current_version` first and
gives that case its own message.

It never moves a checkout backward. It checks out onto the `release` branch,
never a detached HEAD. `changelog` is silent on failure, because a missing
changelog must not fail an update that already succeeded.

## `bashselfupdate_checkout_latest` — the installer's move, from any starting state

```bash
bashselfupdate_checkout_latest "$MYTOOL_APP_DIR"   # fetch, then the newest release onto the release branch; echoes the tag
```

A fresh `git clone` lands on the default branch. Between releases that branch
is ahead of the newest tag, so `update` refuses it. `checkout_latest` has no
precondition. The checkout may be on a branch, an older tag or an untagged
commit. It is idempotent, which is what makes re-running an installer safe.

**Replace `git pull` in your installer with it.** A checkout that `update` has
moved has no upstream to pull from. On a detached HEAD, which a plain
`git checkout <tag>` leaves, `git pull` answers "You are not currently on a
branch". On the `release` branch it answers "There is no tracking information
for the current branch". Owning the move in one place, for the installer and
for `update` alike, is most of the reason this library exists.

## Releases are git tags, read with `git ls-remote` and ordered by semver, never by `sort -V`

```bash
bashselfupdate_latest_tag "$MYTOOL_APP_DIR"                                    # newest release on origin, pre-releases skipped
BASHSELFUPDATE_ALLOW_PRERELEASE=1 bashselfupdate_latest_tag "$MYTOOL_APP_DIR"  # pre-releases included
bashselfupdate_current_version "$MYTOOL_APP_DIR"                               # the release HEAD sits on, or non-zero
bashselfupdate_compare_versions v1.0.0-rc.1 v1.0.0                             # -1: a pre-release ranks below its release
```

**Tags come from `git ls-remote`, not the GitHub API.** There is no token, no
rate limit and no JSON. It works against any git remote, not only GitHub.
goselfupdate needs the API because a Go release is a binary attached to it. A
bash tool's release is the tag itself.

**Version comparison is implemented here rather than shelled out to
`sort -V`.** GNU version sort orders `1.0.0-rc.1` above `1.0.0`. The
specification puts a pre-release below the release it precedes. So `sort -V`
would offer a release candidate as the newest stable version. BSD `sort` on
macOS has no `-V` at all. Pre-releases are skipped unless
`BASHSELFUPDATE_ALLOW_PRERELEASE` is set, to any value.

**The current version is asked of git, never parsed from a string.** Off a tag,
`git describe` prints `v1.2.3-4-gabc1234`. That is a valid semantic version,
because `4-gabc1234` is a legal pre-release identifier. So no string test can
answer "am I on a release". `bashselfupdate_current_version` lists the tags on
HEAD with `git tag --points-at HEAD` and takes the highest.
`bashselfupdate_describe` prints the `git describe` form for display, and never
belongs in a gate.

## The state file — one per tool per machine, stamped before the lookup

`${XDG_STATE_HOME:-~/.local/state}/<tool>/autoupdate-<machine>.json`, written
atomically:

```json
{
  "schema": 1,
  "tool": "mytool",
  "checked_at": "2026-07-26T15:07:15Z",
  "checked_at_epoch": 1785078435,
  "current_version": "v1.3.2",
  "latest_version": "v1.4.0",
  "last_error": ""
}
```

`<machine>` is the hostname from `uname -n`, lowercased, with its domain
dropped. It is `unknown` when the hostname cannot be read.
`bashselfupdate_machine` prints it. It is in the name because both fields that
vary describe one machine: the version installed here, and the instant this box
last checked. A state directory shared between machines, by a file syncer or a
network home directory, would otherwise have two writers on one path. It would
report whichever wrote last as the state of all of them.

`checked_at_epoch` is redundant on purpose. BSD `date` cannot parse the
ISO-8601 field without `-j -f` gymnastics. That integer makes the interval
arithmetic one subtraction.

A gate that declines to check does not write the file at all. So "no state
file" is observable proof that the network was never touched.

The timestamp is written **before** the lookup. `gh` stamps only on success, so
an offline user retries on every invocation until the window resets. An
interval exists to bound the request rate, and only this ordering does that.

## The functions — what each takes and prints, since a library has no `--help`

| Function | Does |
| --- | --- |
| `bashselfupdate_notify <tool> <dir> [remote]` | Gate, throttle, one line. Never fails |
| `bashselfupdate_enabled <tool> <dir>` | Echoes the skip reason, or nothing |
| `bashselfupdate_check <dir> [remote]` | `<current> <latest>` when behind |
| `bashselfupdate_update <dir> [remote]` | Moves a released checkout; `<from> <to>` |
| `bashselfupdate_checkout_latest <dir> [remote]` | Moves it from *any* state; echoes the tag. For installers |
| `bashselfupdate_changelog <dir> <from> <to>` | Commit subjects, one per line, newest first |
| `bashselfupdate_current_version <dir>` | The highest release tag on HEAD, or non-zero |
| `bashselfupdate_describe <dir>` | Human-readable, tagged or not |
| `bashselfupdate_latest_tag <dir> [remote]` | Newest published release |
| `bashselfupdate_remote_tags <dir> [remote]` | Every `v*` tag |
| `bashselfupdate_compare_versions <a> <b>` | `-1`, `0` or `1` |
| `bashselfupdate_is_valid_version <v>` | Exit status |
| `bashselfupdate_is_prerelease <v>` | Exit status |
| `bashselfupdate_machine` | The machine name the state file carries |
| `bashselfupdate_version` | This library's own release |

`[remote]` defaults to `origin` everywhere it appears.

## Siblings — one contract in three languages, never one API

- [goselfupdate](https://github.com/datapointchris/goselfupdate) replaces a Go
  binary.
- [pyselfupdate](https://github.com/datapointchris/pyselfupdate) reinstalls a
  `uv tool`.

All three ship both halves, the notice and the update. They share four things:
the `autoupdate-<machine>.json` schema, the machine derivation that names it,
the `NO_AUTO_UPDATE` contract and the version precedence rules. So one
dashboard can glob `~/.local/state/*/autoupdate-*.json` across every tool with
no per-tool knowledge. Identical precedence means a tool and its siblings never
disagree about which release is newer.

They share no API, because "update" is three different operations: replace a
binary, rebuild a virtual environment, move a git checkout.

## License

MIT
