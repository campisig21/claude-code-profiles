#!/usr/bin/env bash
# profile_mgmt.sh — profile lifecycle. Backs the /profile command.
# Subcommands: create | provision | list | show | status | archive | switch | doctor
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/paths.sh"
source "$HERE/lib/jsonutil.sh"

die() { echo "profile: $*" >&2; exit 1; }

# Active profile name: prefer the in-session env (CLAUDE_PROFILE/CLAUDE_CONFIG_DIR),
# else the sticky active_profile file, else "default". Used by list + status so they agree.
active_profile_name() {
  if [ -n "${CLAUDE_PROFILE:-}" ] || [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    resolve_active_profile
  elif [ -f "$(cc_root)/active_profile" ]; then
    cat "$(cc_root)/active_profile"
  else
    printf '%s\n' default
  fi
}

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
  # Reserve-only: write NOTHING. Emit a cue that tells the /profile command's
  # Claude flow to run the interview, then call `provision` after approval.
  cat <<EOF
PROFILE_INTERVIEW_READY name=$name
Name '$name' is available. Begin the profile-creation interview.
EOF
}

cmd_provision() {
  local name="${1:-}"
  valid_name "$name" || die "invalid or reserved profile name: '${name}'"
  local P; P="$(profile_dir "$name")"
  [ -e "$P" ] && die "profile '$name' already exists at $P"

  local shared; shared="$(shared_dir)"
  mkdir -p "$P/skills" "$P/agents" "$P/projects" "$P/curator/inbox" "$P/commands"

  # persona from template, with {{PROFILE_NAME}} substituted (fallback; the
  # /profile create flow overwrites this with the authored persona).
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
        }
        + (if .statusLine then {statusLine: .statusLine} else {} end)' \
      "$def_settings" > "$P/settings.json"
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

  echo "Provisioned '$name' at $P"
  echo "Activate it with:  ccp $name"
}

cmd_list() {
  local active; active="$(active_profile_name)"
  local mark
  mark=$([ "$active" = "default" ] && echo " *" || echo "")
  echo "Profiles (* = active):"
  echo "  default${mark}   $(cc_root)"
  if [ -d "$(profiles_dir)" ]; then
    local d nm
    for d in "$(profiles_dir)"/*/; do
      [ -d "$d" ] || continue
      nm="$(basename "$d")"
      [ "$nm" = "_shared" ] && continue
      mark=$([ "$active" = "$nm" ] && echo " *" || echo "")
      echo "  ${nm}${mark}   ${d%/}"
    done
  fi
}

cmd_show() {
  local name="${1:-default}"
  profile_exists "$name" || die "no such profile: $name"
  local P; P="$(profile_dir "$name")"
  local persona="(none)"
  if [ -f "$P/CLAUDE.md" ]; then
    persona="$(grep -m1 -E '^[^[:space:]]' "$P/CLAUDE.md" | sed -E 's/^#+ *//')" || true
    [ -n "$persona" ] || persona="(none)"
  fi
  local skills=0 mems=0
  [ -d "$P/skills" ]   && skills="$(find "$P/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ -d "$P/projects" ] && mems="$(find "$P/projects" -type d -name memory 2>/dev/null | wc -l | tr -d ' ')"
  echo "Profile: $name"
  echo "  Path:    $P"
  echo "  Persona: $persona"
  echo "  Skills:  $skills learned"
  echo "  Memory:  $mems project memory store(s)"
  echo "  Plugins symlink: $([ -L "$P/plugins" ] && echo ok || ([ "$name" = default ] && echo "n/a (default owns real dir)" || echo BROKEN))"
}

cmd_status() {
  local name="${1:-$(active_profile_name)}"
  profile_exists "$name" || die "no such profile: $name"
  local state; state="$(profile_dir "$name")/.curator_state"
  echo "Curator status for '$name':"
  if [ -f "$state" ]; then jq '.' "$state"; else echo "  (no .curator_state yet)"; fi
}

cmd_switch() {
  local name="${1:-}"; [ -n "$name" ] || die "usage: switch <name>"
  if [ "$name" != "default" ]; then profile_exists "$name" || die "no such profile: $name"; fi
  echo "Profiles can't switch mid-session (CLAUDE_CONFIG_DIR is read at launch)."
  echo "Relaunch into '$name' with:"
  echo "    ccp $name"
}

cmd_doctor() {
  local name="${1:-$(active_profile_name)}"
  profile_exists "$name" || die "no such profile: $name"
  local P; P="$(profile_dir "$name")" repaired=0
  if [ "$name" = "default" ]; then
    echo "doctor: '$name' is the default profile (owns real plugins/hooks; nothing to relink)."
    return 0
  else
    local want_plugins; want_plugins="$(cc_root)/plugins"
    if [ ! -e "$P/plugins" ] || [ "$(readlink "$P/plugins" 2>/dev/null)" != "$want_plugins" ] || [ ! -d "$P/plugins/" ]; then
      ln -sfn "$want_plugins" "$P/plugins"; echo "  repair: relinked plugins -> $want_plugins"; repaired=1
    fi
    local want_hooks; want_hooks="$(shared_dir)/hooks"
    if [ ! -e "$P/hooks" ] || [ "$(readlink "$P/hooks" 2>/dev/null)" != "$want_hooks" ]; then
      ln -sfn "$want_hooks" "$P/hooks"; echo "  repair: relinked hooks -> $want_hooks"; repaired=1
    fi
  fi
  [ "$repaired" -eq 0 ] && echo "doctor: '$name' healthy."
}

cmd_archive() {
  local name="${1:-}"; [ -n "$name" ] || die "usage: archive <name>"
  [ "$name" = "default" ] && die "refusing to archive the default profile"
  profile_exists "$name" || die "no such profile: $name"
  local P; P="$(profile_dir "$name")"
  local adir; adir="$(profiles_dir)/.archived"
  mkdir -p "$adir"
  [ -e "$adir/$name" ] && die "an archived '$name' already exists at $adir/$name"
  mv "$P" "$adir/$name"
  echo "Archived '$name' -> $adir/$name (recoverable; not deleted)."
}

main() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    create)  cmd_create "$@" ;;
    provision) cmd_provision "$@" ;;
    list)    cmd_list "$@" ;;
    show)    cmd_show "$@" ;;
    status)  cmd_status "$@" ;;
    archive) cmd_archive "$@" ;;
    switch)  cmd_switch "$@" ;;
    doctor)  cmd_doctor "$@" ;;
    *)       die "unknown subcommand: $sub" ;;
  esac
}
main "$@"
