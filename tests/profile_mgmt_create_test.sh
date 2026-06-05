#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
MGMT="$PS_REPO_ROOT/profile_mgmt.sh"

# Pre-stage _shared so symlink targets exist (install.sh does this for real).
mkdir -p "$CC_PROFILE_ROOT/profiles/_shared"
ln -sfn "$PS_REPO_ROOT/hooks"     "$CC_PROFILE_ROOT/profiles/_shared/hooks"
ln -sfn "$PS_REPO_ROOT/commands"  "$CC_PROFILE_ROOT/profiles/_shared/commands"
ln -sfn "$PS_REPO_ROOT/skills"    "$CC_PROFILE_ROOT/profiles/_shared/skills"
ln -sfn "$PS_REPO_ROOT/templates" "$CC_PROFILE_ROOT/profiles/_shared/templates"

# create now RESERVES ONLY: it validates and prints an interview cue, writes nothing.
out="$(CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work 2>&1)"; rc=$?
assert_eq "$rc" "0" "create succeeds"
assert_contains "$out" "PROFILE_INTERVIEW_READY name=work" "create prints interview cue"
P="$CC_PROFILE_ROOT/profiles/work"
[ -e "$P" ] && assert_eq exists nothing "create must NOT create the profile dir" || assert_eq ok ok "create wrote nothing"

# create is idempotent now (regression: the old phantom 'already exists' double-run bug).
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create work >/dev/null 2>&1; r_again=$?
assert_eq "$r_again" "0" "re-running create does not error (no phantom 'already exists')"

# create over an ALREADY-PROVISIONED profile still fails.
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" provision taken >/dev/null 2>&1
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create taken >/dev/null 2>&1; rc=$?
set -e 2>/dev/null || true
assert_eq "$rc" "1" "create over existing profile fails"

# reserved names fail
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create default >/dev/null 2>&1; r1=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create _shared >/dev/null 2>&1; r2=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "bad/name" >/dev/null 2>&1; r3=$?
set -e 2>/dev/null || true
assert_eq "$r1" "1" "reserved: default"
assert_eq "$r2" "1" "reserved: _shared"
assert_eq "$r3" "1" "invalid: slash"

# unsafe / metacharacter names rejected (allowlist)
set +e
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "foo&bar" >/dev/null 2>&1; ra=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create ".." >/dev/null 2>&1; rb=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create "-x" >/dev/null 2>&1; rc2=$?
CC_PROFILE_ROOT="$CC_PROFILE_ROOT" bash "$MGMT" create ".hidden" >/dev/null 2>&1; rd=$?
set -e 2>/dev/null || true
assert_eq "$ra" "1" "reject ampersand name"
assert_eq "$rb" "1" "reject dotdot name"
assert_eq "$rc2" "1" "reject leading-dash name"
assert_eq "$rd" "1" "reject leading-dot name"

ps_teardown_sandbox
ps_report
