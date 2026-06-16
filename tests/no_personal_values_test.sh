#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"

octets='100\.64\.0\.4'
user_host='greg-campi''si'
model='qwen36-35''b'
pattern="${octets}|${user_host}|${model}"
# station/ is personal infra config (this station's own tailnet IP + model names) —
# not distributable framework code, same category as docs/ — so it is excluded too.
hits="$(grep -rEl "$pattern" "$PS_REPO_ROOT" --exclude-dir=docs --exclude-dir=station --exclude-dir=.git --exclude-dir=.codex-dispatch-worktrees || true)"
assert_eq "$hits" "" "repo contains no personal endpoint, host, or model literals outside docs/, station/, and .git/"

ps_report; exit $?
