# bashselfupdate

Update notification and self-update for bash tools installed as a git checkout.

Two things, used independently: tell the user once a day that a newer release
exists, and move the checkout to it when they ask.

```bash
source "${XDG_LIB_HOME:-$HOME/.local/lib}/bashselfupdate/load.bash"

bashselfupdate_notify mytool "$MYTOOL_APP_DIR"   # once a day, one line if behind
bashselfupdate_update "$MYTOOL_APP_DIR"          # move to the newest tag
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/datapointchris/bashselfupdate/main/install.sh | bash

# or pin a version
bash install.sh v1.2.0
```

Clones to `~/.local/lib/bashselfupdate` and checks out the newest release. That
is the layout `bats-support` and `bats-assert` established for a sourced bash
library, so the `source` line above looks like every other one already in your
tool.

Requires `git`, `jq`, and bash 3.2+ — which is to say the bash macOS ships,
not a newer one from Homebrew.

## Why

A bash tool distributed as a git clone has no way to tell its user a newer
version exists, so it silently drifts. Every tool that solves this solves it
slightly differently, and two of them shipped the same bug.

There is no bash package manager worth depending on, so the "library" is a
pinned git checkout in a known place — which is exactly what the tools it
serves are, and is the honest answer rather than a worse one dressed up.

## notify

Call it once, early, from your tool's entry point:

```bash
bashselfupdate_notify mytool "$MYTOOL_APP_DIR"
```

Once per 24 hours, if a newer tag exists, one line goes to stderr:

```text
mytool v1.4.0 available (running v1.3.2) — run `mytool update`
```

It never fails, never updates anything, and never prints an error — a failed
check is recorded in the state file and swallowed, because an update notice
must not be able to break the command the user actually typed.

Nothing is printed when any of these hold:

| Condition | Why |
| --- | --- |
| `NO_AUTO_UPDATE` or `MYTOOL_NO_AUTO_UPDATE` is set | Opted out |
| `CI`, `BUILD_NUMBER`, `RUN_ID`, `GITHUB_ACTIONS`, `CODESPACES` | Not a human |
| stdout or stderr is not a terminal | `mytool list > out 2>&1` must stay clean |
| The checkout is not sitting exactly on a tag | A working copy, not a release |
| Checked within the interval | One lookup per day, not per invocation |

Presence-only, any value: `NO_AUTO_UPDATE=0` disables it, the same way
[`NO_COLOR`](https://no-color.org) works. Set the interval separately with
`AUTO_UPDATE_INTERVAL=6h` or `MYTOOL_AUTO_UPDATE_INTERVAL=30m`.

Set `BASHSELFUPDATE_INTERACTIVE=0` when your tool already knows it is writing
somewhere a human will not read — into a pager, a log, a structured-output mode
— since nothing about the streams themselves reveals that.

## update

```bash
bashselfupdate_check "$MYTOOL_APP_DIR"    # echoes "<current> <latest>", or nothing
bashselfupdate_update "$MYTOOL_APP_DIR"   # echoes "<from> <to>" if it moved
bashselfupdate_changelog "$MYTOOL_APP_DIR" v1.3.2 v1.4.0
```

A worked `mytool update`:

```bash
if moved=$(bashselfupdate_update "$MYTOOL_APP_DIR"); then
  if [[ -n "$moved" ]]; then
    read -r from to <<<"$moved"
    echo "✓ mytool upgraded: $from → $to"
    bashselfupdate_changelog "$MYTOOL_APP_DIR" "$from" "$to" | sed 's/^/  • /'
  else
    echo "✓ mytool already at latest: $(bashselfupdate_current_version "$MYTOOL_APP_DIR")"
  fi
else
  echo "✗ mytool upgrade failed" >&2
  exit 1
fi
```

**The checkout is left on a branch, never a detached HEAD.** A plain
`git checkout <tag>` detaches, and a detached checkout has no upstream — so any
installer that later runs `git pull` fails with *"You are not currently on a
branch"*. That bug shipped in two tools before this library existed, and fixing
it in one place is most of the reason it does.

## Functions

| Function | Does |
| --- | --- |
| `bashselfupdate_notify <tool> <dir> [remote]` | Gate, throttle, one line. Never fails |
| `bashselfupdate_enabled <tool> <dir>` | Echoes the skip reason, or nothing |
| `bashselfupdate_check <dir> [remote]` | `<current> <latest>` when behind |
| `bashselfupdate_update <dir> [remote]` | Moves the checkout; `<from> <to>` |
| `bashselfupdate_changelog <dir> <from> <to>` | Commit subjects, one per line |
| `bashselfupdate_current_version <dir>` | The tag it sits on, or non-zero |
| `bashselfupdate_describe <dir>` | Human-readable, tagged or not |
| `bashselfupdate_latest_tag <dir> [remote]` | Newest published release |
| `bashselfupdate_remote_tags <dir> [remote]` | Every `v*` tag |
| `bashselfupdate_compare_versions <a> <b>` | `-1`, `0` or `1` |
| `bashselfupdate_is_valid_version <v>` | Exit status |
| `bashselfupdate_is_prerelease <v>` | Exit status |

## Two things that look like details and are not

**Tags come from `git ls-remote`, not the GitHub API.** No token, no rate limit,
no JSON, and it works against any git remote rather than only GitHub. The Go and
Python siblings need the API because they have to locate a release *asset*; a
bash tool's release is the tag itself.

**Version comparison is implemented here rather than shelled out to `sort -V`.**
GNU version sort orders `1.0.0-rc.1` *above* `1.0.0`, where the specification
puts a pre-release below the release it precedes — so `sort -V` would offer a
release candidate as the newest stable version. BSD `sort` on macOS has no `-V`
at all. Pre-releases are skipped entirely unless
`BASHSELFUPDATE_ALLOW_PRERELEASE` is set.

## State

`${XDG_STATE_HOME:-~/.local/state}/<tool>/autoupdate.json`, written atomically:

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

`checked_at_epoch` is redundant on purpose: BSD `date` cannot parse the
ISO-8601 field without `-j -f` gymnastics, and that integer is what makes the
interval arithmetic one subtraction.

A gate that declines to check does not write the file at all, so "no state
file" is observable proof that the network was never touched.

The timestamp is written **before** the lookup. `gh` stamps only on success, so
an offline user retries on every invocation until the window resets; an interval
exists to bound the request rate, and only this ordering actually does that.

## Siblings

The same design in two other languages, sharing the state schema and the
environment-variable contract:

- [goselfupdate](https://github.com/datapointchris/goselfupdate) — replaces a Go binary
- [pyselfupdate](https://github.com/datapointchris/pyselfupdate) — reinstalls a `uv tool`

## Licence

MIT
