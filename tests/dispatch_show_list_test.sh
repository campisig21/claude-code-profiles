#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"

( cd "$repo" && CODEX_DISPATCH_NOW=20260531T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
   bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug showme "x" >/dev/null 2>&1 )
id="20260531T120000Z-showme"

# show: diffstat by default, NO full diff
out="$( cd "$repo" && bash "$ENGINE" show "$id" 2>&1 )"
assert_contains "$out" "needs_review" "show prints status"
assert_contains "$out" "diffstat" "show has diffstat"
case "$out" in *"+ok"*) echo "  FAIL: show leaked full diff without --diff"; exit 1;; esac

# show --diff: full diff present
out="$( cd "$repo" && bash "$ENGINE" show "$id" --diff 2>&1 )"
assert_contains "$out" "+ok" "show --diff includes the full diff"

# list: shows the dispatch with id + status
out="$( cd "$repo" && bash "$ENGINE" list 2>&1 )"
assert_contains "$out" "$id" "list shows id"
assert_contains "$out" "needs_review" "list shows status"

# show unknown id errors
out="$( cd "$repo" && bash "$ENGINE" show nope 2>&1 )"; rc=$?
assert_eq "$rc" "1" "show unknown id errors"

ps_teardown_sandbox
ps_report; exit $?
