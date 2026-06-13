#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
INSTALL="$PS_REPO_ROOT/install.sh"

# Redirect HOME so the PATH symlinks land in the sandbox, not the real ~/.local/bin.
# PS_OS=unknown skips the OS-specific curator daemon (irrelevant to PATH wiring; keeps
# this test hermetic and fast).
fakehome="$PS_SANDBOX/home"; mkdir -p "$fakehome"

# PATH wiring ENABLED (CCP_SKIP_PATH unset): dispatch is symlinked onto PATH.
HOME="$fakehome" PS_OS=unknown CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
assert_symlink "$fakehome/.local/bin/dispatch" "install links bin/dispatch onto PATH"
tgt="$(readlink "$fakehome/.local/bin/dispatch")"
assert_eq "$tgt" "$PS_REPO_ROOT/bin/dispatch" "symlink points at the repo's bin/dispatch"

# PATH wiring SKIPPED (CCP_SKIP_PATH=1): no symlink created.
fakehome2="$PS_SANDBOX/home2"; mkdir -p "$fakehome2"
HOME="$fakehome2" PS_OS=unknown CCP_SKIP_PATH=1 CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$INSTALL" >/dev/null 2>&1
[ -e "$fakehome2/.local/bin/dispatch" ] && { echo "  FAIL: CCP_SKIP_PATH did not skip the dispatch symlink"; exit 1; }
assert_eq "ok" "ok" "CCP_SKIP_PATH=1 skips the dispatch PATH symlink"

ps_teardown_sandbox
ps_report; exit $?
