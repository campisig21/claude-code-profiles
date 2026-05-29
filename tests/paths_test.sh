#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$PS_REPO_ROOT/lib/paths.sh"
ps_setup_sandbox

assert_eq "$(cc_root)" "$CC_PROFILE_ROOT" "cc_root honors CC_PROFILE_ROOT"
assert_eq "$(profiles_dir)" "$CC_PROFILE_ROOT/profiles" "profiles_dir"
assert_eq "$(shared_dir)" "$CC_PROFILE_ROOT/profiles/_shared" "shared_dir"
assert_eq "$(profile_dir default)" "$CC_PROFILE_ROOT" "default -> cc_root"
assert_eq "$(profile_dir)" "$CC_PROFILE_ROOT" "empty -> cc_root"
assert_eq "$(profile_dir foo)" "$CC_PROFILE_ROOT/profiles/foo" "named profile dir"

mkdir -p "$CC_PROFILE_ROOT/profiles/foo"
if profile_exists foo; then assert_eq ok ok "foo exists"; else assert_eq missing ok "foo should exist"; fi
if profile_exists nope; then assert_eq present absent "nope should not exist"; else assert_eq absent absent "nope absent"; fi

assert_eq "$(CLAUDE_PROFILE=bar resolve_active_profile)" "bar" "CLAUDE_PROFILE wins"
assert_eq "$(CLAUDE_PROFILE= CLAUDE_CONFIG_DIR= resolve_active_profile)" "default" "unset -> default"
assert_eq "$(CLAUDE_PROFILE= CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT" resolve_active_profile)" "default" "cc_root -> default"
assert_eq "$(CLAUDE_PROFILE= CLAUDE_CONFIG_DIR="$CC_PROFILE_ROOT/profiles/baz" resolve_active_profile)" "baz" "derive from config dir"

assert_eq "$(expected_config_dir default)" "" "default expects empty"
assert_eq "$(expected_config_dir foo)" "$CC_PROFILE_ROOT/profiles/foo" "named expected dir"

ps_teardown_sandbox
ps_report; exit $?
