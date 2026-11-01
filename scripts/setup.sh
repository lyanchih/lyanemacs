#!/usr/bin/env bash
# lyanemacs setup: install and sync Emacs, its config, ACP agents and LSP servers.
#
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- pull
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- agent [name...]
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lsp [lang...]
#   scripts/setup.sh <command>                         (from a checkout)
#
# Piped from curl, install / pull / sync clone (or reuse) $LYANEMACS_DIR and
# re-run that checkout's copy of the script, so both ways behave the same.
# agent and lsp need no checkout and run straight from the pipe.

set -euo pipefail

LYANEMACS_REPO=${LYANEMACS_REPO:-https://github.com/lyanchih/lyanemacs.git}
LYANEMACS_DIR=${LYANEMACS_DIR:-$HOME/repos/lyanemacs}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/lyanemacs
ACP_REGISTRY=https://raw.githubusercontent.com/agentclientprotocol/registry/main
WRAPPER_MARKER='# managed by lyanemacs'

AGENTS=(claude codex cursor antigravity opencode)
LANGS=(python web c rust lisp php)

# Repo-local LSP packages, installed into $TOOLS_DIR by `lsp`.
PY_PACKAGES=('python-lsp-server[all]')
NPM_PACKAGES=(typescript typescript-language-server vscode-langservers-extracted prettier)
COMPOSER_PACKAGES=(phpactor/phpactor)
# What `lsp` may leave in $LYANEMACS_DIR before the repo is cloned there.
TOOL_ENTRIES=(.venv node_modules vendor package.json package-lock.json composer.json composer.lock)

REPO=      # checkout this script runs from; empty when piped without one
TOOLS_DIR= # where `lsp` installs: the checkout, else $LYANEMACS_DIR

ASSUME_YES=0
FLAGS=()

usage() {
  cat <<'EOF'
Usage: setup.sh [-y] [command] [args...]

Commands:
  install            (default) purge apt Emacs, install snap Emacs 31+,
                     link/copy files listed in manifest.tsv
  pull               git pull this repo, then sync (copies and git entries updated)
  sync               apply manifest.tsv again without pulling
  agent [name...]    install ACP agents: claude codex cursor antigravity opencode
                     no names: ask for each missing agent; names: install/upgrade them
  lsp [lang...]      install LSP servers: python web c rust lisp php
                     no names: ask for each missing one; names: install/upgrade them
                     python/web/php go into .venv, node_modules, vendor of the
                     checkout (or $LYANEMACS_DIR when piped without one)

agent and lsp work without a checkout, e.g. on a TRAMP remote host.

Options:
  -y, --yes          answer yes to every prompt (replaced files are still backed up)
  -h, --help         show this help

Environment:
  LYANEMACS_DIR      checkout used when piped from curl, and where `lsp` installs
                     without a checkout (default ~/repos/lyanemacs)
  LYANEMACS_REPO     git URL to clone (default https://github.com/lyanchih/lyanemacs.git)
EOF
}

# ---------------------------------------------------------------- helpers

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask QUESTION [y|n]: prompt on the terminal, since stdin may be the curl pipe.
# Without a terminal (and without --yes) the answer is always no.
ask() {
  local question=$1 default=${2:-n} hint reply
  if [[ $default == y ]]; then hint='[Y/n]'; else hint='[y/N]'; fi
  if ((ASSUME_YES)); then
    printf '%s %s y (--yes)\n' "$question" "$hint"
    return 0
  fi
  if ! has_tty; then
    printf '%s %s n (no terminal)\n' "$question" "$hint"
    return 1
  fi
  while :; do
    printf '%s %s ' "$question" "$hint" >/dev/tty
    IFS= read -r reply </dev/tty || reply=
    case ${reply:-$default} in
      [Yy] | [Yy][Ee][Ss]) return 0 ;;
      [Nn] | [Nn][Oo]) return 1 ;;
    esac
  done
}

as_root() {
  if ((EUID == 0)); then "$@"; else sudo "$@"; fi
}

apt_install() {
  have apt-get || die "apt-get not found; install manually: $*"
  log "apt install $*"
  as_root apt-get install -y "$@"
}

# need COMMAND [APT_PACKAGE]
need() {
  have "$1" || apt_install "${2:-$1}"
}

backup() {
  local path=$1 dest
  dest="$path.bak.$(date +%Y%m%d-%H%M%S)"
  mv -- "$path" "$dest"
  log "Backed up $path -> $dest"
}

sha() { sha256sum -- "$1" | cut -d' ' -f1; }

# Tools installed per user are often missing from PATH in a non-login shell.
setup_path() {
  local dir
  for dir in /snap/bin "$HOME/.opencode/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    [[ -d $dir && :$PATH: != *:$dir:* ]] && PATH="$dir:$PATH"
  done
  export PATH
  load_nvm || true
}

load_nvm() {
  export NVM_DIR=${NVM_DIR:-$HOME/.nvm}
  [[ -s $NVM_DIR/nvm.sh ]] || return 1
  set +u
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  set -u
}

ensure_node() {
  have npm && return
  ask "Node.js not found. Install nvm + Node.js LTS?" y || die "Node.js is required"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  load_nvm || die "nvm install failed"
  set +u
  nvm install --lts
  set -u
}

# npm_global PACKAGE: global install, with sudo only when the prefix needs it.
npm_global() {
  ensure_node
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

# ---------------------------------------------------------------- bootstrap

# Print the checkout this script lives in, if it was run from a file.
script_repo() {
  local src=${BASH_SOURCE[0]:-} dir
  [[ -n $src && -f $src ]] || return 1
  dir=$(cd "$(dirname "$src")/.." && pwd -P)
  [[ -f $dir/manifest.tsv && -d $dir/lisp ]] || return 1
  printf '%s\n' "$dir"
}

# github.com/owner/name for https, ssh and scp-style git URLs.
normalize_url() {
  sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#:#/#; s#\.git$##; s#/$##' <<<"$1"
}

only_tool_entries() {
  local entry known
  while IFS= read -r entry; do
    for known in "${TOOL_ENTRIES[@]}"; do
      [[ $entry == "$known" ]] && continue 2
    done
    return 1
  done < <(ls -A "$1")
}

bootstrap() {
  need git
  if [[ -d $LYANEMACS_DIR/.git ]]; then
    local remote
    remote=$(git -C "$LYANEMACS_DIR" remote get-url origin 2>/dev/null || true)
    [[ $(normalize_url "$remote") == "$(normalize_url "$LYANEMACS_REPO")" ]] ||
      die "$LYANEMACS_DIR is a checkout of '${remote:-no origin}', not $LYANEMACS_REPO; set LYANEMACS_DIR to another path"
    log "Using checkout $LYANEMACS_DIR"
  elif [[ -e $LYANEMACS_DIR && -n $(ls -A "$LYANEMACS_DIR" 2>/dev/null) ]]; then
    only_tool_entries "$LYANEMACS_DIR" ||
      die "$LYANEMACS_DIR exists and is not a lyanemacs checkout; set LYANEMACS_DIR to another path"
    # `lsp` ran here before the clone; check the repo out around its tools.
    log "Cloning $LYANEMACS_REPO into $LYANEMACS_DIR (keeping installed LSP tools)"
    local tmp
    tmp=$(mktemp -d)
    git clone --no-checkout "$LYANEMACS_REPO" "$tmp/repo"
    mv "$tmp/repo/.git" "$LYANEMACS_DIR/.git"
    rm -rf "$tmp"
    git -C "$LYANEMACS_DIR" reset --quiet --hard
  else
    log "Cloning $LYANEMACS_REPO -> $LYANEMACS_DIR"
    mkdir -p "$(dirname "$LYANEMACS_DIR")"
    git clone "$LYANEMACS_REPO" "$LYANEMACS_DIR"
  fi
  exec bash "$LYANEMACS_DIR/scripts/setup.sh" "$@"
}

# ---------------------------------------------------------------- emacs

apt_emacs_packages() {
  have dpkg-query || return 0
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null |
    awk '$1 ~ /^.i/ && $2 ~ /^emacs[0-9]*(-(gtk|nox|lucid|pgtk|common|bin-common|el|common-non-dfsg))?$/ { print $2 }'
}

emacs_major() {
  "$1" --batch --eval '(princ emacs-major-version)' 2>/dev/null || echo 0
}

install_emacs() {
  local pkgs
  pkgs=$(apt_emacs_packages | xargs)
  if [[ -n $pkgs ]]; then
    log "apt Emacs packages installed: $pkgs"
    # Purging can take dependent packages with it; show apt's full plan first.
    apt-get -s purge $pkgs 2>/dev/null | awk '/^Purg/ { print "    " $2 }'
    if ask "Purge the packages above (snap Emacs replaces them)?" y; then
      as_root apt-get purge -y $pkgs
    else
      warn "Kept apt Emacs; /usr/bin/emacs may shadow the snap one"
    fi
  fi

  if have snap && snap list emacs >/dev/null 2>&1; then
    local version
    version=$(snap list emacs | awk 'NR == 2 { print $2 }')
    if ((${version%%.*} >= 31)); then
      ok "snap Emacs $version"
    else
      log "snap Emacs $version is older than 31, refreshing"
      as_root snap refresh emacs --classic --channel=latest/stable
    fi
  elif have snap; then
    log "Installing snap Emacs"
    as_root snap install emacs --classic
  elif have emacs && (($(emacs_major emacs) >= 31)); then
    ok "Emacs $(emacs_major emacs) (not from snap)"
  else
    warn "snap is not available; install Emacs 31+ manually"
  fi
}

# Emacs reads ~/.emacs or ~/.emacs.el instead of ~/.emacs.d/init.el if present.
check_shadowing_init() {
  local file
  for file in "$HOME/.emacs" "$HOME/.emacs.el"; do
    [[ -e $file || -L $file ]] || continue
    warn "$file exists, so Emacs would ignore ~/.emacs.d/init.el"
    if ask "Move $file aside?" y; then backup "$file"; fi
  done
}

# ---------------------------------------------------------------- manifest

declare -A RECORDED=() # copied file -> sha256 last written by sync
declare -A MANAGED=()  # copied file -> 1, for entries in the current manifest

load_state() {
  local sum path
  [[ -f $STATE_DIR/copies ]] || return 0
  while IFS=$'\t' read -r sum path; do
    [[ -n $path ]] && RECORDED[$path]=$sum
  done <"$STATE_DIR/copies"
}

save_state() {
  local path
  mkdir -p "$STATE_DIR"
  for path in "${!RECORDED[@]}"; do
    printf '%s\t%s\n' "${RECORDED[$path]}" "$path"
  done | sort -k2 >"$STATE_DIR/copies"
}

show_diff() {
  diff -u --label "local $1" --label "repo  $2" -- "$1" "$2" | head -n 40 || true
}

sync_link() {
  local src=$1 dst=$2
  if [[ -L $dst && $(readlink -- "$dst") == "$src" ]]; then
    ok "link $dst"
    return
  fi
  if [[ -e $dst || -L $dst ]]; then
    if ! [[ -f $dst && ! -L $dst ]] || ! cmp -s -- "$src" "$dst"; then
      warn "$dst exists and differs from $src"
      [[ -f $dst ]] && show_diff "$dst" "$src"
      ask "Replace $dst with a link (backup kept)?" n || {
        warn "Skipped $dst"
        return
      }
    fi
    backup "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s -- "$src" "$dst"
  ok "link $dst -> $src"
}

sync_copy() {
  local src=$1 dst=$2 new cur
  new=$(sha "$src")
  MANAGED[$dst]=1
  if [[ ! -e $dst && ! -L $dst ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -- "$src" "$dst"
    RECORDED[$dst]=$new
    ok "copy $dst (new)"
    return
  fi
  cur=$(sha "$dst" 2>/dev/null || echo missing)
  if [[ $cur == "$new" && ! -L $dst ]]; then
    RECORDED[$dst]=$new
    ok "copy $dst"
    return
  fi
  # Unchanged since the last sync: an upstream update, safe to overwrite.
  if [[ ! -L $dst && $cur == "${RECORDED[$dst]:-}" ]]; then
    cp -- "$src" "$dst"
    RECORDED[$dst]=$new
    ok "copy $dst (updated)"
    return
  fi
  warn "$dst was changed outside lyanemacs (edit $src in the repo instead)"
  show_diff "$dst" "$src"
  if ask "Overwrite $dst with the repo version (backup kept)?" n; then
    backup "$dst"
    cp -- "$src" "$dst"
    RECORDED[$dst]=$new
    ok "copy $dst (replaced)"
  else
    warn "Skipped $dst"
  fi
}

sync_git() {
  local url=$1 dst=$2 update=$3 remote
  if [[ -d $dst/.git ]]; then
    remote=$(git -C "$dst" remote get-url origin 2>/dev/null || true)
    if [[ $(normalize_url "$remote") != "$(normalize_url "$url")" ]]; then
      warn "$dst tracks '${remote:-no origin}', not $url; left alone"
    elif ((update)); then
      git -C "$dst" pull --ff-only --quiet && ok "git $dst (pulled)" || warn "git pull failed in $dst"
    else
      ok "git $dst"
    fi
  elif [[ -e $dst ]]; then
    warn "$dst exists but is not a git checkout; left alone"
  else
    mkdir -p "$(dirname "$dst")"
    git clone --quiet --depth 1 "$url" "$dst"
    ok "git $dst (cloned)"
  fi
}

# sync_files UPDATE: apply manifest.tsv; UPDATE=1 also pulls git entries.
sync_files() {
  local update=${1:-0} line type src dst rest path
  local -a lines
  log "Syncing files from $REPO/manifest.tsv"
  load_state
  mapfile -t lines < <(grep -Ev '^[[:space:]]*(#|$)' "$REPO/manifest.tsv")
  for line in "${lines[@]}"; do
    read -r type src dst rest <<<"$line"
    dst=${dst/#\~/$HOME}
    case $type in
      link | copy)
        [[ -f $REPO/$src ]] || die "manifest.tsv: $src not found"
        "sync_$type" "$REPO/$src" "$dst"
        ;;
      git) sync_git "$src" "$dst" "$update" ;;
      *) die "manifest.tsv: unknown type '$type'" ;;
    esac
  done
  for path in "${!RECORDED[@]}"; do
    [[ -n ${MANAGED[$path]:-} ]] && continue
    warn "$path is no longer in manifest.tsv; remove it by hand if unused"
    unset 'RECORDED[$path]'
  done
  save_state
}

# ---------------------------------------------------------------- agents

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

cmd_agent() {
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

# ---------------------------------------------------------------- lsp

lang_name() {
  case $1 in
    python | py | pylsp) echo python ;;
    web | html | js | ts | javascript | typescript | css | json) echo web ;;
    c | cpp | c++ | clangd) echo c ;;
    rust | rs | rust-analyzer) echo rust ;;
    lisp | cl | common-lisp | sbcl) echo lisp ;;
    php | phpactor) echo php ;;
    *) return 1 ;;
  esac
}

lang_installed() {
  case $1 in
    python) [[ -x $TOOLS_DIR/.venv/bin/pylsp ]] ;;
    web) [[ -x $TOOLS_DIR/node_modules/.bin/typescript-language-server &&
      -x $TOOLS_DIR/node_modules/.bin/vscode-html-language-server ]] ;;
    c) have clangd ;;
    rust) rust-analyzer --version >/dev/null 2>&1 ;;
    lisp) have sbcl ;;
    php) [[ -x $TOOLS_DIR/vendor/bin/phpactor ]] ;;
  esac
}

# pylsp in $TOOLS_DIR/.venv; a project's own .venv/bin still comes first in Emacs.
install_lang_python() {
  need python3
  python3 -c 'import ensurepip' 2>/dev/null || apt_install python3-venv
  mkdir -p "$TOOLS_DIR"
  [[ -x $TOOLS_DIR/.venv/bin/python ]] || python3 -m venv "$TOOLS_DIR/.venv"
  "$TOOLS_DIR/.venv/bin/pip" install --quiet --upgrade pip
  "$TOOLS_DIR/.venv/bin/pip" install --upgrade "${PY_PACKAGES[@]}"
}

# typescript-language-server, vscode-langservers-extracted and prettier in
# $TOOLS_DIR/node_modules.  Tree-sitter grammars are compiled on first start, so a
# C compiler is needed too.
install_lang_web() {
  need cc build-essential
  ensure_node
  mkdir -p "$TOOLS_DIR"
  npm install --prefix "$TOOLS_DIR" --no-fund --no-audit "${NPM_PACKAGES[@]/%/@latest}"
}

# Projects need compile_commands.json (cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON,
# or `bear -- make` for Makefile projects).
install_lang_c() { apt_install clangd bear; }

install_lang_rust() {
  if ! have rustup; then
    ask "rustup not found. Install it from https://sh.rustup.rs?" y || return 0
    curl -fsSL https://sh.rustup.rs | sh -s -- -y
    setup_path
  fi
  rustup component add rust-analyzer
}

install_lang_lisp() { apt_install sbcl; }

install_lang_php() {
  apt_install php-cli php-xml php-mbstring unzip composer
  mkdir -p "$TOOLS_DIR"
  composer require --no-interaction --working-dir="$TOOLS_DIR" "${COMPOSER_PACKAGES[@]}"
}

cmd_lsp() {
  local name arg upgrade=0
  local -a chosen=()
  for arg in "$@"; do
    name=$(lang_name "$arg") || die "Unknown language '$arg' (known: ${LANGS[*]})"
    chosen+=("$name")
  done
  if ((${#chosen[@]})); then upgrade=1; else chosen=("${LANGS[@]}"); fi

  for name in "${chosen[@]}"; do
    if ! ((upgrade)) && lang_installed "$name"; then
      ok "$name installed"
      continue
    fi
    if ! ((upgrade)); then
      ask "Install the $name language server?" n || {
        log "Skipped $name"
        continue
      }
    fi
    log "Installing $name"
    "install_lang_$name"
    if lang_installed "$name"; then ok "$name installed"; else warn "$name is still not detected"; fi
  done
}

# ---------------------------------------------------------------- commands

cmd_install() {
  need git
  need curl
  install_emacs
  check_shadowing_init
  sync_files 0
  cat <<EOF

Done.  Next:
  $REPO/scripts/setup.sh agent   # ACP agents for agent-shell
  $REPO/scripts/setup.sh lsp     # language servers for eglot
  emacs                          # first start installs the Emacs packages
EOF
}

cmd_pull() {
  log "Updating $REPO"
  if [[ -n $(git -C "$REPO" status --porcelain --untracked-files=no) ]]; then
    warn "Uncommitted changes in $REPO:"
    git -C "$REPO" status --short --untracked-files=no >&2
  fi
  git -C "$REPO" pull --ff-only ||
    die "git pull failed; commit or stash local changes in $REPO, then rerun pull"
  # Hand over to the freshly pulled script.
  exec bash "$REPO/scripts/setup.sh" ${FLAGS[@]+"${FLAGS[@]}"} sync --update
}

cmd_sync() {
  local update=0
  [[ ${1:-} == --update ]] && update=1
  sync_files "$update"
}

main() {
  local -a args=()
  local arg
  for arg in "$@"; do
    case $arg in
      -y | --yes)
        ASSUME_YES=1
        FLAGS+=("$arg")
        ;;
      -h | --help) usage; exit 0 ;;
      *) args+=("$arg") ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}

  local cmd=${1:-install}
  if ! REPO=$(script_repo); then
    REPO=
    case $cmd in
      agent | lsp) ;;
      *) bootstrap ${FLAGS[@]+"${FLAGS[@]}"} "$@" ;;
    esac
  fi
  TOOLS_DIR=${REPO:-$LYANEMACS_DIR}
  setup_path

  shift || true
  case $cmd in
    install) cmd_install ;;
    pull) cmd_pull ;;
    sync) cmd_sync "$@" ;;
    agent) cmd_agent "$@" ;;
    lsp) cmd_lsp "$@" ;;
    *) usage >&2; exit 1 ;;
  esac
}

# Everything runs from here, so a truncated download executes nothing.
main "$@"
