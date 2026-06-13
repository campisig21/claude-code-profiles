#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
ENGINE="$PS_REPO_ROOT/codex_dispatch.sh"
fake="$(ps_make_fake_codex)"

# --- Part A: the library is sourceable STANDALONE (no codex_dispatch.sh, no adapter) ---
drv="$PS_SANDBOX/lib-only.sh"; cat > "$drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
printf 'slug=%s\n'      "$(d_slugify 'Hello, World! 123')"
printf 'has_land=%s\n'  "$(command -v d_land      >/dev/null && echo yes || echo no)"
printf 'has_codex=%s\n' "$(command -v d_codex_exec >/dev/null && echo yes || echo no)"
EOF
out="$(PS_REPO_ROOT="$PS_REPO_ROOT" bash "$drv" 2>&1)"
assert_contains "$out" "slug=hello-world-123" "d_slugify works with only dispatch-lib sourced"
assert_contains "$out" "has_land=yes"  "library carries d_land standalone"
assert_contains "$out" "has_codex=no"  "library does NOT pull in the codex adapter (clean one-way seam)"

# --- Part B: d_land + the d_on_land hook, driven with ONLY the library sourced ---
# Reach needs_review via the engine (we are testing land/hook, not dispatch).
ro="$(ps_make_sandbox_repo ok)"
( cd "$ro" && CODEX_DISPATCH_NOW=20260613T120000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    FAKE_CODEX_BEHAVIOR=pass bash "$ENGINE" dispatch --verify checks \
    --check 'bash check.sh' --retry 1 --slug land-iso "do x" >/dev/null 2>&1 )
id="20260613T120000Z-land-iso"

land_drv="$PS_SANDBOX/land-iso.sh"; cat > "$land_drv" <<'EOF'
set -uo pipefail
source "$PS_REPO_ROOT/lib/jsonutil.sh"
source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
if [ "${WITH_PROFILE:-0}" = 1 ]; then
  resolve_active_profile() { printf 'testprof\n'; }
  profile_dir()           { printf '%s/profiles/%s\n' "$CC_PROFILE_ROOT" "$1"; }
fi
cd "$REPO"
d_land "$ID"
EOF

# B1: profile machinery present => land succeeds AND the curator inbox json appears.
inbox="$CC_PROFILE_ROOT/profiles/testprof/curator/inbox"
REPO="$ro" ID="$id" WITH_PROFILE=1 PS_REPO_ROOT="$PS_REPO_ROOT" \
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$land_drv" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "d_land lands with only dispatch-lib sourced"
assert_eq "$(cat "$ro/IMPL")" "ok" "standalone d_land merged the change into the working tree"
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  assert_eq "$(d_sc_get "$id" '.status')" "landed" "sidecar status landed" )
hit="$(ls "$inbox"/*-codex-"$id".json 2>/dev/null | head -1)"
assert_file "$hit" "d_on_land fired: curator inbox json written when profile present"

# B2: no profile machinery => land still succeeds; hook is a clean no-op.
ro2="$(ps_make_sandbox_repo ok2)"
( cd "$ro2" && CODEX_DISPATCH_NOW=20260613T121000Z CODEX_DISPATCH_CODEX_BIN="$fake" \
    FAKE_CODEX_BEHAVIOR=pass bash "$ENGINE" dispatch --verify checks \
    --check 'bash check.sh' --retry 1 --slug land-iso2 "do x" >/dev/null 2>&1 )
id2="20260613T121000Z-land-iso2"
REPO="$ro2" ID="$id2" WITH_PROFILE=0 PS_REPO_ROOT="$PS_REPO_ROOT" \
  CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$land_drv" >/dev/null 2>&1; rc2=$?
assert_eq "$rc2" "0" "d_land lands even with no profile machinery (portable embedding)"
assert_eq "$(cat "$ro2/IMPL")" "ok" "standalone d_land merged without the hook firing"

# --- Part C: bin/dispatch is at parity with the engine for the moved verbs ---
rc3="$(ps_make_sandbox_repo cli)"
a="$( cd "$rc3" && bash "$ENGINE" list 2>&1 )"
b="$( cd "$rc3" && bash "$PS_REPO_ROOT/bin/dispatch" list 2>&1 )"
assert_eq "$b" "$a" "bin/dispatch list matches codex_dispatch.sh list"

ps_teardown_sandbox
ps_report; exit $?
