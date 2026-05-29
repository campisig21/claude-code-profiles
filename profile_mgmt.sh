#!/usr/bin/env bash
# profile_mgmt.sh — profile lifecycle. Backs the /profile command.
# Subcommands: create | list | show | status | archive | switch | doctor
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/paths.sh"
source "$HERE/lib/jsonutil.sh"

die() { echo "profile: $*" >&2; exit 1; }

valid_name() {
  case "$1" in
    ""|default|_shared) return 1 ;;
  esac
  # allowlist: start alphanumeric, then only [A-Za-z0-9._-]
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

cmd_create() {
  local name="${1:-}"
  valid_name "$name" || die "invalid or reserved profile name: '${name}'"
  local P; P="$(profile_dir "$name")"
  [ -e "$P" ] && die "profile '$name' already exists at $P"

  local shared; shared="$(shared_dir)"
  mkdir -p "$P/skills" "$P/agents" "$P/projects" "$P/curator/inbox" "$P/commands"

  # persona from template, with {{PROFILE_NAME}} substituted
  if [ -f "$shared/templates/persona.md" ]; then
    sed "s/{{PROFILE_NAME}}/$name/g" "$shared/templates/persona.md" > "$P/CLAUDE.md"
  else
    printf '# %s Profile\n' "$name" > "$P/CLAUDE.md"
  fi

  # settings.json: inherit enabledPlugins + flags from the default profile,
  # then register the two profile hooks by absolute _shared path.
  local def_settings; def_settings="$(cc_root)/settings.json"
  if [ -f "$def_settings" ]; then
    jq '{
          enabledPlugins: (.enabledPlugins // {}),
          extraKnownMarketplaces: (.extraKnownMarketplaces // {}),
          autoMemoryEnabled: (.autoMemoryEnabled // true),
          autoDreamEnabled: (.autoDreamEnabled // true),
          permissions: {defaultMode: (.permissions.defaultMode // "default")}
        }' "$def_settings" > "$P/settings.json"
  else
    echo '{"permissions":{"defaultMode":"default"}}' > "$P/settings.json"
  fi
  js_merge_command_hook "$P/settings.json" SessionStart "bash $shared/hooks/profile-wakeup.sh"
  js_merge_command_hook "$P/settings.json" Stop          "bash $shared/hooks/learn-capture.sh"

  # curator state
  js_init_curator_state "$P/.curator_state"

  # shared-machinery symlinks
  ln -sfn "$(cc_root)/plugins" "$P/plugins"
  ln -sfn "$shared/hooks"      "$P/hooks"
  [ -f "$shared/commands/profile.md" ] && ln -sfn "$shared/commands/profile.md" "$P/commands/profile.md"
  if [ -d "$shared/skills" ]; then
    local s
    for s in "$shared/skills"/*/; do
      [ -d "$s" ] || continue
      ln -sfn "${s%/}" "$P/skills/$(basename "$s")"
    done
  fi

  echo "Created profile '$name' at $P"
  echo "Activate it with:  ccp $name"
}

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    create)  cmd_create "$@" ;;
    list|show|status|archive|switch|doctor)
             die "subcommand '$sub' not implemented yet" ;;   # Tasks 8-9
    *)       die "unknown subcommand: $sub" ;;
  esac
}
main "$@"
