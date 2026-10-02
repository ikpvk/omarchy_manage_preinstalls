#!/bin/bash

# Tests for omarchy-preinstalls.
#
# Every test runs the script in a throwaway sandbox: a fake $HOME and a PATH
# that holds only mock Omarchy helpers plus a few basic system tools. The mocks
# log each call instead of doing anything, so nothing on the real system is
# touched and the tests also run on machines without Omarchy (e.g. CI).
#
# Usage: tests/run.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${OMARCHY_PREINSTALLS_SCRIPT:-$ROOT/omarchy-preinstalls}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Commands the script may call. Each one is replaced by the mock below.
MOCKED=(
  gum hyprctl update-desktop-database gtk-update-icon-cache
  omarchy-pkg-add omarchy-pkg-drop omarchy-cmd-present
  omarchy-webapp-install omarchy-webapp-remove
  omarchy-tui-install omarchy-tui-remove
  omarchy-mise-install omarchy-install-hermes-cli
  sudo pacman mise
)
# Real tools the script and the mocks need. Nothing else is on PATH.
SYSTEM_TOOLS=(awk grep cat rm env mkdir ln mv)

# ---------------- mocks ----------------

MOCK_SRC="$WORK/mock"
cat >"$MOCK_SRC" <<'EOF'
#!/bin/bash
# Logs "name [arg] [arg] ..." to $MOCK_LOG, then fakes the command's result.
name=${0##*/}
call=$(
  printf '%s' "$name"
  if (( $# )); then printf ' [%s]' "$@"; fi
)
printf '%s\n' "$call" >>"$MOCK_LOG"

# Calls matching a line (ERE) of $MOCK_STATE/fail fail without doing anything.
if [[ -s $MOCK_STATE/fail ]] && grep -qEf "$MOCK_STATE/fail" <<<"$call"; then
  echo "mock: $name failed" >&2
  exit 1
fi

case $name in
gum)
  case ${1:-} in
  choose)
    # Record the options and pre-selected labels the picker was given.
    shift
    : >"$MOCK_STATE/choose_options"
    while (( $# )); do
      case $1 in
      --header | --height | --selected)
        [[ $1 == --selected ]] && printf '%s\n' "$2" >"$MOCK_STATE/choose_selected"
        shift 2
        ;;
      --*) shift ;;
      *) printf '%s\n' "$1" >>"$MOCK_STATE/choose_options"; shift ;;
      esac
    done
    [[ -f $MOCK_STATE/choose_reply ]] && cat "$MOCK_STATE/choose_reply"
    exit "${MOCK_GUM_CHOOSE_RC:-0}"
    ;;
  confirm)
    # Lets a test change files while the prompt is "open".
    # shellcheck disable=SC1091
    [[ -f $MOCK_STATE/on_confirm ]] && source "$MOCK_STATE/on_confirm"
    exit "${MOCK_GUM_CONFIRM_RC:-0}"
    ;;
  esac
  ;;
pacman)
  # Only the read-only package listing; changes go through the helpers.
  if [[ $* == -Qq ]]; then
    cat "$MOCK_STATE/pkgs"
    exit 0
  fi
  echo "mock: pacman $* must never be called directly by the script" >&2
  exit 99
  ;;
omarchy-pkg-add)
  printf '%s\n' "$@" >>"$MOCK_STATE/pkgs"
  ;;
omarchy-pkg-drop)
  for pkg in "$@"; do
    awk -v p="$pkg" '$0 != p' "$MOCK_STATE/pkgs" >"$MOCK_STATE/pkgs.new"
    cat "$MOCK_STATE/pkgs.new" >"$MOCK_STATE/pkgs"
  done
  ;;
omarchy-webapp-install | omarchy-tui-install)
  printf '%s\n' "$PWD" >>"$MOCK_STATE/cwd"
  ;;
omarchy-webapp-remove | omarchy-tui-remove)
  rm -f "$HOME/.local/share/applications/$1.desktop"
  ;;
omarchy-install-hermes-cli)
  if [[ ${1:-} == --owns ]]; then
    file=$HOME/.local/bin/hermes
    [[ -f $file && ! -L $file ]] && grep -qxF '# Written by omarchy-install-hermes-cli.' "$file"
    exit
  fi
  ;;
sudo | mise)
  echo "mock: $name must never be called directly by the script" >&2
  exit 99
  ;;
esac
exit 0
EOF
chmod +x "$MOCK_SRC"

# ---------------- harness ----------------

PASS=0
FAIL=0

# Fresh sandbox for one test.
setup() {
  SANDBOX="$(mktemp -d "$WORK/test.XXXXXX")"
  HOME_DIR="$SANDBOX/home"
  MOCK_BIN="$SANDBOX/mockbin"
  SYS_BIN="$SANDBOX/sysbin"
  STATE="$SANDBOX/state"
  LOG="$SANDBOX/calls.log"
  OUT="$SANDBOX/output"
  mkdir -p "$HOME_DIR/.local/share/applications" "$HOME_DIR/.local/bin" \
    "$MOCK_BIN" "$SYS_BIN" "$STATE"
  : >"$LOG"
  : >"$STATE/pkgs"
  RUN_WRAPPER=()
  local cmd
  for cmd in "${MOCKED[@]}"; do ln -s "$MOCK_SRC" "$MOCK_BIN/$cmd"; done
  for cmd in "${SYSTEM_TOOLS[@]}"; do ln -s "$(command -v "$cmd")" "$SYS_BIN/$cmd"; done
}

# run_script [VAR=value ...] [-- script-args ...]
# Runs the script with a clean environment (no inherited OMARCHY_* variables).
run_script() {
  local env_args=() script_args=()
  while (( $# )); do
    if [[ $1 == -- ]]; then
      shift
      script_args=("$@")
      break
    fi
    env_args+=("$1")
    shift
  done
  "${RUN_WRAPPER[@]}" env -i HOME="$HOME_DIR" PATH="$MOCK_BIN:$SYS_BIN" TERM=dumb \
    MOCK_LOG="$LOG" MOCK_STATE="$STATE" "${env_args[@]}" \
    "$BASH" "$SCRIPT" "${script_args[@]}" >"$OUT" 2>&1
  RC=$?
}

# Fake installed state.
have_webapp() { printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://example.com\n' >"$HOME_DIR/.local/share/applications/$1.desktop"; }
have_tui() { printf '[Desktop Entry]\nExec=xdg-terminal-exec --app-id=TUI.%s -e true\n' "$1" >"$HOME_DIR/.local/share/applications/$1.desktop"; }
# have_stub <bin> [mise-package]: the wrapper omarchy-mise-install writes.
have_stub() {
  local bin="$1" pkg="${2:-$1}"
  printf '#!/bin/bash\nexport MISE_MINIMUM_RELEASE_AGE=0\nmise use -g --quiet "%s" || exit 1\nexec mise x "%s" -- "%s" "$@"\n' \
    "$pkg" "$pkg" "$bin" >"$HOME_DIR/.local/bin/$bin"
  chmod +x "$HOME_DIR/.local/bin/$bin"
}
# have_legacy_playwright_cli <1|2|3> [package]: the old omarchy-npx-install
# wrapper formats, oldest first.
have_legacy_playwright_cli() {
  local pkg="${2:-playwright}" file="$HOME_DIR/.local/bin/playwright-cli"
  case $1 in
  1) printf '#!/bin/bash\nexec npx --yes %s "$@"\n' "$pkg" >"$file" ;;
  2) printf '#!/bin/bash\nexec mise exec node@latest -- npx --yes %s "$@"\n' "$pkg" >"$file" ;;
  3) printf '#!/bin/bash\npackage="%s"\ncommand="playwright-cli"\n' "$pkg" >"$file" ;;
  esac
  chmod +x "$file"
}
# A launcher at an item's .desktop path that Omarchy didn't write.
have_user_launcher() { printf '[Desktop Entry]\nName=%s\nExec=firefox # users own %s\n' "$1" "$1" >"$HOME_DIR/.local/share/applications/$1.desktop"; }
# A file at a stub path that Omarchy didn't write (e.g. a real install).
have_user_bin() { printf '#!/bin/bash\necho users own %s\n' "$1" >"$HOME_DIR/.local/bin/$1"; chmod +x "$HOME_DIR/.local/bin/$1"; }
have_pkg() { printf '%s\n' "$1" >>"$STATE/pkgs"; }

# Every item id, read from the options the script hands to the picker
# ("label:id"). Call before setting up state; it clears the call log.
all_ids() {
  run_script MOCK_GUM_CHOOSE_RC=1
  : >"$LOG"
  awk -F ':' '{ print $NF }' "$STATE/choose_options"
}

fail() {
  printf '  FAIL: %s\n' "$1"
  printf '    output:\n'; sed 's/^/      /' "$OUT" 2>/dev/null || true
  printf '    calls:\n'; sed 's/^/      /' "$LOG" 2>/dev/null || true
  CURRENT_FAILED=1
}
assert_rc() { [[ $RC == "$1" ]] || fail "exit code $RC, expected $1"; }
assert_out_has() { grep -qF -- "$1" "$OUT" || fail "output lacks: $1"; }
assert_called() { grep -qxF -- "$1" "$LOG" || fail "not called: $1"; }
assert_not_called() { ! grep -qE -- "$1" "$LOG" || fail "unexpectedly called: $1"; }
assert_out_lacks() { ! grep -qF -- "$1" "$OUT" || fail "output unexpectedly has: $1"; }
assert_file_exists() { [[ -e $1 ]] || fail "missing file: $1"; }
assert_file_gone() { [[ ! -e $1 ]] || fail "file still exists: $1"; }
assert_before() {
  local a b
  a=$(grep -nxF -- "$1" "$LOG" | head -1 | cut -d: -f1)
  b=$(grep -nxF -- "$2" "$LOG" | head -1 | cut -d: -f1)
  [[ -n $a && -n $b && $a -lt $b ]] || fail "expected '$1' before '$2'"
}

# Runs one test function and records the result.
t() {
  CURRENT_FAILED=0
  setup
  "$1"
  if (( CURRENT_FAILED )); then
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$1"
  else
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$1"
  fi
}

# Any action the script takes that changes something.
ACTIONS='^(omarchy-(webapp|tui)-(install|remove)|omarchy-mise-install|omarchy-pkg-(add|drop)) '

# ---------------- tests ----------------

test_sandbox_only_reaches_mocks() {
  local cmd
  for cmd in "${MOCKED[@]}"; do
    [[ $(PATH="$MOCK_BIN:$SYS_BIN" command -v "$cmd") == "$MOCK_BIN/$cmd" ]] ||
      fail "$cmd does not resolve to the mock"
  done
  ! PATH="$MOCK_BIN:$SYS_BIN" command -v omarchy-refresh-applications >/dev/null ||
    fail "real Omarchy commands are reachable from the sandbox"
}

test_help_exits_without_doing_anything() {
  run_script -- --help
  assert_rc 0
  assert_out_has "Usage: omarchy-preinstalls"
  [[ ! -s $LOG ]] || fail "--help called other commands"
}

test_missing_commands_are_an_error() {
  rm "$MOCK_BIN/gum" "$MOCK_BIN/omarchy-mise-install"
  run_script
  assert_rc 1
  assert_out_has "required command(s) not found: gum omarchy-mise-install"
  [[ ! -s $LOG ]] || fail "commands were called"
}

test_picker_lists_all_42_items() {
  local ids
  ids="$(all_ids)"
  [[ $(grep -c . <<<"$ids") == 42 ]] || fail "expected 42 items, got $(grep -c . <<<"$ids")"
  grep -qxF 'webapp|Google Maps' <<<"$ids" || fail "missing webapp|Google Maps"
  grep -qxF 'tui|Disk Usage' <<<"$ids" || fail "missing tui|Disk Usage"
  grep -qxF 'cli|playwright' <<<"$ids" || fail "missing cli|playwright"
  grep -qxF 'pkg|libreoffice-fresh' <<<"$ids" || fail "missing pkg|libreoffice-fresh"
  grep -qxF 'cli|cursor-agent' <<<"$ids" || fail "missing cli|cursor-agent"
  grep -qxF 'cli|muse' <<<"$ids" || fail "missing cli|muse"
  grep -qxF 'cli|hermes' <<<"$ids" || fail "missing cli|hermes"
}

test_picker_preselects_installed_items() {
  have_webapp Discord
  have_pkg obsidian
  printf 'webapp|Discord\npkg|obsidian\n' >"$STATE/choose_reply"
  run_script
  assert_rc 0
  [[ $(cat "$STATE/choose_selected") == "Web App · Discord,Package · obsidian" ]] ||
    fail "pre-selected labels were: $(cat "$STATE/choose_selected")"
  assert_out_has "Nothing to do."
}

test_picker_cancel_changes_nothing() {
  have_webapp Discord
  run_script MOCK_GUM_CHOOSE_RC=130
  assert_rc 0
  assert_out_has "Cancelled."
  assert_not_called "$ACTIONS"
}

test_declined_confirmation_changes_nothing() {
  have_webapp Discord
  run_script OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian' MOCK_GUM_CONFIRM_RC=1
  assert_rc 0
  assert_out_has "Will remove:"
  assert_called "gum [confirm] [Apply these changes?]"
  assert_out_has "Cancelled."
  assert_not_called "$ACTIONS"
}

test_nothing_to_do_when_selection_matches_state() {
  have_webapp YouTube
  have_tui Docker
  have_stub gh
  have_pkg obsidian
  run_script OMARCHY_PREINSTALLS_SELECTION=$'webapp|YouTube\ntui|Docker\ncli|gh\npkg|obsidian'
  assert_rc 0
  assert_out_has "Nothing to do."
  assert_not_called "$ACTIONS"
}

test_dry_run_prints_every_install_and_runs_nothing() {
  local ids
  ids="$(all_ids)"
  : >"$LOG"
  run_script OMARCHY_DRY_RUN=1 OMARCHY_PREINSTALLS_SELECTION="$ids"
  assert_rc 0
  # 11 web apps + 2 TUIs + 16 CLI tools, and one call for all 13 packages.
  [[ $(grep -c '\[dry-run\]' "$OUT") == 30 ]] ||
    fail "expected 30 dry-run lines, got $(grep -c '\[dry-run\]' "$OUT")"
  assert_out_has "Dry run — no changes made."
  assert_not_called "$ACTIONS"
  assert_not_called '^hyprctl '
}

test_installs_pass_the_right_arguments() {
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\nwebapp|HEY\nwebapp|Zoom\ntui|Disk Usage\ntui|Docker\ncli|codex\ncli|playwright\ncli|omp\npkg|obsidian'
  assert_rc 0
  assert_called "omarchy-webapp-install [Discord] [https://discord.com/channels/@me] [omarchy-discord]"
  assert_called "omarchy-webapp-install [HEY] [https://app.hey.com] [hey] [omarchy-webapp-handler-hey %u] [x-scheme-handler/mailto]"
  assert_called "omarchy-webapp-install [Zoom] [https://app.zoom.us] [zoom] [omarchy-webapp-handler-zoom %u] [x-scheme-handler/zoommtg;x-scheme-handler/zoomus]"
  assert_called 'omarchy-tui-install [Disk Usage] [bash -c "dua i /"] [float] [disk-usage]'
  assert_called "omarchy-tui-install [Docker] [omarchy-launch-docker-tui] [tile] [docker]"
  assert_called "omarchy-mise-install [codex]"
  assert_called "omarchy-mise-install [npm:playwright] [playwright]"
  assert_called "omarchy-mise-install [github:can1357/oh-my-pi] [omp]"
  # Docker TUI needs lazydocker, so it is added to the one package call.
  assert_called "omarchy-pkg-add [obsidian] [lazydocker]"
}

test_removes_unselected_installed_items() {
  have_webapp Discord
  have_tui Docker
  have_stub gh
  have_stub playwright npm:playwright
  have_legacy_playwright_cli 1
  have_pkg lazydocker
  have_pkg obsidian
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_called "omarchy-webapp-remove [Discord]"
  assert_called "omarchy-tui-remove [Docker]"
  assert_called "omarchy-pkg-drop [lazydocker]"
  assert_not_called '^omarchy-pkg-drop \[obsidian\]'
  assert_file_gone "$HOME_DIR/.local/bin/gh"
  assert_file_gone "$HOME_DIR/.local/bin/playwright"
  assert_file_gone "$HOME_DIR/.local/bin/playwright-cli"
}

test_removals_run_before_installs() {
  have_pkg lazydocker
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_before "omarchy-pkg-drop [lazydocker]" "omarchy-pkg-add [obsidian]"
}

test_refresh_steps_run_after_changes() {
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='webapp|X'
  assert_rc 0
  assert_called "update-desktop-database [$HOME_DIR/.local/share/applications]"
  assert_called "gtk-update-icon-cache [$HOME_DIR/.local/share/icons/hicolor]"
  assert_not_called '^hyprctl '
}

test_launcher_user_file_is_never_removed() {
  have_user_launcher X
  have_user_launcher Docker
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_not_called '^omarchy-(webapp|tui)-remove '
  assert_file_exists "$HOME_DIR/.local/share/applications/X.desktop"
  assert_file_exists "$HOME_DIR/.local/share/applications/Docker.desktop"
  assert_out_has "Left untouched (not installed by Omarchy):"
  assert_out_has "Web App · X ($HOME_DIR/.local/share/applications/X.desktop)"
  assert_out_has "TUI · Docker ($HOME_DIR/.local/share/applications/Docker.desktop)"
}

test_launcher_user_file_is_never_overwritten() {
  have_user_launcher X
  have_user_launcher Docker
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|X\ntui|Docker'
  assert_rc 0
  assert_not_called '^omarchy-(webapp|tui)-install '
  grep -qs 'users own X' "$HOME_DIR/.local/share/applications/X.desktop" || fail "X.desktop was modified"
  grep -qs 'users own Docker' "$HOME_DIR/.local/share/applications/Docker.desktop" || fail "Docker.desktop was modified"
}

test_launcher_symlink_is_unmanaged() {
  mkdir -p "$HOME_DIR/elsewhere"
  printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://x.com/\n' >"$HOME_DIR/elsewhere/X.desktop"
  ln -s "$HOME_DIR/elsewhere/X.desktop" "$HOME_DIR/.local/share/applications/X.desktop"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='webapp|X'
  assert_rc 0
  assert_not_called '^omarchy-webapp-(install|remove) '
  [[ -L $HOME_DIR/.local/share/applications/X.desktop ]] || fail "symlink was replaced"
  assert_out_has "Web App · X ($HOME_DIR/.local/share/applications/X.desktop)"
}

test_picker_hides_unmanaged_launchers() {
  have_user_launcher X
  have_user_launcher Docker
  run_script MOCK_GUM_CHOOSE_RC=1
  ! grep -qE '(webapp\|X|tui\|Docker)$' "$STATE/choose_options" || fail "unmanaged launcher offered in picker"
  [[ $(grep -c . "$STATE/choose_options") == 40 ]] || fail "expected 40 options"
}

test_launcher_rechecked_before_install() {
  printf '%s\n' "printf '[Desktop Entry]\nExec=firefox # users own X\n' >\"\$HOME/.local/share/applications/X.desktop\"" >"$STATE/on_confirm"
  run_script OMARCHY_PREINSTALLS_SELECTION='webapp|X'
  assert_rc 0
  assert_out_has "  + Web App · X"
  assert_not_called '^omarchy-webapp-install '
  grep -qs 'users own X' "$HOME_DIR/.local/share/applications/X.desktop" || fail "X.desktop was modified"
  assert_out_has "Skipped Web App · X: $HOME_DIR/.local/share/applications/X.desktop appeared since the check"
}

test_launcher_rechecked_before_removal() {
  have_tui Docker
  printf '%s\n' "printf '[Desktop Entry]\nExec=docker-desktop # users own Docker\n' >\"\$HOME/.local/share/applications/Docker.desktop\"" >"$STATE/on_confirm"
  run_script OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_out_has "  - TUI · Docker"
  assert_not_called '^omarchy-tui-remove '
  grep -qs 'users own Docker' "$HOME_DIR/.local/share/applications/Docker.desktop" || fail "Docker.desktop was deleted"
  assert_out_has "Skipped TUI · Docker: $HOME_DIR/.local/share/applications/Docker.desktop is no longer an Omarchy launcher"
}

test_cli_user_file_is_never_removed() {
  have_user_bin claude
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_file_exists "$HOME_DIR/.local/bin/claude"
  assert_out_has "Left untouched (not installed by Omarchy):"
  assert_out_has "CLI Tool · claude ($HOME_DIR/.local/bin/claude)"
  assert_out_lacks "  - CLI Tool · claude"
}

test_cli_user_file_is_never_overwritten() {
  have_user_bin claude
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='cli|claude'
  assert_rc 0
  assert_not_called '^omarchy-mise-install '
  grep -qs 'users own claude' "$HOME_DIR/.local/bin/claude" || fail "claude was modified"
}

test_cli_symlink_is_unmanaged() {
  mkdir -p "$HOME_DIR/opt"
  printf '#!/bin/bash\nmise use -g --quiet "claude" || exit 1\n' >"$HOME_DIR/opt/claude"
  ln -s "$HOME_DIR/opt/claude" "$HOME_DIR/.local/bin/claude"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  [[ -L $HOME_DIR/.local/bin/claude ]] || fail "symlink was removed"
  assert_out_has "CLI Tool · claude ($HOME_DIR/.local/bin/claude)"
}

test_cli_stub_for_another_package_is_unmanaged() {
  have_stub gh some-other-tool
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_file_exists "$HOME_DIR/.local/bin/gh"
  assert_out_has "CLI Tool · gh ($HOME_DIR/.local/bin/gh)"
}

test_picker_hides_unmanaged_cli_items() {
  have_user_bin claude
  run_script MOCK_GUM_CHOOSE_RC=1
  ! grep -q 'cli|claude$' "$STATE/choose_options" || fail "cli|claude offered in picker"
  [[ $(grep -c . "$STATE/choose_options") == 41 ]] || fail "expected 41 options"
}

test_playwright_cli_kept_when_not_a_stub() {
  have_stub playwright npm:playwright
  have_user_bin playwright-cli
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_file_gone "$HOME_DIR/.local/bin/playwright"
  assert_file_exists "$HOME_DIR/.local/bin/playwright-cli"
  assert_out_has "Left $HOME_DIR/.local/bin/playwright-cli in place (not an Omarchy stub)."
}

test_cli_removal_explains_mise_cleanup() {
  have_stub ghui npm:@kitlangton/ghui
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_file_gone "$HOME_DIR/.local/bin/ghui"
  assert_out_has "mise still has the tools installed"
  assert_out_has "  mise unuse -g npm:@kitlangton/ghui"
}

test_cli_rechecked_before_removal() {
  have_stub gh
  printf '%s\n' "printf '#!/bin/bash\necho users own gh\n' >\"\$HOME/.local/bin/gh\"" >"$STATE/on_confirm"
  run_script OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_out_has "  - CLI Tool · gh"
  grep -qs 'users own gh' "$HOME_DIR/.local/bin/gh" || fail "replaced gh was deleted"
  assert_out_has "Skipped CLI Tool · gh: $HOME_DIR/.local/bin/gh is no longer an Omarchy stub"
  assert_out_lacks "mise unuse -g gh"
}

test_cli_rechecked_before_install() {
  printf '%s\n' "printf '#!/bin/bash\necho users own claude\n' >\"\$HOME/.local/bin/claude\"" >"$STATE/on_confirm"
  run_script OMARCHY_PREINSTALLS_SELECTION='cli|claude'
  assert_rc 0
  assert_out_has "  + CLI Tool · claude"
  assert_not_called '^omarchy-mise-install '
  grep -qs 'users own claude' "$HOME_DIR/.local/bin/claude" || fail "claude was modified"
  assert_out_has "Skipped CLI Tool · claude: $HOME_DIR/.local/bin/claude appeared since the check"
}

test_legacy_playwright_cli_formats_are_removed() {
  local format pkg
  for format in 1 2 3; do
    for pkg in playwright playwright-cli; do
      have_stub playwright npm:playwright
      have_legacy_playwright_cli "$format" "$pkg"
      run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
      [[ ! -e $HOME_DIR/.local/bin/playwright-cli ]] ||
        fail "format $format ($pkg) playwright-cli was not removed"
    done
  done
}

test_playwright_cli_mise_stub_for_other_tool_is_kept() {
  have_stub playwright npm:playwright
  have_stub playwright-cli some-unrelated-tool
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_file_gone "$HOME_DIR/.local/bin/playwright"
  assert_file_exists "$HOME_DIR/.local/bin/playwright-cli"
  assert_out_has "Left $HOME_DIR/.local/bin/playwright-cli in place (not an Omarchy stub)."
}

# ---- scripted selection ----

test_unknown_selection_id_is_an_error() {
  have_pkg obsidian
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=$'pkg|Obsidian\nwebapp|Discord'
  assert_rc 1
  assert_out_has "unknown item id(s) in the selection; nothing was changed:"
  assert_out_has "  pkg|Obsidian"
  assert_not_called "$ACTIONS"
}

test_scripted_removal_needs_opt_in() {
  have_webapp Discord
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 1
  assert_out_has "the selection would remove 1 item(s); nothing was changed."
  assert_out_has "OMARCHY_PREINSTALLS_ALLOW_REMOVE=1"
  assert_not_called "$ACTIONS"
}

test_scripted_install_only_needs_no_opt_in() {
  have_webapp Discord
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\npkg|obsidian'
  assert_rc 0
  assert_called "omarchy-pkg-add [obsidian]"
}

test_empty_selection_removes_everything_with_opt_in() {
  have_webapp Discord
  have_pkg obsidian
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_not_called '^gum \[choose\]'
  assert_called "omarchy-webapp-remove [Discord]"
  assert_called "omarchy-pkg-drop [obsidian]"
}

test_empty_selection_without_opt_in_is_refused() {
  have_webapp Discord
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 1
  assert_not_called '^gum \[choose\]'
  assert_not_called "$ACTIONS"
}

test_dry_run_of_removals_notes_opt_in() {
  have_webapp Discord
  run_script OMARCHY_DRY_RUN=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_out_has "Note: a real run needs OMARCHY_PREINSTALLS_ALLOW_REMOVE=1"
  assert_out_has "[dry-run] omarchy-webapp-remove Discord"
  assert_not_called "$ACTIONS"
}

test_yes_without_selection_is_an_error() {
  run_script OMARCHY_PREINSTALLS_YES=1
  assert_rc 1
  assert_out_has "OMARCHY_PREINSTALLS_YES=1 requires OMARCHY_PREINSTALLS_SELECTION"
  [[ ! -s $LOG ]] || fail "commands were called"
}

# ---- arguments and environment ----

test_unknown_argument_is_rejected() {
  run_script -- --dry-run
  assert_rc 2
  assert_out_has "unexpected argument: --dry-run"
  [[ ! -s $LOG ]] || fail "commands were called"
}

test_dry_run_accepts_true() {
  run_script OMARCHY_DRY_RUN=true OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_out_has "Dry run — no changes made."
  assert_not_called "$ACTIONS"
}

test_invalid_boolean_is_an_error() {
  local var
  for var in OMARCHY_DRY_RUN OMARCHY_PREINSTALLS_YES OMARCHY_PREINSTALLS_ALLOW_REMOVE; do
    : >"$LOG"
    run_script "$var=2" OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
    [[ $RC == 1 ]] || fail "$var=2: exit code $RC, expected 1"
    grep -qF "$var must be 1 or 0" "$OUT" || fail "$var=2: no error message"
    [[ ! -s $LOG ]] || fail "$var=2: commands were called"
  done
}

test_root_is_refused() {
  if ! unshare -r true 2>/dev/null; then
    echo "  (skipped: unprivileged user namespaces unavailable)"
    return
  fi
  RUN_WRAPPER=(unshare -r)
  run_script
  assert_rc 1
  assert_out_has "not as root or with sudo"
  [[ ! -s $LOG ]] || fail "commands were called"
}

test_failed_package_query_is_an_error() {
  echo '^pacman ' >"$STATE/fail"
  run_script
  assert_rc 1
  assert_out_has "could not list installed packages"
  assert_not_called '^gum \[choose\]'
}

# ---- failures ----

test_failure_continues_and_reports() {
  echo '^omarchy-webapp-install \[Discord\]' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|Discord\nwebapp|X\npkg|obsidian'
  assert_rc 1
  assert_called "omarchy-webapp-install [X] [https://x.com/] [x]"
  assert_called "omarchy-pkg-add [obsidian]"
  assert_called "update-desktop-database [$HOME_DIR/.local/share/applications]"
  assert_out_has "Applied 2 of 3 changes."
  assert_out_has "  ! Web App · Discord (install)"
  assert_out_has "  (cd / && omarchy-webapp-install Discord https://discord.com/channels/@me omarchy-discord)"
}

test_failed_package_batch_is_reported_per_package() {
  have_pkg pinta
  have_pkg obsidian
  echo '^omarchy-pkg-drop ' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 1
  assert_out_has "  ! Package · pinta (remove)"
  assert_out_has "  ! Package · obsidian (remove)"
}

test_failed_package_blocks_launcher_that_needs_it() {
  echo '^omarchy-pkg-add ' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='tui|Docker'
  assert_rc 1
  assert_not_called '^omarchy-tui-install '
  assert_out_has "  ! TUI · Docker (install; needs Package · lazydocker, which failed)"
  assert_out_has "  omarchy-pkg-add lazydocker"
}

test_failed_launcher_removal_keeps_package_it_runs() {
  have_tui Docker
  have_pkg lazydocker
  echo '^omarchy-tui-remove ' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 1
  assert_not_called '^omarchy-pkg-drop '
  assert_out_has "  ! Package · lazydocker (remove; TUI · Docker still needs it)"
}

test_skipped_launcher_removal_keeps_package_it_runs() {
  have_tui Docker
  have_pkg lazydocker
  mkdir -p "$HOME_DIR/elsewhere"
  printf '%s\n' "mv \"\$HOME/.local/share/applications/Docker.desktop\" \"\$HOME/elsewhere/Docker.desktop\"" \
    "ln -s \"\$HOME/elsewhere/Docker.desktop\" \"\$HOME/.local/share/applications/Docker.desktop\"" >"$STATE/on_confirm"
  run_script OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_not_called '^omarchy-tui-remove '
  assert_not_called '^omarchy-pkg-drop '
  assert_out_has "  = Package · lazydocker (remove; TUI · Docker still needs it)"
}

test_launcher_retry_runs_from_root_dir() {
  echo '^omarchy-tui-install ' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='tui|Disk Usage'
  assert_rc 1
  assert_out_has '  (cd / && omarchy-tui-install Disk\ Usage bash\ -c\ \"dua\ i\ /\" float disk-usage)'
}

test_package_retry_keeps_the_batch() {
  have_pkg pinta
  have_pkg obsidian
  echo '^omarchy-pkg-drop ' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 1
  assert_out_has "  omarchy-pkg-drop pinta obsidian"
  [[ $(grep -c '^  omarchy-pkg-drop' "$OUT") == 1 ]] || fail "expected one package retry command"
}

test_summary_lists_every_outcome() {
  have_webapp Discord
  have_stub gh
  printf '%s\n' "printf '#!/bin/bash\necho users own gh\n' >\"\$HOME/.local/bin/gh\"" >"$STATE/on_confirm"
  echo '^omarchy-webapp-install \[X\]' >"$STATE/fail"
  run_script OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|X\npkg|obsidian'
  assert_rc 1
  assert_out_has "Applied 2 of 4 changes."
  assert_out_has "Succeeded:"
  assert_out_has "  + Package · obsidian (install)"
  assert_out_has "  + Web App · Discord (remove)"
  assert_out_has "Skipped (left untouched):"
  assert_out_has "  = CLI Tool · gh (remove)"
  assert_out_has "  ! Web App · X (install)"
}

test_summary_shown_when_everything_is_skipped() {
  have_stub gh
  printf '%s\n' "printf '#!/bin/bash\necho users own gh\n' >\"\$HOME/.local/bin/gh\"" >"$STATE/on_confirm"
  run_script OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_out_has "Applied 0 of 1 changes."
  assert_out_has "  = CLI Tool · gh (remove)"
}

# ---- packages ----

test_packages_are_batched() {
  have_pkg pinta
  have_pkg obsidian
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=$'pkg|aether\npkg|kdenlive'
  assert_rc 0
  assert_called "omarchy-pkg-drop [pinta] [obsidian]"
  assert_called "omarchy-pkg-add [aether] [kdenlive]"
  [[ $(grep -c '^omarchy-pkg-' "$LOG") == 2 ]] || fail "expected exactly two package calls"
}

# ---- dependencies ----

test_kept_docker_tui_keeps_lazydocker() {
  have_tui Docker
  have_pkg lazydocker
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='tui|Docker'
  assert_rc 0
  assert_out_has "Keeping Package · lazydocker: TUI · Docker needs it."
  assert_out_has "Nothing to do."
  assert_not_called '^omarchy-pkg-drop '
}

test_installed_docker_tui_brings_lazydocker() {
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='tui|Docker'
  assert_rc 0
  assert_out_has "Also installing Package · lazydocker: TUI · Docker needs it."
  assert_before "omarchy-pkg-add [lazydocker]" "omarchy-tui-install [Docker] [omarchy-launch-docker-tui] [tile] [docker]"
}

test_removing_both_docker_items_is_allowed() {
  have_tui Docker
  have_pkg lazydocker
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_before "omarchy-tui-remove [Docker]" "omarchy-pkg-drop [lazydocker]"
}

test_preexisting_missing_dependency_is_left_alone() {
  have_tui Docker
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='tui|Docker'
  assert_rc 0
  assert_out_has "Nothing to do."
}

# ---- refresh and environment of the helpers ----

test_hyprland_is_never_reloaded() {
  have_webapp Discord
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=$'pkg|obsidian\ntui|Docker'
  assert_rc 0
  assert_not_called '^hyprctl '
}

test_install_helpers_run_from_root_dir() {
  mkdir -p "$SANDBOX/cwd"
  : >"$SANDBOX/cwd/x"
  : >"$SANDBOX/cwd/docker"
  cd "$SANDBOX/cwd" || return
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=$'webapp|X\ntui|Docker'
  cd - >/dev/null || return
  assert_rc 0
  [[ $(grep -c . "$STATE/cwd") == 2 ]] || fail "expected two launcher installs"
  ! grep -qvx / "$STATE/cwd" || fail "install helpers ran outside /: $(cat "$STATE/cwd")"
}

# ---- cursor-agent, muse, hermes ----

test_muse_stub_matched_by_prefix() {
  have_stub muse 'http:muse[url=https://example.com/other-launcher.sh,bin=muse]'
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_file_gone "$HOME_DIR/.local/bin/muse"
}

test_cursor_agent_stub_is_removed() {
  have_stub cursor-agent
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_file_gone "$HOME_DIR/.local/bin/cursor-agent"
  assert_out_has "  mise unuse -g cursor-agent"
}

test_muse_and_cursor_agent_installs() {
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION=$'cli|muse\ncli|cursor-agent'
  assert_rc 0
  assert_called "omarchy-mise-install [cursor-agent]"
  assert_called "omarchy-mise-install [http:muse[url=https://api.meta.ai/muse-launcher.sh,bin=muse,version_list_url=https://api.meta.ai/muse-code/channels/muse-stable,version_json_path=.version]] [muse]"
}

test_path_guarded_cli_elsewhere_on_path_is_unmanaged() {
  printf '#!/bin/bash\n' >"$SYS_BIN/cursor-agent"
  chmod +x "$SYS_BIN/cursor-agent"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='cli|cursor-agent'
  assert_rc 0
  assert_not_called '^omarchy-mise-install '
  assert_out_has "CLI Tool · cursor-agent ($SYS_BIN/cursor-agent)"
}

test_hermes_uses_its_own_installer() {
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='cli|hermes'
  assert_rc 0
  assert_called "omarchy-install-hermes-cli"
  assert_not_called '^omarchy-mise-install '
}

test_hermes_wrapper_removed_only_when_owned() {
  printf '#!/bin/bash\n\n# Written by omarchy-install-hermes-cli.\n' >"$HOME_DIR/.local/bin/hermes"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_file_gone "$HOME_DIR/.local/bin/hermes"
  assert_out_has "  mise uninstall --all 'pipx:hermes-agent[extras=all]'"

  printf '#!/bin/bash\nexec ~/.hermes/bin/hermes "$@"\n' >"$HOME_DIR/.local/bin/hermes"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_ALLOW_REMOVE=1 OMARCHY_PREINSTALLS_SELECTION=
  assert_rc 0
  assert_file_exists "$HOME_DIR/.local/bin/hermes"
  assert_out_has "CLI Tool · hermes ($HOME_DIR/.local/bin/hermes)"
}

# ---- inventory drift ----

# fake_omarchy_tree <ids>: a minimal $OMARCHY_PATH shipping exactly <ids>.
fake_omarchy_tree() {
  local root="$SANDBOX/omarchy" id pkgs=()
  mkdir -p "$root/applications" "$root/install/user" "$root/bin"
  printf '[Desktop Entry]\nExec=foot\n' >"$root/applications/foot.desktop"
  printf '# Comment mentioning omarchy-mise-install nothing\nmise settings set x y\n' >"$root/install/user/mise.sh"
  : >"$root/install/omarchy-base.packages"
  while IFS= read -r id; do
    case $id in
    webapp\|*) printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://example.com\n' >"$root/applications/${id#*|}.desktop" ;;
    tui\|*) printf '[Desktop Entry]\nExec=xdg-terminal-exec --app-id=TUI.tile -e true\n' >"$root/applications/${id#*|}.desktop" ;;
    cli\|hermes) echo 'omarchy-install-hermes-cli || true' >>"$root/install/user/mise.sh" ;;
    cli\|cursor-agent) echo 'omarchy-cmd-missing cursor-agent && omarchy-mise-install cursor-agent' >>"$root/install/user/mise.sh" ;;
    cli\|*) echo "  omarchy-mise-install \"some:pkg[a=b]\" ${id#*|}" >>"$root/install/user/mise.sh" ;;
    pkg\|*)
      pkgs+=("${id#*|}")
      echo "${id#*|}" >>"$root/install/omarchy-base.packages"
      ;;
    esac
  done <<<"$1"
  {
    printf '#!/bin/bash\n  omarchy-pkg-drop \\\n'
    printf '    %s \\\n' "${pkgs[@]:0:${#pkgs[@]}-1}"
    printf '    %s\nfi\n' "${pkgs[-1]}"
  } >"$root/bin/omarchy-remove-preinstalls"
  echo "$root"
}

test_drift_silent_when_lists_match() {
  local root
  root=$(fake_omarchy_tree "$(all_ids)")
  run_script OMARCHY_PATH="$root" MOCK_GUM_CHOOSE_RC=1
  assert_out_lacks "Warning"
}

test_drift_warns_about_differences() {
  local root
  root=$(fake_omarchy_tree "$(all_ids | grep -vxF -e 'cli|grok' -e 'pkg|pinta')")
  printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://new.example\n' >"$root/applications/New App.desktop"
  echo 'omarchy-mise-install newtool' >>"$root/install/user/mise.sh"
  run_script OMARCHY_PATH="$root" MOCK_GUM_CHOOSE_RC=1
  assert_out_has "Warning: this script's list of preinstalls differs from Omarchy at $root:"
  assert_out_has "Web apps/TUIs shipped by Omarchy but not managed here: New App"
  assert_out_has "CLI tools shipped by Omarchy but not managed here: newtool"
  assert_out_has "CLI tools managed here but no longer shipped by Omarchy: grok"
  assert_out_has "Packages managed here but no longer shipped by Omarchy: pinta"
  assert_out_has "Packages not in omarchy-base.packages: pinta"
}

# ---------------- run ----------------

mapfile -t TESTS < <(declare -F | awk '{ print $3 }' | grep '^test_')
for name in "${TESTS[@]}"; do t "$name"; done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
