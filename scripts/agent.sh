#!/usr/bin/env bash
# lyanemacs agent: install the ACP agents used by agent-shell.
#
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/agent.sh | bash -s -- [name...]
#   scripts/agent.sh [name...]                      (or: scripts/setup.sh agent ...)

set -euo pipefail

AGENTS=(claude codex cursor antigravity opencode)
ACP_REGISTRY=https://raw.githubusercontent.com/agentclientprotocol/registry/main
WRAPPER_MARKER='# managed by lyanemacs'

usage() {
  cat <<'EOF'
Usage: agent.sh [-y] [name...]

Agents:
  claude        @agentclientprotocol/claude-agent-acp (npm, global)
  codex         @agentclientprotocol/codex-acp (npm, global)
  cursor        cursor-agent (cursor.com installer)
  antigravity   agy_acp_server.par (ACP registry binary, sha256 checked)
  opencode      opencode (opencode.ai installer)

No names: ask for each missing agent.  Names: install or upgrade them.
claude and codex need Node.js; lang.sh installs it after asking.

Options:
  -y, --yes   answer yes to every prompt
  -h, --help  show this help
EOF
}

# Load common.sh from next to this script, or download it when piped from curl.
load_common() {
  local src=${BASH_SOURCE[0]:-} dir
  if [[ -f $src && -f $(dirname "$src")/common.sh ]]; then
    dir=$(dirname "$src")
  else
    dir=$(mktemp -d)
    COMMON_TMP=$dir
    trap 'rm -rf "$COMMON_TMP"' EXIT
    curl -fsSL "${LYANEMACS_SITE:-https://lyanemacs.qiyecaotw.net}/scripts/common.sh" -o "$dir/common.sh" || {
      echo "xxx Cannot download common.sh" >&2
      exit 1
    }
  fi
  # shellcheck source=common.sh
  . "$dir/common.sh"
}

# npm_global PACKAGE: global install, with sudo only when the prefix needs it.
npm_global() {
  need_lang node
  if [[ -w $(npm prefix -g) ]]; then
    npm install -g --no-fund --no-audit "$@"
  else
    as_root npm install -g --no-fund --no-audit "$@"
  fi
}

# write_wrapper PATH TARGET: tiny exec script, used to put a binary on PATH
# while it keeps finding the files next to it.
write_wrapper() {
  local path=$1 target=$2
  if [[ -e $path || -L $path ]] && ! grep -qs "$WRAPPER_MARKER" "$path"; then
    ask "$path exists and is not managed by lyanemacs. Replace it (backup kept)?" n || {
      warn "Kept $path"
      return
    }
    backup "$path"
  fi
  mkdir -p "$(dirname "$path")"
  printf '#!/bin/sh\n%s\nexec "%s" "$@"\n' "$WRAPPER_MARKER" "$target" >"$path"
  chmod +x "$path"
}

agent_name() {
  case $1 in
    claude | claude-acp | claude-agent-acp) echo claude ;;
    codex | codex-acp) echo codex ;;
    cursor | cursor-agent) echo cursor ;;
    antigravity | agy | antigravity-acp) echo antigravity ;;
    opencode) echo opencode ;;
    *) return 1 ;;
  esac
}

agent_installed() {
  case $1 in
    claude) have claude-agent-acp ;;
    codex) have codex-acp ;;
    cursor) have cursor-agent ;;
    antigravity) have agy_acp_server.par ;;
    opencode) have opencode ;;
  esac
}

agent_hint() {
  case $1 in
    claude) echo "log in with the claude CLI or set ANTHROPIC_API_KEY" ;;
    codex) echo "agent-shell asks to log in on first use" ;;
    cursor) echo "run 'cursor-agent login' once" ;;
    antigravity) echo "agent-shell asks to log in on first use" ;;
    opencode) echo "run 'opencode auth login' once" ;;
  esac
}

install_agent_claude() { npm_global @agentclientprotocol/claude-agent-acp@latest; }
install_agent_codex() { npm_global @agentclientprotocol/codex-acp@latest; }

install_agent_cursor() {
  need curl
  curl -fsSL https://cursor.com/install | bash
}

install_agent_opencode() {
  need curl
  curl -fsSL https://opencode.ai/install | bash
}

# Same location as `agent-shell-antigravity-bootstrap' in init.el, plus a
# wrapper in ~/.local/bin so the default `agy_acp_server.par' command resolves.
install_agent_antigravity() {
  local upgrade=$1 os arch platform dir tmp version url sum
  need curl
  need unzip
  need python3
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case $(uname -m) in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "Antigravity: unsupported architecture $(uname -m)" ;;
  esac
  platform=$os-$arch
  dir=${XDG_CACHE_HOME:-$HOME/.cache}/agent-shell/antigravity/$platform

  if [[ -x $dir/agy_acp_server.par ]] && ! ((upgrade)); then
    ok "Antigravity server already in $dir"
  else
    tmp=$(mktemp -d)
    curl -fsSL "$ACP_REGISTRY/antigravity-acp/agent.json" -o "$tmp/agent.json"
    read -r version url sum < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
b = d["distribution"]["binary"][sys.argv[2]]
print(d["version"], b["archive"], b.get("sha256", "-"))' "$tmp/agent.json" "$platform") ||
      die "Antigravity: no $platform build in the ACP registry"
    if [[ -x $dir/agy_acp_server.par && $(cat "$dir/.version" 2>/dev/null) == "$version" ]]; then
      ok "Antigravity server $version is current"
    else
      log "Downloading Antigravity ACP server $version"
      curl -fL --progress-bar "$url" -o "$tmp/server.zip"
      if [[ $sum != - ]]; then
        echo "$sum  $tmp/server.zip" | sha256sum -c --quiet - || die "Antigravity: checksum mismatch"
      fi
      rm -rf "$dir.new"
      mkdir -p "$dir.new"
      unzip -q -o "$tmp/server.zip" -d "$dir.new"
      chmod +x "$dir.new/agy_acp_server.par"
      echo "$version" >"$dir.new/.version"
      rm -rf "$dir"
      mv "$dir.new" "$dir"
    fi
    rm -rf "$tmp"
  fi
  write_wrapper "$HOME/.local/bin/agy_acp_server.par" "$dir/agy_acp_server.par"
}

main() {
  load_common
  parse_args "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  setup_path

  local name arg upgrade=0
  local -a chosen=()
  for arg in "$@"; do
    name=$(agent_name "$arg") || die "Unknown agent '$arg' (known: ${AGENTS[*]})"
    chosen+=("$name")
  done
  if ((${#chosen[@]})); then upgrade=1; else chosen=("${AGENTS[@]}"); fi

  for name in "${chosen[@]}"; do
    if ! ((upgrade)) && agent_installed "$name"; then
      ok "$name installed"
      continue
    fi
    if ! ((upgrade)); then
      ask "Install $name?" n || {
        log "Skipped $name"
        continue
      }
    fi
    log "Installing $name"
    if [[ $name == antigravity ]]; then
      install_agent_antigravity "$upgrade"
    else
      "install_agent_$name"
    fi
    setup_path
    if agent_installed "$name"; then
      ok "$name installed; $(agent_hint "$name")"
    else
      warn "$name installed but not on PATH yet; open a new shell"
    fi
  done
}

# Everything runs from here, so a truncated download executes nothing.
main "$@"
