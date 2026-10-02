# Omarchy "Manage Preinstalls" — Work Summary

A granular alternative to Omarchy's all-or-nothing `Remove → Preinstalls` /
`Install → Preinstalls` commands. Provides an interactive checkbox TUI that
lets you keep, install, or remove individual preinstalled applications.

---

## 1. Problem

On a fresh Omarchy install, the `Super` menu exposes:

- **Remove → Preinstalls** — removes *everything* preinstalled at once.
- **Install → Preinstalls** — restores *everything* at once.

There was no way to keep a few items while removing the rest.

## 2. Research Findings

Reading the packaged sources under `/usr/share/omarchy/`, the "preinstalls"
set spans **four categories**:

| Category | Count | Detection |
|---|---|---|
| Web app launchers | 11 | regular `.desktop` file with `Exec=omarchy-launch-webapp*` / `omarchy-webapp-handler*` |
| TUI launchers | 2 | regular `.desktop` file with `Exec=*xdg-terminal-exec --app-id=TUI.*` |
| CLI tool stubs | 16 | regular file in `~/.local/bin/` with a `mise use -g … "<pkg>"` line (muse: the `"http:muse[` prefix; hermes: `omarchy-install-hermes-cli --owns`). Anything else there is the user's and is left alone |
| Desktop packages | 13 | listed by one `pacman -Qq` query |

### Backend commands that already exist (reused, nothing reinvented)

| Action | Install | Remove |
|---|---|---|
| Web app | `omarchy-webapp-install <name> <url> <icon> [exec] [mime]` | `omarchy-webapp-remove <name>` |
| TUI | `omarchy-tui-install <name> <cmd> <float\|tile> <icon>` | `omarchy-tui-remove <name>` |
| CLI stub | `omarchy-mise-install <pkg> [command]` (hermes: `omarchy-install-hermes-cli`) | `rm ~/.local/bin/<bin>` (stubs only; the mise tool stays installed — the script prints the `mise` command that removes it) |
| Package | `omarchy-pkg-add <pkg>...` | `omarchy-pkg-drop <pkg>...` (one call for all packages) |

## 3. The Solution

`omarchy-preinstalls` — a single bash script using the same `gum` TUI toolkit
Omarchy already uses:

1. Checks that every command it calls exists, then builds the full inventory
   (hardcoded tables mirroring `$OMARCHY_PATH/applications/*.desktop`,
   `install/user/mise.sh`, and the package list in
   `bin/omarchy-remove-preinstalls`). If those sources list different items
   (a newer Omarchy), it prints a warning naming the differences.
2. Detects what is currently installed per item. A path holding something
   Omarchy didn't write — a CLI file that isn't a mise stub, or a `.desktop`
   file that isn't an Omarchy web app/TUI launcher (including symlinks) — is a
   conflict: it is hidden from the picker, never removed or overwritten, and
   listed as "Left untouched" in the summary. `cursor-agent` and `muse` found
   elsewhere on `PATH` count as conflicts too (Omarchy only installs those
   stubs when the command is missing). Ownership is re-checked right before
   each action.
3. Renders a `gum choose --no-limit` checkbox list, **pre-checking installed
   items** (grouped and labeled as `Web App · X`, `TUI · X`, `CLI Tool · X`,
   `Package · X`; `space`/`x` toggles, `enter` confirms, `ctrl+a` toggles all).
4. Diffs your selection against live state:
   - checked but **not installed** → will install
   - unchecked but **installed** → will remove
   - the Docker TUI runs `lazydocker`: removing lazydocker while keeping the
     TUI keeps lazydocker, and installing the TUI also installs lazydocker
     (shown under "Adjusted for dependencies")
5. Prints a "Will install / Will remove" summary, asks for confirmation, then
   applies the changes via the backend commands in step 2: removals first,
   all packages in one `pacman` transaction each way, from `/` as the working
   directory (the install helpers would take a same-named file in the current
   directory as the icon). A failed step doesn't stop the run; anything that
   depends on it is not attempted, and a package isn't removed while a
   launcher that runs it is still there. The run ends with a summary of every
   change (succeeded / skipped / failed / not attempted) and, after a failure,
   retry commands (failed packages kept together as one batch, launcher
   installs run from `/`), then exits non-zero.
6. Ends with `update-desktop-database` and `gtk-update-icon-cache`. There's no
   `hyprctl reload`: Hyprland only reads the `preinstalls-removed` marker,
   which this tool never touches, and launchers don't need a reload.

## 4. Files Created / Modified

### `~/.local/bin/omarchy-preinstalls`
The tool itself. `~/.local/bin` is user-owned and on `PATH`. It is **not**
installed into `/usr/share/omarchy/` (that tree is package-owned and
overwritten on `omarchy update`).

### `~/.config/omarchy/extensions/omarchy-menu.jsonc`
One new menu row added (the stock bulk entries are left untouched):

```jsonc
"install.manage-preinstalls": {"icon":"󰏓","label":"Manage Preinstalls","description":"Add or remove preinstalled web apps, TUIs, CLI tools, and desktop packages individually","action":"omarchy-launch-floating-terminal-with-presentation omarchy-preinstalls"},
```

This appears under **Menu → Install → Manage Preinstalls**. The extension file
hot-reloads on save, so no restart is needed.

## 5. Full Inventory

### Web Apps (11) — name, url, icon
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

### CLI Tool Stubs (16) — bin, mise package
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

### Desktop Packages (13)
`aether`, `cliamp`, `libreoffice-fresh`, `xournalpp`, `pinta`, `obsidian`,
`obs-studio`, `kdenlive`, `moonlight-qt`, `lazydocker`, `omacut`, `omacalc`,
`omawrite`

## 6. Usage

**From the menu:** `Super` → **Install** → **Manage Preinstalls** (opens a
floating terminal with themed gum styling).

**From a terminal:** `omarchy-preinstalls` or `omarchy-preinstalls --help`.

The script takes no arguments other than `-h`/`--help`, and refuses to run as
root (it would act on root's home; the package helpers ask for sudo
themselves).

Environment variables (all optional; yes/no values accept `1`/`0`,
`true`/`false` or `yes`/`no`, and anything else is an error):

| Variable | Effect |
|---|---|
| `OMARCHY_DRY_RUN=1` | Print every planned command without executing anything |
| `OMARCHY_PREINSTALLS_SELECTION` | Skip the picker. Newline-separated item ids: the **complete desired state**. Installed items it doesn't list are removed; set but empty means remove everything. Unknown ids are an error |
| `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1` | Required for a `SELECTION` run that would remove anything; without it the run stops before changing anything (a dry run only notes it) |
| `OMARCHY_PREINSTALLS_YES=1` | Skip the final `gum confirm`. Only valid with `OMARCHY_PREINSTALLS_SELECTION` |

Item id format: `webapp|<Name>` / `tui|<Name>` / `cli|<bin>` / `pkg|<pkg>`
(e.g. `webapp|Discord`, `pkg|obsidian`).

```bash
# Keep only Discord and Obsidian, removing every other preinstall:
OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\npkg|obsidian' \
OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_YES=1 omarchy-preinstalls
```

## 7. Development Notes & Gotchas

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
- **Double "Done" prompt (fixed)**: the menu launches the tool via
  `omarchy-launch-floating-terminal-with-presentation`, which already runs
  `omarchy-show-done` after the command. The script's own `omarchy-show-done`
  call was removed so only one prompt appears. (`*preinstalls` stock commands
  follow the same convention.)
- **Removal order**: removals run *before* installs so installs have the
  freed space; launchers are removed before the packages they run, and
  packages are installed before launchers. `omarchy-pkg-drop`/`add`
  self-elevate with `sudo`, once per batch. Each package's result is judged
  by a fresh `pacman -Qq` afterwards, not by the batch's exit status.

## 8. Verification Performed

- `bash -n` syntax check.
- Dry runs across all 39 items confirming every install/remove command is
  formatted correctly (including HEY/Zoom custom exec + mime, and the
  quoted `Disk Usage` TUI command).
- Real end-to-end install/remove of web apps (WhatsApp, Basecamp, HEY) and a
  TUI (Disk Usage) — launchers verified byte-for-byte equivalent to the
  packaged `.desktop` files, then system restored.
- "Nothing to do" no-op path when the selection matches installed state.
- Menu JSONC validated (trailing comma is fine — JSONC).
- After the second review round (now 42 items): a dry run on a real Omarchy
  machine detects every installed item, including cursor-agent, muse and
  hermes, and reports no inventory drift against `/usr/share/omarchy`.
## 9. Tests

`tests/run.sh` runs the script in a throwaway sandbox (fake `$HOME`, mock
Omarchy helpers that only log their calls), so it never touches the real
system and also runs without Omarchy installed. CI runs it plus ShellCheck on
every push.

```bash
tests/run.sh
```
