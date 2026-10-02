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
  omarchy-pkg-present omarchy-pkg-add omarchy-pkg-drop omarchy-cmd-present
  omarchy-webapp-install omarchy-webapp-remove
  omarchy-tui-install omarchy-tui-remove
  omarchy-mise-install
  sudo pacman mise
)
# Real tools the script and the mocks need. Nothing else is on PATH.
SYSTEM_TOOLS=(awk grep cat rm env mkdir)

# ---------------- mocks ----------------

MOCK_SRC="$WORK/mock"
cat >"$MOCK_SRC" <<'EOF'
#!/bin/bash
# Logs "name [arg] [arg] ..." to $MOCK_LOG, then fakes the command's result.
name=${0##*/}
{
  printf '%s' "$name"
  printf ' [%s]' "$@"
  printf '\n'
} >>"$MOCK_LOG"

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
  confirm) exit "${MOCK_GUM_CONFIRM_RC:-0}" ;;
  esac
  ;;
omarchy-pkg-present)
  for pkg in "$@"; do
    grep -qxF "$pkg" "$MOCK_STATE/pkgs" 2>/dev/null || exit 1
  done
  ;;
sudo | pacman | mise)
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
  env -i HOME="$HOME_DIR" PATH="$MOCK_BIN:$SYS_BIN" TERM=dumb \
    MOCK_LOG="$LOG" MOCK_STATE="$STATE" "${env_args[@]}" \
    "$BASH" "$SCRIPT" "${script_args[@]}" >"$OUT" 2>&1
  RC=$?
}

# Fake installed state.
have_webapp() { printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://example.com\n' >"$HOME_DIR/.local/share/applications/$1.desktop"; }
have_tui() { printf '[Desktop Entry]\nExec=xdg-terminal-exec --app-id=TUI.%s -e true\n' "$1" >"$HOME_DIR/.local/share/applications/$1.desktop"; }
have_stub() { printf '#!/bin/bash\n' >"$HOME_DIR/.local/bin/$1"; chmod +x "$HOME_DIR/.local/bin/$1"; }
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

test_missing_gum_is_an_error() {
  rm "$MOCK_BIN/gum"
  run_script
  assert_rc 1
  assert_out_has "'gum' is required"
}

test_picker_lists_all_39_items() {
  local ids
  ids="$(all_ids)"
  [[ $(grep -c . <<<"$ids") == 39 ]] || fail "expected 39 items, got $(grep -c . <<<"$ids")"
  grep -qxF 'webapp|Google Maps' <<<"$ids" || fail "missing webapp|Google Maps"
  grep -qxF 'tui|Disk Usage' <<<"$ids" || fail "missing tui|Disk Usage"
  grep -qxF 'cli|playwright' <<<"$ids" || fail "missing cli|playwright"
  grep -qxF 'pkg|libreoffice-fresh' <<<"$ids" || fail "missing pkg|libreoffice-fresh"
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
  run_script OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian' MOCK_GUM_CONFIRM_RC=1
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
  [[ $(grep -c '\[dry-run\]' "$OUT") == 39 ]] ||
    fail "expected 39 dry-run lines, got $(grep -c '\[dry-run\]' "$OUT")"
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
  assert_called "omarchy-pkg-add [obsidian]"
}

test_removes_unselected_installed_items() {
  have_webapp Discord
  have_tui Docker
  have_stub gh
  have_stub playwright
  have_stub playwright-cli
  have_pkg lazydocker
  have_pkg obsidian
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
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
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_before "omarchy-pkg-drop [lazydocker]" "omarchy-pkg-add [obsidian]"
}

test_refresh_steps_run_after_changes() {
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='webapp|X'
  assert_rc 0
  assert_called "update-desktop-database [$HOME_DIR/.local/share/applications]"
  assert_called "gtk-update-icon-cache [$HOME_DIR/.local/share/icons/hicolor]"
  assert_called "hyprctl [reload]"
}

test_non_omarchy_desktop_file_is_not_an_installed_webapp() {
  printf '[Desktop Entry]\nExec=firefox https://x.com\n' >"$HOME_DIR/.local/share/applications/X.desktop"
  run_script OMARCHY_PREINSTALLS_YES=1 OMARCHY_PREINSTALLS_SELECTION='pkg|obsidian'
  assert_rc 0
  assert_not_called '^omarchy-webapp-remove '
  assert_file_exists "$HOME_DIR/.local/share/applications/X.desktop"
}

# ---------------- run ----------------

mapfile -t TESTS < <(declare -F | awk '{ print $3 }' | grep '^test_')
for name in "${TESTS[@]}"; do t "$name"; done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
