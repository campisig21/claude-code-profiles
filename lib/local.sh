#!/usr/bin/env bash
# lib/local.sh — backend facade. Sources the selected local-LLM backend so all
# consumers (codex dispatch, local-ask, MCP, curator) share one l_* interface.
: "${CODEX_DISPATCH_LOCAL_BACKEND:=llamacpp}"
_here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_here/local-${CODEX_DISPATCH_LOCAL_BACKEND}.sh"
