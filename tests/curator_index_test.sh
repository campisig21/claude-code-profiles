#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
CURATOR="$PS_REPO_ROOT/bin/curator.py"
source "$PS_REPO_ROOT/lib/jsonutil.sh"; js_init_curator_state "$CC_PROFILE_ROOT/.curator_state"
mkdir -p "$CC_PROFILE_ROOT/curator/inbox" "$CC_PROFILE_ROOT/skills/use-rg" \
         "$CC_PROFILE_ROOT/projects/acme/memory"
printf -- '---\nname: use-rg\ndescription: use ripgrep for code search\n---\n' > "$CC_PROFILE_ROOT/skills/use-rg/SKILL.md"
echo "# Memory Index" > "$CC_PROFILE_ROOT/projects/acme/memory/MEMORY.md"
printf '# default\n@curator/INDEX.md\n' > "$CC_PROFILE_ROOT/CLAUDE.md"
before="$(cat "$CC_PROFILE_ROOT/CLAUDE.md")"
echo 0 > "$CC_PROFILE_ROOT/curator/last_activity"
fakebin="$PS_SANDBOX/bin"; mkdir -p "$fakebin"
printf '#!/usr/bin/env bash\necho '"'"'{"decisions":[],"new_skill_candidates":[]}'"'"'\n' > "$fakebin/claude"; chmod +x "$fakebin/claude"
echo '{"kind":"flag","type":"auto","title":"t","body":"b","context":""}' > "$CC_PROFILE_ROOT/curator/inbox/c1.json"

CC_PROFILE_ROOT="$CC_PROFILE_ROOT" CURATOR_CLAUDE_BIN="$fakebin/claude" python3 "$CURATOR" run default >/dev/null 2>&1

idx="$CC_PROFILE_ROOT/curator/INDEX.md"
assert_file "$idx" "INDEX.md generated"
assert_contains "$(cat "$idx")" "use-rg" "INDEX lists learned skill"
assert_contains "$(cat "$idx")" "ripgrep" "INDEX shows use-when from description"
assert_contains "$(cat "$idx")" "projects/acme/memory/MEMORY.md" "INDEX rolls up memory store"
assert_eq "$before" "$(cat "$CC_PROFILE_ROOT/CLAUDE.md")" "CLAUDE.md byte-unchanged"

ps_teardown_sandbox
ps_report; exit $?
