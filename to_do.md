# omarchy-preinstalls — To Do

Issues found during review of `omarchy-preinstalls` (2026-10-02), plus two
rounds of external review comments.
Mark items `[x]` when fixed and add a short note on what changed.

## Order of work

1. Ownership / conflicts (#1, #13), selection validation (#2), dry-run and argument validation (#4, #5), prerequisite and detection checks (#11).
2. Package batching (#8), dependencies (#6), failure reporting (#3).
3. Remaining items (#7, #9, #10, #12), documentation and cleanup (Minor).

---

## Will break / cause damage

- [x] **1. CLI stubs: no ownership check, for both removal and installation** (`omarchy-preinstalls:113`, `:172`, `:146-152`)
  - Problem (removal): any executable at `~/.local/bin/<bin>` counts as "installed"; unchecking runs `rm -f` on it. Real installs and user scripts/symlinks live there too (e.g. Claude Code's native installer puts `claude` at `~/.local/bin/claude`).
  - Problem (installation): `omarchy-mise-install` runs `rm -f ~/.local/bin/<cmd>` before writing its wrapper, so just marking a non-stub file "not installed" is not enough — checking it would overwrite the user's binary.
  - Fix: three states per CLI item — stub (managed), absent, conflict (unmanaged file present). Note that stock `omarchy-remove-preinstalls` still blindly `rm -f`s the original CLI list and only fingerprints the newer tools (`cursor-agent`, `muse`, `hermes`); extend that fingerprint pattern to **every** CLI item: regular file (not a symlink) containing a line matching `^mise use -g .*"<pkg>"`. Block both install and removal for conflicts and show them as such in the picker/summary.
  - Check `playwright-cli` independently before deleting it (stock remove script deletes it, but nothing in current Omarchy creates it — likely a legacy name).
  - Note: removing the stub leaves the downloaded mise tool on disk **and** a global mise config entry (the stub runs `mise use -g` on first run). Don't run `mise uninstall` / `mise unuse -g` automatically (the tool may be used elsewhere); document the leftover, or make full uninstall opt-in.
  - **Done:** `cli_state` classifies each CLI path as absent / stub / conflict via `is_mise_stub` (regular file, not a symlink, `mise use -g` line naming the package). Conflicts are hidden from the picker, skipped in the diff, and listed under "Left untouched" — never removed or installed over. `playwright-cli` is only deleted if it matches one of the three formats the old `omarchy-npx-install` wrote (traced in upstream Omarchy history) for package `playwright` or `playwright-cli`. Ownership is re-checked immediately before each CLI install/remove, so a file that appears or is replaced while the confirm prompt is open is skipped (only the unavoidable ms gap before the helper's own `rm -f` remains). After removing stubs the script prints `mise unuse -g <pkg>` for full removal (documented in README). Tests: 11 new cases in `tests/run.sh` (incl. files changed while the confirm prompt is open, all legacy `playwright-cli` formats, and an unrelated mise stub at that path).

- [ ] **2. Scripted selection: unsafe input handling** (`:226`, `:246`)
  - Keep the current meaning: `OMARCHY_PREINSTALLS_SELECTION` is the complete desired state (don't make it add-only — that would change the interface).
  - Problem: unknown ids (typos like `pkg|Obsidian`) are silently ignored, so an item the user meant to keep is scheduled for removal. The doc example (`webapp|Discord` + `pkg|obsidian` with `YES=1`) silently uninstalls every other preinstall.
  - Fix: validate every id before computing changes and fail on unknown ones; require explicit permission for removals in scripted mode (e.g. a separate `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1`). Update the example in `INSTALL_ON_NEW_MACHINE.md` and `README.md` to explain the semantics.
  - Also: an explicitly empty `OMARCHY_PREINSTALLS_SELECTION=""` is treated as unset (`[[ -n … ]]`) and opens the picker. Detect "set but empty" with `${VAR+x}`; since that means "remove everything", it needs the same explicit removal opt-in.

- [ ] **3. One failure aborts the whole run partway** (`:278-285`, `set -e`)
  - Problem: a failing `pacman -Rns` (dependency of another package), wrong sudo password, or a network error in a mise install kills the script mid-apply. No report of what succeeded, and the final refresh steps are skipped.
  - Fix: catch failures per item, continue, always run the refresh step, and exit non-zero if anything failed. End with a summary that separates **succeeded**, **failed**, and **skipped because a dependency failed** (relevant once #6/#8 land).
  - Retry guidance: never suggest re-running with only the failed ids — under full-desired-state semantics that would remove everything that succeeded. Print either one command per failed item, or the complete original selection to re-run.

- [ ] **4. Invalid `OMARCHY_DRY_RUN` values crash or behave strangely** (`:123` vs `:287`)
  - Problem: `run()` uses `(( DRY_RUN ))` (numeric) and line 287 uses `[[ $DRY_RUN == 1 ]]` (string). `OMARCHY_DRY_RUN=true`/`yes` → `true: unbound variable` under `set -u`; `=2` skips the dry-run exit, asks to confirm, prints only `[dry-run]` lines, then still reloads Hyprland.
  - Fix: validate once at startup — accept a small set (`0|1`, optionally `true|false|yes|no`) and **fail with a clear error on anything else** (never default an unrecognised value to `0`, or an intended dry run becomes real). Use the same normalised check everywhere.

- [ ] **5. Unrecognized arguments are ignored** (`:22`)
  - Problem: `omarchy-preinstalls --dry-run` silently runs for real, guarded only by the confirm prompt.
  - Fix: reject any argument other than `-h`/`--help` with a usage error (or add a real `--dry-run` flag).

## Logic gaps

- [ ] **6. Docker TUI depends on lazydocker, which the script doesn't know** (confirmed: `omarchy-launch-docker-tui` runs `lazydocker`)
  - Problem: keeping "TUI · Docker" while unchecking "Package · lazydocker" leaves a broken launcher.
  - Fix: detect the conflict and show the proposed adjustment (e.g. keep lazydocker, or also remove the Docker TUI) in the summary before applying anything.

- [ ] **7. `OMARCHY_PREINSTALLS_YES=1` without a selection isn't blocked**
  - Problem: docs say it must be paired with `OMARCHY_PREINSTALLS_SELECTION`, but the script still shows the picker and then skips confirmation.
  - Fix: error out (or ignore `YES`) when no selection is provided.

- [ ] **8. One `sudo pacman` call per package** (confirmed: both helpers accept multiple packages)
  - Problem: up to 13 separate pacman transactions; slow, partial failures leave mixed state, and removing packages one at a time fails when packages selected for removal depend on each other.
  - Fix: batch all package removals into one `omarchy-pkg-drop` call and all installs into one `omarchy-pkg-add` call.

- [ ] **9. `hyprctl reload` likely isn't needed at all**
  - Problem: reloading resets any Hyprland settings changed at runtime. The stock scripts reload because they create/delete the `~/.local/state/omarchy/preinstalls-removed` marker (which gates app keybindings); this script never touches the marker, and `.desktop` launchers don't need a Hyprland reload.
  - Fix: confirm that launcher changes don't need a reload, then remove the call (rather than just making it conditional).

- [ ] **10. Running under `sudo` targets root's home**
  - Problem: `$HOME` becomes root's, so detection and removal act on the wrong directories.
  - Fix: refuse to run when `EUID == 0` (the helpers self-elevate already).

- [ ] **11. Detection failures look like "not installed"** (`:31`, `:116`)
  - Problem: only `gum` is checked up front. And even when a helper exists it can fail: `omarchy-pkg-present` just runs `pacman -Q "$pkg" || exit 1`, so a missing package and a failed `pacman` look identical. The picker can then show a wrong state.
  - Fix: at startup, check every command the script calls in one place (`gum`, `pacman`, `omarchy-pkg-add`, `omarchy-pkg-drop`, `omarchy-webapp-install`/`-remove`, `omarchy-tui-install`/`-remove`, `omarchy-mise-install`, `omarchy-cmd-present`) and exit with a clear error if any is missing. For packages, run `pacman -Qq` once and look names up in its output — but capture it directly and check its exit status (e.g. `inventory=$(pacman -Qq) || die …`). Don't copy `omarchy-pkg-drop`'s `< <(pacman -Qq)`, which discards the exit status, so a failed query would become an empty inventory.

- [ ] **12. Inventory is already out of date with current Omarchy**
  - Problem: stock `omarchy-remove-preinstalls` also manages `cursor-agent`, `muse`, and `hermes` (all present in `~/.local/bin` on this machine); this script doesn't list them. They also need special ownership checks: `cursor-agent` and `muse` use specific `mise use -g` fingerprints (Cursor's own installer can symlink `cursor-agent`), and `hermes` uses `omarchy-install-hermes-cli --owns`.
  - Fix: add them with the stock ownership checks, and add a check that compares the built-in lists against `$OMARCHY_PATH` (`applications/*.desktop`, `install/user/mise.sh`, `install/omarchy-base.packages`, `bin/omarchy-remove-preinstalls`) and warns when they differ.

- [ ] **13. Web app / TUI installs can overwrite a user's own `.desktop` file** (found while fixing #1)
  - Problem: `omarchy-webapp-install` and `omarchy-tui-install` write `~/.local/share/applications/<Name>.desktop` unconditionally (`cat >"$DESKTOP_FILE"`). A file there whose `Exec=` isn't an Omarchy launcher reads as "not installed", so checking the item replaces the user's file.
  - Fix: same three-state model as #1 — absent / Omarchy launcher / conflict — and hide, skip, and report conflicts.

## Minor

- [ ] **README's `[[ … ]] &&` explanation is wrong** — a false test on the left of `&&` is always exempt from `set -e` (any bash version), including inside a function. The real danger is the function then *returning* that non-zero status (e.g. when the list is its last command) and being called somewhere `set -e` applies, which exits the script at the call site. Fix the explanation in `README.md`, and rewrite lines 258 and 260 as `if` for consistency.
- [ ] **`--help` is incomplete** — document `OMARCHY_PREINSTALLS_SELECTION`, `OMARCHY_PREINSTALLS_YES` (and any new removal opt-in), and the item id format.
- [ ] **Simplify `args` building** — replace `mapfile -t args < <(printf …)` with `args=("$name" "$url" "$icon")` (and the cli equivalent); declare `args` as `local`.
