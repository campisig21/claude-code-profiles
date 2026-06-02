#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
out="$(python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("curator", "bin/curator.py")
cur = importlib.util.module_from_spec(spec); spec.loader.exec_module(cur)
p = cur.build_prompt({"candidates":[],"existing_digest":[],"skill_stats":{},"prune_nominations":[],"codex_events":[]})
print(p)
PY
)"
assert_contains "$out" '"content"' "prompt names the content field"
assert_contains "$out" 'COMPLETE file text' "prompt says content is the full file body"
assert_contains "$out" 'Do NOT use a "body" field' "prompt forbids a body field"
assert_contains "$out" '"action":"prune"' "prompt documents prune shape"
assert_contains "$out" '"action":"skip"' "prompt documents skip shape"

ps_teardown_sandbox
ps_report; exit $?
