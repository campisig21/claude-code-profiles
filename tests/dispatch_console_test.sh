#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox
DISPATCH="$PS_REPO_ROOT/bin/dispatch"
fake="$(ps_make_fake_codex)"
ro="$(ps_make_sandbox_repo ok)"

# a real cell dispatch (begin + codex-run) gives attach something to show.
id="$( cd "$ro" && CODEX_DISPATCH_NOW=20260613T160000Z bash "$DISPATCH" begin board --label gpt-5.5 )"
( cd "$ro" && CODEX_DISPATCH_CODEX_BIN="$fake" \
    bash "$DISPATCH" codex-run "$id" --backend codex -m gpt-5.5 "do board" >/dev/null 2>&1 )

# attach --no-follow formats the event stream and exits (no tail -f hang).
aout="$( cd "$ro" && bash "$DISPATCH" attach "$id" --no-follow 2>&1 )"; arc=$?
assert_eq "$arc" "0" "attach --no-follow exits"
assert_contains "$aout" "[begin/start]" "attach renders the begin event"
assert_contains "$aout" "[codex-run/start]" "attach renders the codex-run start"
assert_contains "$aout" "[codex-run/done]" "attach renders the codex-run done"

# console board: columns + this dispatch's harness/backend/model/status.
cout="$( cd "$ro" && bash "$DISPATCH" console 2>&1 )"
assert_contains "$cout" "HARNESS" "console prints the column header"
assert_contains "$cout" "LAST-ACTIVITY" "console has the last-activity column"
assert_contains "$cout" "$id" "console lists the dispatch id"
assert_contains "$cout" "agent" "console shows harness=agent for a begin'd cell"
assert_contains "$cout" "gpt-5.5" "console shows the model"

# legacy-sidecar defaulting (AC3): a sidecar with NO harness/model field shows codex/—.
( cd "$ro"; source "$PS_REPO_ROOT/lib/jsonutil.sh"; source "$PS_REPO_ROOT/lib/dispatch-lib.sh"
  legacy="20200101T000000Z-legacy"
  jq -n --arg id "$legacy" '{id:$id, status:"needs_review", branch:"codex/legacy", updated_at:"20200101T000000Z"}' \
    > "$(d_sidecar_path "$legacy")" )
cout2="$( cd "$ro" && bash "$DISPATCH" console 2>&1 )"
# the legacy row defaults harness->codex and model->— (no field present)
assert_contains "$cout2" "20200101T000000Z-legacy" "console lists the legacy dispatch"
line="$(printf '%s\n' "$cout2" | grep legacy)"
assert_contains "$line" "codex" "legacy harness defaults to codex"
assert_contains "$line" "—"     "legacy model defaults to —"

# attach on an unknown id is refused.
out="$( cd "$ro" && bash "$DISPATCH" attach nope --no-follow 2>&1 )"; rc=$?
assert_eq "$rc" "1" "attach refuses an unknown id"

ps_teardown_sandbox
ps_report; exit $?
