#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"

assert_eq "$(d_backend_args ollama)" "--oss --local-provider ollama -m qwen2.5-coder" \
  "ollama backend -> native oss flags with default model"
( CODEX_DISPATCH_LOCAL_MODEL=foo
  assert_eq "$(d_backend_args ollama)" "--oss --local-provider ollama -m foo" \
    "ollama backend -> env model override honored" )

fake="$(ps_make_fake_codex)"
repo="$(ps_make_sandbox_repo)"
log="$PS_SANDBOX/argv.log"; : > "$log"
stamp=20260601T120000Z

( cd "$repo" && CODEX_DISPATCH_NOW="$stamp" CODEX_DISPATCH_CODEX_BIN="$fake" \
    FAKE_CODEX_ARGV_LOG="$log" \
    bash "$PS_REPO_ROOT/codex_dispatch.sh" dispatch --backend ollama --verify checks \
      --check 'bash check.sh' --slug beo "x" >/dev/null 2>&1 )

assert_contains "$(cat "$log")" "--oss" "dispatch passes codex oss flag"
assert_contains "$(cat "$log")" "--local-provider ollama" "dispatch passes ollama provider flag"
( cd "$repo"
  source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch.sh"
  assert_eq "$(d_sc_get ${stamp}-beo '.backend')" "ollama" "sidecar records backend=ollama" )

ps_teardown_sandbox
ps_report; exit $?
