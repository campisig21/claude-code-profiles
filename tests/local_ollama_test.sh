#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ps_setup_sandbox

export CODEX_DISPATCH_LOCAL_BACKEND=ollama
export OLLAMA_HOST=http://localhost:11434
export CODEX_DISPATCH_LOCAL_MODEL=qwen2.5-coder

fcurl="$PS_SANDBOX/fake-curl"
cat > "$fcurl" <<'SH'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
    http://*/api/ps|https://*/api/ps|*/api/ps) url="$arg" ;;
    http://*/api/chat|https://*/api/chat|*/api/chat) url="$arg" ;;
  esac
done

case "$url" in
  */api/ps)
    printf '{"models":[{"name":"qwen2.5-coder"}]}\n'
    ;;
  */api/chat)
    printf '{"message":{"content":"pong"}}\n'
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$fcurl"
export CODEX_DISPATCH_CURL_BIN="$fcurl"

source "$PS_REPO_ROOT/lib/local.sh"

assert_eq "$(l_probe)" "ready" "l_probe reports ready"
( l_ready ); assert_eq "$?" "0" "l_ready exits 0"
assert_contains "$(ollama_chat qwen2.5-coder 'ping')" "pong" "ollama_chat returns assistant content"

ps_teardown_sandbox
ps_report; exit $?
