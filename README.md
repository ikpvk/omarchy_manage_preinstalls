# Omarchy "Manage Preinstalls"

A granular alternative to Omarchy's all-or-nothing `Remove → Preinstalls` /
`Install → Preinstalls` commands. An interactive checkbox list lets you keep,
install, or remove individual preinstalled web apps, TUIs, CLI tools, and
desktop packages.

- [Install](#install)
- [Update to the latest version](#update-to-the-latest-version)
- [Uninstall](#uninstall)
- [Usage](#usage)
- [Troubleshooting](#troubleshooting)
- [What it manages](#what-it-manages)
- [How it works](#how-it-works)
- [Development](#development)

---

## Why

On a fresh Omarchy install, the `Super` menu exposes:

- **Remove → Preinstalls** — removes *everything* preinstalled at once.
- **Install → Preinstalls** — restores *everything* at once.

There was no way to keep a few items while removing the rest.

## Install

### Requirements

- **A recent Omarchy release**, one that includes `omarchy-install-hermes-cli`.
  Check with `command -v omarchy-install-hermes-cli`; if it prints nothing,
  run `omarchy update` first.
- Nothing else: `gum`, `pacman`, and the Omarchy helpers the tool uses all
  ship with Omarchy, so no new packages are needed. At startup the script
  checks every command it needs and names any that are missing.

### 1. Get the script

```bash
git clone https://github.com/ikpvk/omarchy_manage_preinstalls.git
cd omarchy_manage_preinstalls
```

### 2. Copy it into `~/.local/bin`

```bash
install -m 755 omarchy-preinstalls ~/.local/bin/omarchy-preinstalls
```

`~/.local/bin` is yours, already on `PATH`, and never touched by
`omarchy update`. **Do not** put the script in `/usr/share/omarchy/`: that tree
belongs to the `omarchy` package and is overwritten on every update.

The script starts with an `omarchy:summary=` comment, so it also shows up in
`omarchy commands`.

### 3. Add the menu entry

Create the menu extension file if it doesn't exist yet:

```bash
mkdir -p ~/.config/omarchy/extensions
```

Then add this row to `~/.config/omarchy/extensions/omarchy-menu.jsonc`, before
the closing `}`:

```jsonc
"install.manage-preinstalls": {"icon":"󰦏","label":"Manage Preinstalls","description":"Add or remove preinstalled web apps, TUIs, CLI tools, and desktop packages individually","action":"omarchy-launch-floating-terminal-with-presentation omarchy-preinstalls"},
```

If the file is new, the whole file looks like this:

```jsonc
{
  "install.manage-preinstalls": {"icon":"󰦏","label":"Manage Preinstalls","description":"Add or remove preinstalled web apps, TUIs, CLI tools, and desktop packages individually","action":"omarchy-launch-floating-terminal-with-presentation omarchy-preinstalls"},
}
```

- JSONC allows comments and trailing commas.
- The id `install.manage-preinstalls` puts the row in the **Install** submenu,
  next to the stock bulk entries (which stay as they are).
- The file reloads on save; no restart is needed. If the row doesn't appear,
  reopen the menu.

### 4. Check it works

```bash
omarchy-preinstalls --help
OMARCHY_DRY_RUN=1 omarchy-preinstalls   # shows what it would do, changes nothing
```

## Update to the latest version

The copy in `~/.local/bin` does **not** update itself when the repository
changes, and `omarchy update` doesn't touch it. To check whether you're
running an older version, from your clone:

```bash
cd /path/to/omarchy_manage_preinstalls
git checkout master
git pull
cmp -s omarchy-preinstalls ~/.local/bin/omarchy-preinstalls && echo "Up to date" || echo "Older version installed"
```

If it says "Older version installed", copy the new script over the old one
and check it:

```bash
install -m 755 omarchy-preinstalls ~/.local/bin/omarchy-preinstalls
OMARCHY_DRY_RUN=1 omarchy-preinstalls   # changes nothing
```

That's all: the menu entry calls the same command, so it doesn't need to
change, and the next time you open **Manage Preinstalls** it runs the new
version.

### Changes since older versions

If you installed before October 2026, note:

- **New items:** the CLI tools `cursor-agent`, `muse`, and `hermes` are now
  managed too (42 items in all).
- **Newer Omarchy needed:** see [Requirements](#requirements).
- **Scripts that use `OMARCHY_PREINSTALLS_SELECTION` behave more safely, so
  some need updating:**
  - a selection that would remove anything now also needs
    `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1`, or the run stops before changing
    anything;
  - unknown item ids are an error instead of being ignored;
  - `OMARCHY_PREINSTALLS_SELECTION=""` now means "nothing selected" (remove
    everything) instead of opening the picker;
  - `OMARCHY_PREINSTALLS_YES=1` without a selection is an error.
- **Stricter input:** yes/no variables accept only `1`/`0`, `true`/`false`,
  or `yes`/`no`; any argument other than `-h`/`--help` is an error; running as
  root is refused.
- **Safer runs:** launchers and CLI files Omarchy didn't write are never
  removed or overwritten, a failed step no longer stops the run, and every
  run ends with a summary of what succeeded, was skipped, or failed.

## Uninstall

Removing the manager doesn't touch the applications it manages: everything
stays exactly as it is when you uninstall it, and the stock bulk commands
keep working.

1. Delete the script:

   ```bash
   rm ~/.local/bin/omarchy-preinstalls
   ```

2. Remove the menu row: delete the `"install.manage-preinstalls": {…},` line
   from `~/.config/omarchy/extensions/omarchy-menu.jsonc`. If it was the only
   entry there, you can delete the whole file instead. The menu reloads on
   save.

3. Optionally, delete your clone of this repository.

## Usage

**From the menu:** `Super` → **Install** → **Manage Preinstalls** (opens a
floating terminal).

**From a terminal:** `omarchy-preinstalls`.

Installed items are pre-checked. `space`/`x` toggles an item, `enter`
confirms, `ctrl+a` toggles all. The script then shows what it will install
and remove and asks for confirmation before changing anything. Checked items
that are missing get installed; unchecked items that are installed get
removed.

**CLI tools install on first use.** Checking a CLI tool only creates a small
wrapper in `~/.local/bin`, so that step finishes almost instantly. The tool
itself is downloaded the first time you run it, so expect that first launch
to take longer (for `hermes`, a few minutes). Later launches are quick.

The script takes no arguments other than `-h`/`--help`. It refuses to run as
root: it would act on root's home, and the package helpers ask for `sudo`
themselves.

### Environment variables

All optional. Yes/no values accept `1`/`0`, `true`/`false`, or `yes`/`no`;
anything else is an error.

| Variable | Effect |
|---|---|
| `OMARCHY_DRY_RUN=1` | Print every planned command without executing anything |
| `OMARCHY_PREINSTALLS_SELECTION` | Skip the picker. Newline-separated item ids: the **complete desired state**. Installed items it doesn't list are removed; set but empty means remove everything. Unknown ids are an error |
| `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1` | Required for a `SELECTION` run that would remove anything; without it the run stops before changing anything (a dry run only notes it) |
| `OMARCHY_PREINSTALLS_YES=1` | Skip the final confirmation. Only valid with `OMARCHY_PREINSTALLS_SELECTION` |

Item ids: `webapp|<Name>`, `tui|<Name>`, `cli|<bin>`, `pkg|<package>` (e.g.
`webapp|Discord`, `tui|Docker`, `cli|gh`, `pkg|obsidian`).

### Scripted use

```bash
# Preview a selection first; changes nothing:
OMARCHY_DRY_RUN=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\npkg|obsidian' \
  omarchy-preinstalls

# Keep only Discord and Obsidian, removing every other preinstall:
OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\npkg|obsidian' \
OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 \
OMARCHY_PREINSTALLS_YES=1 omarchy-preinstalls
```

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Error: required command(s) not found: ...` | `gum` or an Omarchy helper is missing. Install `gum` with `omarchy pkg add gum`; for Omarchy helpers, run `omarchy update`. |
| `Warning: this script's list of preinstalls differs from Omarchy` | Omarchy changed its preinstalls. First [update the script](#update-to-the-latest-version); if the warning stays, see [Keeping the lists in sync](#keeping-the-lists-in-sync-with-omarchy). Items the script doesn't list are neither shown nor changed. |
| A run ends with "Failed:" and exits non-zero | Independent changes continue after a failure; changes that depend on a failed one are not attempted. The summary shows what succeeded, failed, or was skipped. Fix the cause, then run `omarchy-preinstalls` again or use the printed retry commands. Don't re-run a selection of just the failed ids: that would remove everything else. |
| An item is listed under "Left untouched" | Something at that path wasn't written by Omarchy (your own launcher, a native install, a symlink). The script never removes or overwrites it. |
| Menu row not visible | Reopen the menu, or run `omarchy menu` again. If it still doesn't appear, check the JSONC for a syntax error and save again. |
| "Done" prompt appears once | Correct: the menu wrapper already shows it. Don't add `omarchy-show-done` to the script. |
| `sudo: a password is required` | Package changes ask for `sudo`. Run in a terminal where sudo can prompt (the menu already does this). |
| Using it alongside the stock **Remove/Install → Preinstalls** | This tool never creates or deletes the `~/.local/state/omarchy/preinstalls-removed` marker. The stock bulk commands do, and that marker turns the preinstall keybindings off (present) or on (absent). The stock commands also act on the same items as this tool: a bulk remove removes items you kept here, and a bulk install restores items you removed here. Reinstalling items here after a bulk remove leaves the marker in place, so their keybindings stay off until the stock **Install → Preinstalls** runs. |

## What it manages

Reading the packaged sources under `/usr/share/omarchy/`, the preinstalls fall
into **four categories**:

| Category | Count | Counted as installed when |
|---|---|---|
| Web app launchers | 11 | a regular `.desktop` file with `Exec=omarchy-launch-webapp*` / `omarchy-webapp-handler*` |
| TUI launchers | 2 | a regular `.desktop` file with `Exec=*xdg-terminal-exec --app-id=TUI.*` |
| CLI tool stubs | 16 | a regular file in `~/.local/bin/` with a `mise use -g … "<pkg>"` line (muse: the `"http:muse[` prefix; hermes: `omarchy-install-hermes-cli --owns`). Anything else there is yours and is left alone |
| Desktop packages | 13 | listed by one `pacman -Qq` query |

### Web apps (11)

| Name | URL | Icon |
|---|---|---|
| Basecamp | https://launchpad.37signals.com | basecamp |
| Discord | https://discord.com/channels/@me | omarchy-discord |
| Google Contacts | https://contacts.google.com/ | google-contacts |
| Google Maps | https://maps.google.com | google-maps |
| Google Messages | https://messages.google.com/web/conversations | google-messages |
| Google Photos | https://photos.google.com/ | google-photos |
| HEY | https://app.hey.com (mailto handler) | hey |
| WhatsApp | https://web.whatsapp.com/ | whatsapp |
| X | https://x.com/ | x |
| YouTube | https://youtube.com/ | youtube |
| Zoom | https://app.zoom.us (meeting handler) | zoom |

HEY and Zoom use custom `Exec` handlers (`omarchy-webapp-handler-hey %u`,
`omarchy-webapp-handler-zoom %u`) plus `MimeType` entries, which the installer
preserves.

### TUIs (2)

| Name | Command | Style | Icon |
|---|---|---|---|
| Disk Usage | `bash -c "dua i /"` | float | disk-usage |
| Docker | `omarchy-launch-docker-tui` | tile | docker |

### CLI tool stubs (16)

| bin | mise package | command |
|---|---|---|
| codex | codex | — |
| claude | claude | — |
| crush | crush | — |
| gemini | gemini | — |
| gh | gh | — |
| copilot | copilot | — |
| opencode | opencode | — |
| playwright | npm:playwright | playwright |
| pi | pi | — |
| omp | github:can1357/oh-my-pi | omp |
| grok | npm:@xai-official/grok | grok |
| cursor-agent | cursor-agent | — |
| ghui | npm:@kitlangton/ghui | ghui |
| hunk | aqua:modem-dev/hunk | hunk |
| hermes | installed by `omarchy-install-hermes-cli` | — |
| muse | `http:muse[url=https://api.meta.ai/muse-launcher.sh,…]` | muse |

Installing a CLI tool writes only its wrapper; the tool itself is downloaded
the first time you run it. Removing a CLI tool removes only its wrapper in
`~/.local/bin`; mise keeps the tool itself. The script prints the `mise` command that removes it
completely.

### Desktop packages (13)

`aether`, `cliamp`, `libreoffice-fresh`, `xournalpp`, `pinta`, `obsidian`,
`obs-studio`, `kdenlive`, `moonlight-qt`, `lazydocker`, `omacut`, `omacalc`,
`omawrite`

### Keeping the lists in sync with Omarchy

The lists above are built into the script. On every run it compares them with
`$OMARCHY_PATH` and warns about any differences. If you still see the warning
after [updating](#update-to-the-latest-version), the script's tables need
editing to match these sources:

```bash
ls "$OMARCHY_PATH"/applications/*.desktop               # web apps + TUIs
cat "$OMARCHY_PATH/install/user/mise.sh"                # CLI stubs
grep -A20 omarchy-pkg-drop "$OMARCHY_PATH/bin/omarchy-remove-preinstalls"   # packages
```

New CLI tools may need their own ownership check; copy the one
`omarchy-remove-preinstalls` uses for them.

## How it works

`omarchy-preinstalls` is a single bash script using the same `gum` toolkit as
Omarchy, and Omarchy's own helpers for every change:

| Action | Install | Remove |
|---|---|---|
| Web app | `omarchy-webapp-install <name> <url> <icon> [exec] [mime]` | `omarchy-webapp-remove <name>` |
| TUI | `omarchy-tui-install <name> <cmd> <float\|tile> <icon>` | `omarchy-tui-remove <name>` |
| CLI stub | `omarchy-mise-install <pkg> [command]` (hermes: `omarchy-install-hermes-cli`) | `rm ~/.local/bin/<bin>` (stubs only) |
| Package | `omarchy-pkg-add <pkg>...` | `omarchy-pkg-drop <pkg>...` (one call for all packages) |

1. Checks that every command it calls exists, then builds the inventory and
   warns if it differs from the installed Omarchy sources.
2. Detects what is installed per item. A path holding something Omarchy
   didn't write — a CLI file that isn't a mise stub, or a `.desktop` file that
   isn't an Omarchy web app/TUI launcher (including symlinks) — is a conflict:
   it is hidden from the picker, never removed or overwritten, and listed as
   "Left untouched". `cursor-agent` and `muse` found elsewhere on `PATH` count
   as conflicts too (Omarchy only installs those stubs when the command is
   missing). Ownership is re-checked right before each action.
3. Shows a `gum choose --no-limit` checkbox list with installed items
   pre-checked, labelled `Web App · X`, `TUI · X`, `CLI Tool · X`,
   `Package · X`.
4. Compares your selection with what's installed:
   - checked but **not installed** → install
   - unchecked but **installed** → remove
   - the Docker TUI runs `lazydocker`: removing lazydocker while keeping the
     TUI keeps lazydocker, and installing the TUI also installs lazydocker
     (shown under "Adjusted for dependencies")
5. Shows the plan, asks for confirmation, then applies it: removals first, all
   packages in one `pacman` transaction each way, from `/` as the working
   directory (the install helpers would take a same-named file in the current
   directory as the icon). A failed step doesn't stop the run; anything that
   depends on it is not attempted, and a package isn't removed while a
   launcher that runs it is still there. The run ends with a summary of every
   change (succeeded / skipped / failed / not attempted) and, after a failure,
   retry commands, then exits non-zero.
6. Refreshes `update-desktop-database` and `gtk-update-icon-cache`. There's no
   `hyprctl reload`: Hyprland only reads the `preinstalls-removed` marker,
   which this tool never touches, and launchers don't need a reload.

## Development

### Tests

`tests/run.sh` runs the script in a throwaway sandbox (fake `$HOME`, mock
Omarchy helpers that only log their calls), so it never touches the real
system and also runs without Omarchy installed. CI runs it plus ShellCheck on
every push.

```bash
tests/run.sh
```

### Notes & gotchas

- **`set -e` + `[[ ... ]] && foo`**: a false test on the left of `&&` never
  triggers `set -e` by itself, in any bash version, inside a function or not.
  The danger is a function whose *last* command is such a list: it then
  returns non-zero, and if it was called where `set -e` applies, the script
  exits at the call site (this surfaced during dry-run testing as a silent
  mid-loop abort). The script uses `if` statements for these throughout.
- **Failures under `set -e`**: install/remove functions are called as
  `f && rc=0 || rc=$?`, which turns `set -e` off inside them, so each one
  returns its status explicitly (0 done, 1 failed, 2 skipped because the path
  changed hands) instead of relying on the last command.
- **gum 2.0**: multi-select is `--no-limit` (not `--multi`), and with
  `--label-delimiter=:` the *label* is displayed while the *value* is what gets
  returned; `--selected` must list display **labels**, not values.
- **Single "Done" prompt**: the menu launches the tool via
  `omarchy-launch-floating-terminal-with-presentation`, which already runs
  `omarchy-show-done` afterwards, so the script doesn't call it (the stock
  `*preinstalls` commands follow the same convention).
- **Order of changes**: removals run *before* installs so installs have the
  freed space; launchers are removed before the packages they run, and
  packages are installed before launchers. `omarchy-pkg-drop`/`add` ask for
  `sudo` once per batch. Each package's result is judged by a fresh
  `pacman -Qq` afterwards, not by the batch's exit status.

### Verification performed

- Dry runs across every item confirming each install/remove command is
  formatted correctly (including HEY/Zoom custom exec + mime, and the quoted
  `Disk Usage` TUI command).
- Real end-to-end install/remove of web apps (WhatsApp, Basecamp, HEY) and a
  TUI (Disk Usage): launchers byte-for-byte equivalent to the packaged
  `.desktop` files, then the system restored.
- After the second review round (42 items): a dry run on a real Omarchy
  machine detects every installed item, including cursor-agent, muse and
  hermes, and reports no differences from `/usr/share/omarchy`.

## License

MIT — see [`LICENSE`](LICENSE).
