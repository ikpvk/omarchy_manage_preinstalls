# Install "Manage Preinstalls" on a Fresh Omarchy Machine

Deploy the granular preinstalls manager to any machine running a stock Omarchy
installation. Everything it depends on already ships with Omarchy — no new
packages are required.

---

## Prerequisites (all present by default on Omarchy)

The feature reuses existing Omarchy components. Verify they exist:

```bash
command -v gum                                   # TUI toolkit
command -v omarchy-webapp-install omarchy-tui-install
command -v omarchy-webapp-remove omarchy-tui-remove omarchy-cmd-present pacman
command -v omarchy-mise-install omarchy-install-hermes-cli omarchy-pkg-add omarchy-pkg-drop
command -v omarchy-launch-floating-terminal-with-presentation
```

The script checks these itself at startup and names any that are missing. On a
current stock install all are present (`omarchy-install-hermes-cli` only ships
with recent Omarchy releases).

## Step 1 — Install the script

Copy the script to the user's own `~/.local/bin` (already on `PATH`, survives
updates, and is *not* touched by `omarchy update`):

```bash
cp /path/to/omarchy-preinstalls ~/.local/bin/omarchy-preinstalls
chmod +x ~/.local/bin/omarchy-preinstalls
```

> **Do not** place it in `/usr/share/omarchy/` — that tree is owned by the
> `omarchy` package and any local changes are overwritten on `omarchy update`.

The script begins with an `omarchy:summary=` comment, so it is also picked up
by `omarchy commands`.

## Step 2 — Add the menu entry

Append a row to the user menu extension file
`~/.config/omarchy/extensions/omarchy-menu.jsonc` (create the file if it does
not exist):

```bash
mkdir -p ~/.config/omarchy/extensions
```

Insert before the closing `}` of the existing object:

```jsonc
"install.manage-preinstalls": {"icon":"󰏓","label":"Manage Preinstalls","description":"Add or remove preinstalled web apps, TUIs, CLI tools, and desktop packages individually","action":"omarchy-launch-floating-terminal-with-presentation omarchy-preinstalls"},
```

Example of a minimal valid file:

```jsonc
{
  "install.manage-preinstalls": {"icon":"󰏓","label":"Manage Preinstalls","description":"Add or remove preinstalled web apps, TUIs, CLI tools, and desktop packages individually","action":"omarchy-launch-floating-terminal-with-presentation omarchy-preinstalls"},
}
```

Notes:

- JSONC allows comments and trailing commas.
- The dotted id `install.manage-preinstalls` places the row under the existing
  **Install** submenu, next to the stock bulk `Install → Preinstalls` and
  `Remove → Preinstalls` entries (which are left untouched).
- The extension file **hot-reloads on save** — no restart needed. If the row
  does not appear, refresh/reopen the menu.

## Step 3 — Verify

```bash
# 1. Help + syntax
~/.local/bin/omarchy-preinstalls --help
bash -n ~/.local/bin/omarchy-preinstalls

# 2. Dry-run: shows what WOULD happen without changing anything
OMARCHY_DRY_RUN=1 ~/.local/bin/omarchy-preinstalls

# 3. Interactive (requires a terminal)
omarchy-preinstalls
```

Then open **Super** → **Install** → **Manage Preinstalls**. Installed items are
pre-checked; toggle with `space`/`x`, confirm with `enter`, toggle all with
`ctrl+a`. After the summary it asks for confirmation before applying anything.

## Non-interactive / scripting usage

```bash
# Print the plan without executing (same as the menu, safe to script):
OMARCHY_DRY_RUN=1 omarchy-preinstalls

# Fully scripted: the selection is the COMPLETE desired state. Every installed
# preinstall it doesn't list is removed, which needs an explicit opt-in.
# Item ids: webapp|<Name> | tui|<Name> | cli|<bin> | pkg|<pkg>
# This keeps only Discord and Obsidian and removes all other preinstalls:
OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\npkg|obsidian' \
OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 \
OMARCHY_PREINSTALLS_YES=1 omarchy-preinstalls
```

Preview a selection first with `OMARCHY_DRY_RUN=1` instead of
`OMARCHY_PREINSTALLS_YES=1`. Unknown ids (e.g. `pkg|Obsidian`) are an error,
and without `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1` a selection that would remove
anything stops before changing anything. `OMARCHY_PREINSTALLS_YES=1` without a
selection is an error.

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Error: required command(s) not found: ...` | An Omarchy helper or `gum` is missing — install `gum` with `omarchy pkg add gum`; for Omarchy helpers, run `omarchy update`. |
| `Warning: this script's list of preinstalls differs from Omarchy` | Omarchy changed its preinstalls; see "Keeping it up to date" below. Items the script doesn't list are neither shown nor changed. |
| A run ends with "Failed:" and exits non-zero | Every other change was still applied. Fix the cause, then run `omarchy-preinstalls` again or use the printed retry commands — don't re-run a selection of just the failed ids, since that would remove everything else. |
| Menu row not visible | Extension not reloaded — reopen the menu, or run `omarchy menu` again. JSONC syntax error → fix and re-save. |
| "Done" prompt appears once | Correct. The menu wrapper already prints it; do **not** re-add `omarchy-show-done` to the script. |
| `sudo: a password is required` | Package remove/install self-elevates. Run inside a terminal where sudo can prompt (the menu already does this). |
| `preinstalls-removed` marker | The bulk `Remove → Preinstalls`/`Install → Preinstalls` entries read the marker at `~/.local/state/omarchy/preinstalls-removed`. This feature **ignores** it, so the two systems never interfere — but a bulk remove run by the stock command can remove items this tool just installed, and vice versa. |

## Keeping it up to date

The inventory tables in the script are hardcoded to the Omarchy version this
was built against. On every run it compares them with `$OMARCHY_PATH` and
prints a warning naming any differences. When that happens, re-sync the tables
in the script from:

```bash
ls "$OMARCHY_PATH"/applications/*.desktop               # web apps + TUIs
cat "$OMARCHY_PATH/install/user/mise.sh"                # CLI stubs
grep -A20 omarchy-pkg-drop "$OMARCHY_PATH/bin/omarchy-remove-preinstalls"   # packages
```

New CLI tools may need their own ownership check; copy the one
`omarchy-remove-preinstalls` uses for them.