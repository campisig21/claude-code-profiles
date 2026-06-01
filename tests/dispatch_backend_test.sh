#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

# --- resolver ---------------------------------------------------------------
assert_eq "$(d_backend_args codex)" ""        "codex backend -> no extra flags"
assert_eq "$(d_backend_args)"      ""         "empty/default backend -> no extra flags"
assert_eq "$(d_backend_args local)" "-p local" "local backend -> -p <profile>"
( CODEX_DISPATCH_LOCAL_PROFILE=ws; assert_eq "$(d_backend_args local)" "-p ws" "profile override honored" )
d_backend_args bogus >/dev/null 2>&1; assert_eq "$?" "1" "unknown backend returns nonzero"

# --- arg threading into the codex invocation --------------------------------
fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
log="$PS_SANDBOX/argv.log"; : > "$log"

# exec with local backend args splices "-p local" into the codex argv
( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash -c 'source "'"$PS_REPO_ROOT"'/lib/jsonutil.sh"; source "'"$PS_REPO_ROOT"'/lib/dispatch.sh";
             tmp="$(mktemp)"; d_codex_exec "'"$repo"'" "$tmp" "do it" -p local >/dev/null; rm -f "$tmp"' )
assert_contains "$(cat "$log")" "-p local" "exec splices backend args"
assert_contains "$(cat "$log")" "exec"     "exec still calls codex exec"

# exec with NO backend args is unchanged (no stray -p)
: > "$log"
( cd "$repo" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash -c 'source "'"$PS_REPO_ROOT"'/lib/jsonutil.sh"; source "'"$PS_REPO_ROOT"'/lib/dispatch.sh";
             tmp="$(mktemp)"; d_codex_exec "'"$repo"'" "$tmp" "do it" >/dev/null; rm -f "$tmp"' )
case "$(cat "$log")" in *"-p "*) echo "  FAIL: default exec leaked a -p flag"; exit 1;; esac

# --- --backend records the sidecar field ------------------------------------
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
( cd "$repo" && CODEX_DISPATCH_NOW=20260601T100000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log" \
    bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' --slug be "x" >/dev/null 2>&1 )
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get 20260601T100000Z-be '.backend')" "local" "sidecar records backend=local" )
( cd "$repo" && CODEX_DISPATCH_NOW=20260601T100100Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    bash "$ENGINE" dispatch --verify checks --check 'bash check.sh' --slug df "x" >/dev/null 2>&1 )
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get 20260601T100100Z-df '.backend')" "codex" "default backend recorded as codex" )

# --- retries keep the backend flag (resume must also carry -p local) --------
: > "$log"
( cd "$repo" && CODEX_DISPATCH_NOW=20260601T110000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    CODEX_DISPATCH_FAKE_STATE=ready FAKE_CODEX_ARGV_LOG="$log" FAKE_CODEX_BEHAVIOR=fail \
    bash "$ENGINE" dispatch --backend local --verify checks --check 'bash check.sh' --retry 1 --slug rty "x" >/dev/null 2>&1 )
# the retry path calls `codex exec resume ... -p local`; assert a resume line carries the flag
assert_contains "$(grep resume "$log" || true)" "-p local" "retry resume carries backend flag"

ps_teardown_sandbox
ps_report; exit $?
