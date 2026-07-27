# Changelog

All notable changes to this project are documented here. Maintained by
go-semantic-release from conventional commits; edit the unreleased section by
hand only.

## Unreleased

### Added

- `bashselfupdate_notify` — a once-a-day update check that prints one line and
  nothing else. Gated on an opt-out environment variable, CI detection, terminal
  detection, whether the checkout sits on a tag, and a 24 hour interval.
- `bashselfupdate_check` / `_update` / `_changelog` — the explicit update path,
  for a `<tool> update` command. Leaves the checkout on a branch rather than a
  detached HEAD.
- Tag discovery through `git ls-remote`, needing no token, no API and no rate
  limit.
- Semantic version comparison following semver.org section 11, replacing
  `sort -V`, which ranks a pre-release above its release and is absent on BSD.
- A shared `autoupdate.json` state schema, identical across goselfupdate,
  pyselfupdate and bashselfupdate.
- `install.sh`, cloning to `~/.local/lib/bashselfupdate` at a pinned tag.
