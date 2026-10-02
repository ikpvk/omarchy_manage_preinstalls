# omarchy-preinstalls — To Do

Issues found during review of `omarchy-preinstalls` (2026-10-02), plus two
rounds of external review comments.
Mark items `[x]` when fixed and add a short note on what changed.

## Order of work

1. Ownership / conflicts (#1, #13, #14), selection validation (#2), dry-run and argument validation (#4, #5), prerequisite and detection checks (#11).
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

- [x] **2. Scripted selection: unsafe input handling** (`:226`, `:246`)
  - Keep the current meaning: `OMARCHY_PREINSTALLS_SELECTION` is the complete desired state (don't make it add-only — that would change the interface).
  - Problem: unknown ids (typos like `pkg|Obsidian`) are silently ignored, so an item the user meant to keep is scheduled for removal. The doc example (`webapp|Discord` + `pkg|obsidian` with `YES=1`) silently uninstalls every other preinstall.
  - Fix: validate every id before computing changes and fail on unknown ones; require explicit permission for removals in scripted mode (e.g. a separate `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1`). Update the example in `INSTALL_ON_NEW_MACHINE.md` and `README.md` to explain the semantics.
  - Also: an explicitly empty `OMARCHY_PREINSTALLS_SELECTION=""` is treated as unset (`[[ -n … ]]`) and opens the picker. Detect "set but empty" with `${VAR+x}`; since that means "remove everything", it needs the same explicit removal opt-in.
  - **Done:** Unknown ids are rejected before anything changes (listed, exit 1). The selection keeps its full-desired-state meaning; set-but-empty (`${VAR+x}`) now counts as a selection meaning "nothing". Any `SELECTION` run that would remove something stops before changing anything unless `OMARCHY_PREINSTALLS_ALLOW_REMOVE=1` (a dry run only prints a note). Examples in `README.md` and `INSTALL_ON_NEW_MACHINE.md` now include the opt-in and explain the semantics. Tests: 7.

- [x] **3. One failure aborts the whole run partway** (`:278-285`, `set -e`)
  - Problem: a failing `pacman -Rns` (dependency of another package), wrong sudo password, or a network error in a mise install kills the script mid-apply. No report of what succeeded, and the final refresh steps are skipped.
  - Fix: catch failures per item, continue, always run the refresh step, and exit non-zero if anything failed. End with a summary that separates **succeeded**, **failed**, and **skipped because a dependency failed** (relevant once #6/#8 land).
  - Retry guidance: never suggest re-running with only the failed ids — under full-desired-state semantics that would remove everything that succeeded. Print either one command per failed item, or the complete original selection to re-run.
  - **Done:** `install_id`/`remove_id` return 0 (done), 1 (failed) or 2 (skipped: path changed hands) explicitly and are called as `f && rc=0 || rc=$?`, so one failure no longer aborts the run. The refresh steps always run. The run ends with "Applied X of Y changes", a **Failed** list, a **Not attempted, because something they depend on failed** list, and one retry command per failed step (never a reduced selection), then exits 1. Tests: 4.

- [x] **4. Invalid `OMARCHY_DRY_RUN` values crash or behave strangely** (`:123` vs `:287`)
  - Problem: `run()` uses `(( DRY_RUN ))` (numeric) and line 287 uses `[[ $DRY_RUN == 1 ]]` (string). `OMARCHY_DRY_RUN=true`/`yes` → `true: unbound variable` under `set -u`; `=2` skips the dry-run exit, asks to confirm, prints only `[dry-run]` lines, then still reloads Hyprland.
  - Fix: validate once at startup — accept a small set (`0|1`, optionally `true|false|yes|no`) and **fail with a clear error on anything else** (never default an unrecognised value to `0`, or an intended dry run becomes real). Use the same normalised check everywhere.
  - **Done:** `bool_env` normalises `OMARCHY_DRY_RUN` (and `OMARCHY_PREINSTALLS_YES` / `_ALLOW_REMOVE`) once at startup: `1|0|true|false|yes|no`, case-insensitive, empty = 0; anything else is an error before anything runs. Every check uses the normalised `(( DRY_RUN ))`. Tests: 2.

- [x] **5. Unrecognized arguments are ignored** (`:22`)
  - Problem: `omarchy-preinstalls --dry-run` silently runs for real, guarded only by the confirm prompt.
  - Fix: reject any argument other than `-h`/`--help` with a usage error (or add a real `--dry-run` flag).
  - **Done:** Any argument other than a lone `-h`/`--help` prints the usage and exits 2. No `--dry-run` flag was added. Test: 1.

## Logic gaps

- [x] **6. Docker TUI depends on lazydocker, which the script doesn't know** (confirmed: `omarchy-launch-docker-tui` runs `lazydocker`)
  - Problem: keeping "TUI · Docker" while unchecking "Package · lazydocker" leaves a broken launcher.
  - Fix: detect the conflict and show the proposed adjustment (e.g. keep lazydocker, or also remove the Docker TUI) in the summary before applying anything.
  - **Done:** A `NEEDS` table (`tui|Docker` → `pkg|lazydocker`). If the changes would leave an Omarchy Docker TUI without lazydocker, lazydocker's removal is cancelled ("Keeping …") or lazydocker is added to the installs ("Also installing …"), listed under "Adjusted for dependencies" before the confirm prompt. A combination that was already broken and isn't being changed is left alone. When applying, launchers are removed before packages and packages are installed before launchers, and an item whose dependency (or dependent) failed is not attempted. Tests: 4, plus 2 under #3.

- [x] **7. `OMARCHY_PREINSTALLS_YES=1` without a selection isn't blocked**
  - Problem: docs say it must be paired with `OMARCHY_PREINSTALLS_SELECTION`, but the script still shows the picker and then skips confirmation.
  - Fix: error out (or ignore `YES`) when no selection is provided.
  - **Done:** `OMARCHY_PREINSTALLS_YES=1` without `OMARCHY_PREINSTALLS_SELECTION` is an error before the picker opens. Test: 1.

- [x] **8. One `sudo pacman` call per package** (confirmed: both helpers accept multiple packages)
  - Problem: up to 13 separate pacman transactions; slow, partial failures leave mixed state, and removing packages one at a time fails when packages selected for removal depend on each other.
  - Fix: batch all package removals into one `omarchy-pkg-drop` call and all installs into one `omarchy-pkg-add` call.
  - **Done:** All package removals go in one `omarchy-pkg-drop` call and all installs in one `omarchy-pkg-add` call. Each package's result comes from a fresh `pacman -Qq` afterwards, not from the batch's exit status. Test: 1.

- [x] **9. `hyprctl reload` likely isn't needed at all**
  - Problem: reloading resets any Hyprland settings changed at runtime. The stock scripts reload because they create/delete the `~/.local/state/omarchy/preinstalls-removed` marker (which gates app keybindings); this script never touches the marker, and `.desktop` launchers don't need a Hyprland reload.
  - Fix: confirm that launcher changes don't need a reload, then remove the call (rather than just making it conditional).
  - **Done:** Confirmed that Hyprland only reads the marker (`default/hypr/helpers.lua`, `preinstalled_bindings_enabled`), and web-app key bindings run `omarchy-launch-webapp <url>` directly, not through `.desktop` files. The `hyprctl reload` call is removed; `update-desktop-database` and the icon cache refresh remain. Test: 1.

- [x] **10. Running under `sudo` targets root's home**
  - Problem: `$HOME` becomes root's, so detection and removal act on the wrong directories.
  - Fix: refuse to run when `EUID == 0` (the helpers self-elevate already).
  - **Done:** Exits with an error when `EUID == 0`. Test: 1, run under `unshare -r` (skipped where unprivileged user namespaces are unavailable).

- [x] **11. Detection failures look like "not installed"** (`:31`, `:116`)
  - Problem: only `gum` is checked up front. And even when a helper exists it can fail: `omarchy-pkg-present` just runs `pacman -Q "$pkg" || exit 1`, so a missing package and a failed `pacman` look identical. The picker can then show a wrong state.
  - Fix: at startup, check every command the script calls in one place (`gum`, `pacman`, `omarchy-pkg-add`, `omarchy-pkg-drop`, `omarchy-webapp-install`/`-remove`, `omarchy-tui-install`/`-remove`, `omarchy-mise-install`, `omarchy-cmd-present`) and exit with a clear error if any is missing. For packages, run `pacman -Qq` once and look names up in its output — but capture it directly and check its exit status (e.g. `inventory=$(pacman -Qq) || die …`). Don't copy `omarchy-pkg-drop`'s `< <(pacman -Qq)`, which discards the exit status, so a failed query would become an empty inventory.
  - **Done:** `REQUIRED_COMMANDS` (gum, pacman, omarchy-cmd-present, the pkg/webapp/tui/mise helpers, omarchy-install-hermes-cli) are checked together at startup, and the error names every missing one. Packages are detected from a single `PKG_INVENTORY=$(pacman -Qq) || die …`, and the result is checked again after each package batch. `omarchy-pkg-present` is no longer used. Tests: 2.

- [x] **12. Inventory is already out of date with current Omarchy**
  - Problem: stock `omarchy-remove-preinstalls` also manages `cursor-agent`, `muse`, and `hermes` (all present in `~/.local/bin` on this machine); this script doesn't list them. They also need special ownership checks: `cursor-agent` and `muse` use specific `mise use -g` fingerprints (Cursor's own installer can symlink `cursor-agent`), and `hermes` uses `omarchy-install-hermes-cli --owns`.
  - Fix: add them with the stock ownership checks, and add a check that compares the built-in lists against `$OMARCHY_PATH` (`applications/*.desktop`, `install/user/mise.sh`, `install/omarchy-base.packages`, `bin/omarchy-remove-preinstalls`) and warns when they differ.
  - **Done:** Added `cursor-agent` (exact `"cursor-agent"` fingerprint), `muse` (the `"http:muse[` prefix, installed with the full spec from `mise.sh`) and `hermes` (ownership via `omarchy-install-hermes-cli --owns`, installed with `omarchy-install-hermes-cli`; after removal the script prints the `mise rm -g` / `mise uninstall --all` commands that installer itself recommends). Like `mise.sh`'s `omarchy-cmd-missing` guard, `cursor-agent`/`muse` found elsewhere on `PATH` count as conflicts. `check_inventory_drift` compares the lists with `$OMARCHY_PATH` (`applications/*.desktop` filtered by Exec, the `omarchy-mise-install`/hermes lines in `install/user/mise.sh`, the `omarchy-pkg-drop` list in `bin/omarchy-remove-preinstalls`, `install/omarchy-base.packages`) and warns about differences without stopping. It finds none on this machine. Tests: 9.

- [x] **13. Web app / TUI installs can overwrite a user's own `.desktop` file** (found while fixing #1)
  - Problem: `omarchy-webapp-install` and `omarchy-tui-install` write `~/.local/share/applications/<Name>.desktop` unconditionally (`cat >"$DESKTOP_FILE"`). A file there whose `Exec=` isn't an Omarchy launcher reads as "not installed", so checking the item replaces the user's file.
  - Fix: same three-state model as #1 — absent / Omarchy launcher / conflict — and hide, skip, and report conflicts.
  - **Done:** `launcher_state` classifies `<Name>.desktop` as absent / installed (regular file whose `Exec=` matches the web app or TUI pattern) / conflict (anything else, incl. symlinks — Omarchy copies its launchers, never links them). Conflicts are hidden, skipped, and listed under "Left untouched". Ownership is re-checked right before each install/remove (matters for removal too: `omarchy-tui-remove <name>` deletes the file without looking at it). Tests: 6 new cases; verified with a dry run that the real launchers on this machine are still detected as installed.

- [x] **14. Icon names can be mistaken for files in the current directory** (found while fixing #13)
  - Problem: `omarchy-webapp-install` / `omarchy-tui-install` treat the icon argument as a file path if `[[ -f $ICON_REF ]]`, relative to the current directory. Running the script from a folder containing a file named e.g. `x`, `hey`, or `docker` would install that file as the app's icon.
  - Fix: run the install helpers from a neutral directory (e.g. `cd /` before applying, or a `( cd / && … )` subshell around each call).
  - **Done:** `apply` runs `cd /` first, so no helper sees the caller's directory. Test: 1 (run from a directory containing `x` and `docker`; checks the install helpers' working directory).

## Minor

- [x] **README's `[[ … ]] &&` explanation is wrong** — a false test on the left of `&&` is always exempt from `set -e` (any bash version), including inside a function. The real danger is the function then *returning* that non-zero status (e.g. when the list is its last command) and being called somewhere `set -e` applies, which exits the script at the call site. Fix the explanation in `README.md`, and rewrite lines 258 and 260 as `if` for consistency.
  - **Done:** Explanation rewritten in `README.md` §7; the two diff-loop lines (now in the `ACTION` loop) use `if`, as do the other `[[ … ]] &&` lists.
- [x] **`--help` is incomplete** — document `OMARCHY_PREINSTALLS_SELECTION`, `OMARCHY_PREINSTALLS_YES` (and any new removal opt-in), and the item id format.
  - **Done:** `--help` documents every variable (with accepted yes/no values), the full-desired-state semantics, the removal opt-in, and the item id format.
- [x] **Simplify `args` building** — replace `mapfile -t args < <(printf …)` with `args=("$name" "$url" "$icon")` (and the cli equivalent); declare `args` as `local`.
  - **Done:** `args=("$name" "$url" "$icon")` / `args=("$pkg")`, declared `local`.

## Review round 3

- [x] **R1. Dependency protection missed skipped removals** (#6)
  - Problem: only a *failed* launcher removal protected its package. If `Docker.desktop` changed hands during the confirm prompt (e.g. became a symlink), the launcher was kept but `lazydocker` was still removed.
  - **Done:** before dropping a package, `still_needed` checks each launcher that needs it: if its removal failed, was blocked or was skipped, or its file is still there (real runs), the package is kept. Caused by a skip, it is reported as skipped (exit 0); caused by a failure, as not attempted (exit 1). Test: `test_skipped_launcher_removal_keeps_package_it_runs`.
- [x] **R2. Printed launcher retries bypassed the safe working directory** (#14)
  - **Done:** retries for `omarchy-webapp-install` / `omarchy-tui-install` are printed as `(cd / && …)`. Test: `test_launcher_retry_runs_from_root_dir`.
- [x] **R3. Package retries undid the batching** (#8)
  - **Done:** each failed batch gives one retry command with all its failed packages. Test: `test_package_retry_keeps_the_batch`.
- [x] **R4. Result summary incomplete** (#3)
  - **Done:** every real run that changes something ends with "Applied X of Y changes" and lists **Succeeded**, **Skipped (left untouched)** (with the reason, when another item caused it), **Failed** and **Not attempted**. It is printed even when every action was skipped (exit 0 then). Tests: `test_summary_lists_every_outcome`, `test_summary_shown_when_everything_is_skipped`.
