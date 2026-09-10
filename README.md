# kiro-profiles

Switch between multiple logged-in [Kiro CLI](https://kiro.dev) profiles on one
machine, the same way you'd juggle separate config directories for any other
tool — by pointing an environment variable at a per-profile directory.

Kiro stores all of its per-user state (auth/login, settings, agents, prompts,
skills, steering, sessions) under `_KIRO_HOME`, defaulting to `~/.kiro`.
`kiro-profiles` gives each profile its own `_KIRO_HOME` directory under
`${XDG_DATA_HOME:-~/.local/share}/kiro-profiles/<name>` and wraps `kiro-cli` so
the right one is always active — including optional directory-local
auto-switching via a `.kiro-profile` file.

Works with `bash` and `zsh` on Linux and macOS. (Windows / MSYS is not
supported yet.)

## Install

```sh
git clone https://github.com/quinnjr/kiro-profiles.git
cd kiro-profiles
./install.sh
```

Then add the printed line to your `~/.zshrc` or `~/.bashrc`:

```sh
. "${XDG_DATA_HOME:-$HOME/.local/share}/kiro-profile/kiro-profile.sh"
```

Reload your shell and create your first profile:

```sh
kiro-profile create --init work
kiro-profile use work
kiro-cli login          # authenticates the "work" account into that profile
```

## How it works

- Each profile is a directory: `${XDG_DATA_HOME:-~/.local/share}/kiro-profiles/<name>`.
- `kiro-profile use <name>` exports `_KIRO_HOME` to that directory for the session.
- The `kiro-cli` wrapper resolves a profile before launching: an explicit
  `use` wins, otherwise a directory-local `.kiro-profile`, otherwise the
  configured default. If none resolve, `_KIRO_HOME` is left **unset** so Kiro
  behaves exactly like a stock install (`~/.kiro`).
- Log in once per profile (`kiro-cli login` while the profile is active) and
  each keeps its own independent session.

## Importing an existing install

Already logged in under the default `~/.kiro`? Snapshot it into a managed
profile instead of starting over:

```sh
kiro-profile import work            # copies ~/.kiro (or $_KIRO_HOME) into "work"
kiro-profile import --from ~/some/other/.kiro personal
kiro-profile use work               # now on the imported profile
```

`import` copies the source directory's full contents (including dotfiles and
permissions) into the new profile, so the imported profile carries over your
existing login/session state. Profile directories are created `0700`
(owner-only), since they hold auth secrets. `import` reuses an existing
**empty** profile directory (so `create work` followed by `import work` works),
but refuses to overwrite a populated profile or to import from another managed
profile directory. `create --from <dir>` does the same thing as part of a
`create`.

## Commands

| Command | Description |
| --- | --- |
| `kiro-profile` | Show current profile status |
| `kiro-profile use <name>` | Switch the session to a profile (pins it) |
| `kiro-profile create [--init] [--from <dir>] <name>` | Create a profile (`--init` writes a `settings/cli.json` skeleton; `--from` copies an existing directory into it) |
| `kiro-profile import [--from <dir>] <name>` | Create a profile from an existing Kiro directory (defaults to `$_KIRO_HOME`, else `~/.kiro`) |
| `kiro-profile list` / `ls` | List all profiles, marking default and active |
| `kiro-profile default [name]` | Get or set the default profile |
| `kiro-profile local [name]` | Show, set (`.kiro-profile`), or `--remove` the directory-local profile |
| `kiro-profile auto [on\|off\|status]` | Control directory-local auto-switching |
| `kiro-profile which [name]` | Print the resolved `_KIRO_HOME` path |
| `kiro-profile version` | Show the installed version |
| `kiro-profile update [--force]` | Update to the latest release |
| `kiro-profile delete <name>` | Delete a profile and all its data |
| `kiro-profile help` | Show help |

## Directory-local profiles

Drop a `.kiro-profile` file in a project (holding a single profile name) and
the shell switches to that profile when you `cd` into the tree, reverting when
you leave:

```sh
cd ~/work/some-project
kiro-profile local work      # writes ./.kiro-profile containing "work"
```

An explicit `kiro-profile use` pins the session and overrides any
`.kiro-profile` until you run `kiro-profile auto on`.

## Environment variables

| Variable | Effect |
| --- | --- |
| `KIRO_PROFILE_NO_AUTO_SWITCH=1` | Disable directory-local auto-switching entirely |
| `KIRO_PROFILE_AUTO_QUIET=1` | Auto-switch silently (no stderr notices) |
| `KIRO_PROFILE_NO_UPDATE_CHECK=1` | Disable the passive update check |
| `KIRO_PROFILE_UPDATE_CHECK_INTERVAL` | Seconds between update checks (default `86400`) |
| `XDG_DATA_HOME` | Overrides where profiles and the tool are stored |

## Updating

A passive, rate-limited check (at most once per day) prints a one-line notice
to stderr when a newer release is available. Upgrade with:

```sh
kiro-profile update
```

The updater downloads `kiro-profile.sh` and `VERSION` from the latest GitHub
release, verifies them against `SHA256SUMS`, and replaces the installed copy
atomically. Disable the check with `KIRO_PROFILE_NO_UPDATE_CHECK=1`.

> **Trust model:** `SHA256SUMS` is served from the same release as the files
> it covers, so verification proves download **integrity**, not
> **authenticity** — trust ultimately rests on GitHub and TLS. Since the
> updater overwrites a script you source into every shell, treat it as an
> RCE-equivalent trust boundary and pin to releases you trust.

## License

MIT — see [LICENSE](LICENSE).
