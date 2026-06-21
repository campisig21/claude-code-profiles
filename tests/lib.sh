# Sourced by every *_test.sh. Provides a temp sandbox + assertions.
# Never executed directly.

PS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS_TESTS=0
PS_FAILS=0
# Subshell-safe tally: assertions inside ( ... ) subshells lose variable
# increments when the subshell exits, so we also append to files whose path is
# fixed at source time and inherited by subshells. ps_report reads the files.
PS_COUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ps_count.XXXXXX")"
: > "$PS_COUNT_DIR/tests"; : > "$PS_COUNT_DIR/fails"

ps_setup_sandbox() {
  PS_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ps_test.XXXXXX")"
  export CC_PROFILE_ROOT="$PS_SANDBOX"
  unset CLAUDE_PROFILE
  unset CLAUDE_CONFIG_DIR
  # Sandbox CODEX_HOME for EVERY test: install.sh writes $CODEX_HOME/local.config.toml,
  # so any test that runs install.sh must never touch the real ~/.codex (C.1).
  export CODEX_HOME="$PS_SANDBOX/dot-codex"
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

# Fake `claude -p` for claude-run transport tests. Dumps the ANTHROPIC_* env it
# received + its args. Distinct from ps_make_fake_claude (ccp profile tests).
ps_make_fake_claude_p() {
  local p="$PS_SANDBOX/fake-claude-p"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<unset>}"
echo "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-<unset>}"
echo "ANTHROPIC_SMALL_FAST_MODEL=${ANTHROPIC_SMALL_FAST_MODEL:-<unset>}"
echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-<unset>}"
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-<unset>}"
echo "ARGS=$*"
exit 0
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}

assert_eq() {
  PS_TESTS=$((PS_TESTS + 1)); echo x >> "$PS_COUNT_DIR/tests"
  if [ "$1" != "$2" ]; then
    echo "  FAIL: ${3:-assert_eq}: expected [$2], got [$1]"
    PS_FAILS=$((PS_FAILS + 1)); echo x >> "$PS_COUNT_DIR/fails"
  fi
}
assert_contains() {
  PS_TESTS=$((PS_TESTS + 1)); echo x >> "$PS_COUNT_DIR/tests"
  case "$1" in
    *"$2"*) ;;
    *) echo "  FAIL: ${3:-assert_contains}: output missing [$2]"; PS_FAILS=$((PS_FAILS + 1)); echo x >> "$PS_COUNT_DIR/fails" ;;
  esac
}
assert_file() {
  PS_TESTS=$((PS_TESTS + 1)); echo x >> "$PS_COUNT_DIR/tests"
  [ -e "$1" ] || { echo "  FAIL: ${2:-assert_file}: missing [$1]"; PS_FAILS=$((PS_FAILS + 1)); echo x >> "$PS_COUNT_DIR/fails"; }
}
assert_symlink() {
  PS_TESTS=$((PS_TESTS + 1)); echo x >> "$PS_COUNT_DIR/tests"
  [ -L "$1" ] || { echo "  FAIL: ${2:-assert_symlink}: not a symlink [$1]"; PS_FAILS=$((PS_FAILS + 1)); echo x >> "$PS_COUNT_DIR/fails"; }
}
ps_report() {
  local t f
  t="$(wc -l < "$PS_COUNT_DIR/tests" | tr -d ' ')"
  f="$(wc -l < "$PS_COUNT_DIR/fails" | tr -d ' ')"
  echo "  ($t checks, $f failed)"
  rm -rf "$PS_COUNT_DIR"
  return "$f"
}

# --- Subsystem C doubles -----------------------------------------------------

# A fake `codex` for engine tests. Honors: [exec [resume]] ... -C <dir> -o <file> --json
# and `--version`. Behavior controlled by FAKE_CODEX_BEHAVIOR=pass|fail|weaken-tests.
# Writes a sentinel file IMPL in the -C dir: "ok" passes the sandbox check, "bad" fails.
# `exec resume` always writes "ok" (models a fix on retry). Echoes path to the fake.
ps_make_fake_codex() {
  local p="$PS_SANDBOX/fake-codex"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
[ -n "${FAKE_CODEX_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CODEX_ARGV_LOG"
# --version short-circuit
for a in "$@"; do case "$a" in --version|-V) echo "fake-codex 0.0.0"; exit 0;; esac; done
is_resume=0
for a in "$@"; do case "$a" in resume) is_resume=1;; esac; done
cdir="." ; outfile="" ; json=0
while [ $# -gt 0 ]; do
  case "$1" in
    -C|--cd) cdir="$2"; shift 2;;
    -o|--output-last-message) outfile="$2"; shift 2;;
    --json) json=1; shift;;
    *) shift;;
  esac
done
behavior="${FAKE_CODEX_BEHAVIOR:-pass}"
if [ "$is_resume" = "1" ]; then
  # resume behavior: default applies a fix; 'noop' models a model that ignores
  # the feedback and changes nothing (the NO-OP resume case).
  case "${FAKE_CODEX_RESUME_BEHAVIOR:-pass}" in
    noop) msg="resumed: no changes made";;
    *)    printf 'ok\n' > "$cdir/IMPL"; msg="resumed: applied fix";;
  esac
else
  case "$behavior" in
    pass)         printf 'ok\n'  > "$cdir/IMPL"; msg="implemented (pass)";;
    fail)         printf 'bad\n' > "$cdir/IMPL"; msg="implemented (fail)";;
    noop)         msg="no changes made";;   # produces zero file changes (NO-OP exec)
    weaken-tests) printf 'ok\n'  > "$cdir/IMPL"
                  mkdir -p "$cdir/tests"; printf '# weakened\n' >> "$cdir/tests/some_test.sh"
                  msg="implemented (weakened tests)";;
    *)            printf 'ok\n'  > "$cdir/IMPL"; msg="implemented";;
  esac
fi
[ -n "$outfile" ] && printf '%s\n' "$msg" > "$outfile"
[ "$json" = "1" ] && printf '{"type":"session.created","session_id":"fake-sess-0001"}\n'
exit 0
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}

# Create a sandbox git repo INSIDE PS_SANDBOX (so teardown removes it + sibling
# worktrees). Seeds a commit and a check script `check.sh` that passes iff IMPL=ok.
# Echoes the repo path.
ps_make_sandbox_repo() {
  local repo="$PS_SANDBOX/${1:-repo}"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"   # resolve symlinks (macOS /tmp -> /private/tmp) so it matches git
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name  "Test"
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  cat > "$repo/check.sh" <<'CHK'
#!/usr/bin/env bash
# Passes iff IMPL exists and contains "ok".
[ -f IMPL ] && grep -q ok IMPL
CHK
  chmod +x "$repo/check.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed"
  printf '%s\n' "$repo"
}

# A fake `ssh` for lifecycle tests. Records "<target> :: <remote cmd>" to
# FAKE_SSH_LOG; exits FAKE_SSH_RC (default 0). Echoes path to the fake.
ps_make_fake_ssh() {
  local p="$PS_SANDBOX/fake-ssh"
  cat > "$p" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_SSH_LOG:-}" ] && printf '%s :: %s\n' "$1" "${*:2}" >> "$FAKE_SSH_LOG"
exit "${FAKE_SSH_RC:-0}"
SH
  chmod +x "$p"
  printf '%s\n' "$p"
}
