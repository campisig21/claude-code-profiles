# Sourced by every *_test.sh. Provides a temp sandbox + assertions.
# Never executed directly.

PS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS_TESTS=0
PS_FAILS=0

ps_setup_sandbox() {
  PS_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ps_test.XXXXXX")"
  export CC_PROFILE_ROOT="$PS_SANDBOX"
  mkdir -p "$CC_PROFILE_ROOT/plugins"
  cat > "$CC_PROFILE_ROOT/settings.json" <<'JSON'
{ "enabledPlugins": { "superpowers@official": true }, "permissions": { "defaultMode": "default" } }
JSON
}

ps_teardown_sandbox() {
  [ -n "${PS_SANDBOX:-}" ] && rm -rf "$PS_SANDBOX"
}

# Fake `claude` that dumps env + args (for ccp tests). Echoes its path.
ps_make_fake_claude() {
  local p="$PS_SANDBOX/fake-claude"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
echo "CLAUDE_PROFILE=${CLAUDE_PROFILE:-<unset>}"
echo "ARGS=$*"
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}

assert_eq() {
  PS_TESTS=$((PS_TESTS + 1))
  if [ "$1" != "$2" ]; then
    echo "  FAIL: ${3:-assert_eq}: expected [$2], got [$1]"
    PS_FAILS=$((PS_FAILS + 1))
  fi
}
assert_contains() {
  PS_TESTS=$((PS_TESTS + 1))
  case "$1" in
    *"$2"*) ;;
    *) echo "  FAIL: ${3:-assert_contains}: output missing [$2]"; PS_FAILS=$((PS_FAILS + 1)) ;;
  esac
}
assert_file() {
  PS_TESTS=$((PS_TESTS + 1))
  [ -e "$1" ] || { echo "  FAIL: ${2:-assert_file}: missing [$1]"; PS_FAILS=$((PS_FAILS + 1)); }
}
assert_symlink() {
  PS_TESTS=$((PS_TESTS + 1))
  [ -L "$1" ] || { echo "  FAIL: ${2:-assert_symlink}: not a symlink [$1]"; PS_FAILS=$((PS_FAILS + 1)); }
}
ps_report() {
  echo "  ($PS_TESTS checks, $PS_FAILS failed)"
  return "$PS_FAILS"
}
