#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"
log="$PS_SANDBOX/argv.log"

# --- AC7a: a NEW cloud model is a pure -m passthrough — NO code change. --------
# A model string never mentioned anywhere in the code threads straight through.
: > "$log"
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T170000Z bash "$DISPATCH" begin am --label gpt-5.4 )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" FAKE_CODEX_ARGV_LOG="$log" \
    bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.4 "x" >/dev/null 2>&1 )
assert_contains "$(cat "$log")" "-m gpt-5.4" "new cloud model threads via -m with no code change"

# --- AC7b: a NEW provider is ONE d_backend_args arm and NO new files. ---------
# Simulate the one-line contributor edit by overriding d_backend_args in a driver
# that adds a transport-only `vllm` arm, then codex-run --backend vllm.
drv="$PS_SANDBOX/addprovider.sh"; cat > "$drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch.sh"
# The entire "add a provider" change: ONE new case arm (transport-only).
d_backend_args() {
  case "${1:-codex}" in
    codex) : ;;
    vllm)  printf '%s' '--oss --local-provider vllm' ;;
    *)     return 1 ;;
  esac
}
# export so the grandchild fake codex (spawned inside d_codex_run) sees them —
# an inline VAR=x prefix on a FUNCTION call does not reliably reach child procs.
export CODEX_DISPATCH_CODEX_BIN="$FAKE" FAKE_CODEX_ARGV_LOG="$LOG"
cd "$REPO"
id="$(CODEX_DISPATCH_NOW=20260613T171000Z d_begin prov --label m1)"
d_codex_run "$id" --backend vllm -m m1 "x" >/dev/null
EOF
: > "$log"
REPO="$ro" FAKE="$fake" LOG="$log" PS_REPO_ROOT="$PS_REPO_ROOT" bash "$drv"
assert_contains "$(cat "$log")" "--local-provider vllm" "new provider's transport bundle threads from one arm"
assert_contains "$(cat "$log")" "-m m1" "the model axis still threads for the new provider"

ps_teardown_sandbox
ps_report; exit $?
