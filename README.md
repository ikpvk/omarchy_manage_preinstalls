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
| Web app launchers | 11 | `.desktop` file with `Exec=omarchy-launch-webapp*` / `omarchy-webapp-handler*` |
| TUI launchers | 2 | `.desktop` file with `Exec=*xdg-terminal-exec --app-id=TUI.*` |
| CLI tool stubs | 13 | regular file in `~/.local/bin/` with a `mise use -g … "<pkg>"` line (anything else there is the user's and is left alone) |
| Desktop packages | 13 | installed via `pacman` |

### Backend commands that already exist (reused, nothing reinvented)

| Action | Install | Remove |
|---|---|---|
| Web app | `omarchy-webapp-install <name> <url> <icon> [exec] [mime]` | `omarchy-webapp-remove <name>` |
| TUI | `omarchy-tui-install <name> <cmd> <float\|tile> <icon>` | `omarchy-tui-remove <name>` |
| CLI stub | `omarchy-mise-install <pkg> [command]` | `rm ~/.local/bin/<bin>` (stubs only; the mise tool stays installed — `mise unuse -g <pkg>` removes it) |
| Package | `omarchy-pkg-add <pkg>` | `omarchy-pkg-drop <pkg>` |

## 3. The Solution

`omarchy-preinstalls` — a single bash script using the same `gum` TUI toolkit
Omarchy already uses:

1. Builds the full inventory (hardcoded tables mirroring
   `$OMARCHY_PATH/applications/*.desktop`, `install/user/mise.sh`, and
   `install/omarchy-base.packages`).
2. Detects what is currently installed per item. A CLI path holding something
   Omarchy didn't write (a real install, a symlink, a user script) is a
   conflict: it is hidden from the picker, never removed or overwritten, and
   listed as "Left untouched" in the summary.
3. Renders a `gum choose --no-limit` checkbox list, **pre-checking installed
   items** (grouped and labeled as `Web App · X`, `TUI · X`, `CLI Tool · X`,
   `Package · X`; `space`/`x` toggles, `enter` confirms, `ctrl+a` toggles all).
4. Diffs your selection against live state:
   - checked but **not installed** → will install
   - unchecked but **installed** → will remove
5. Prints a "Will install / Will remove" summary, asks for confirmation, then
   applies the changes via the backend commands in step 2.
6. Ends with `update-desktop-database`, `gtk-update-icon-cache`, and
   `hyprctl reload`.

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

### CLI Tool Stubs (13) — bin, mise package
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
| ghui | npm:@kitlangton/ghui | ghui |
| hunk | aqua:modem-dev/hunk | hunk |

### Desktop Packages (13)
`aether`, `cliamp`, `libreoffice-fresh`, `xournalpp`, `pinta`, `obsidian`,
`obs-studio`, `kdenlive`, `moonlight-qt`, `lazydocker`, `omacut`, `omacalc`,
`omawrite`

## 6. Usage

**From the menu:** `Super` → **Install** → **Manage Preinstalls** (opens a
floating terminal with themed gum styling).

**From a terminal:** `omarchy-preinstalls` or `omarchy-preinstalls --help`.

Environment variables (all optional):

| Variable | Effect |
|---|---|
| `OMARCHY_DRY_RUN=1` | Print every planned command without executing anything |
| `OMARCHY_PREINSTALLS_SELECTION` | Skip the picker; newline-separated item ids treated as the selection (non-interactive/scripting) |
| `OMARCHY_PREINSTALLS_YES=1` | Skip the final `gum confirm` (must be combined with `OMARCHY_PREINSTALLS_SELECTION`) |

Item id format: `webapp|<Name>` / `tui|<Name>` / `cli|<bin>` / `pkg|<pkg>`
(e.g. `webapp|Discord`, `pkg|obsidian`).

## 7. Development Notes & Gotchas

- **`set -e` + `[[ ... ]] && foo`**: a failing `[[ ]]` as the *last* command in
  an `&&` list aborts the script under `set -e`. All such patterns in the
  install/remove functions were rewritten as `if` statements (this surfaced
  during dry-run testing as a silent mid-loop abort).
- **gum 2.0**: multi-select is `--no-limit` (not `--multi`), and with
  `--label-delimiter=:` the *label* is displayed while the *value* is what gets
  returned; `--selected` must list display **labels**, not values.
- **Double "Done" prompt (fixed)**: the menu launches the tool via
  `omarchy-launch-floating-terminal-with-presentation`, which already runs
  `omarchy-show-done` after the command. The script's own `omarchy-show-done`
  call was removed so only one prompt appears. (`*preinstalls` stock commands
  follow the same convention.)
- **Removal order**: packages are removed *before* installs so installs have the
  freed space; `omarchy-pkg-drop`/`add` self-elevate with `sudo`.

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
## 9. Tests

`tests/run.sh` runs the script in a throwaway sandbox (fake `$HOME`, mock
Omarchy helpers that only log their calls), so it never touches the real
system and also runs without Omarchy installed. CI runs it plus ShellCheck on
every push.

```bash
tests/run.sh
```
