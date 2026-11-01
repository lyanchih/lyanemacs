#!/usr/bin/env bash
# lyanemacs setup: install Emacs and sync this repo's config into ~/.emacs.d.
#
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- pull
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lang|agent|lsp [name...]
#   scripts/setup.sh <command>                         (from a checkout)
#
# Piped from curl, install / pull / sync clone (or reuse) $LYANEMACS_DIR and
# re-run that checkout's copy of the script, so both ways behave the same.
# lang / agent / lsp are separate scripts (lang.sh, agent.sh, lsp.sh); setup.sh
# runs them from the checkout, or downloads them when piped, without cloning.

set -euo pipefail

STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/lyanemacs
# What lsp.sh may leave in $LYANEMACS_DIR before the repo is cloned there.
TOOL_ENTRIES=(.venv node_modules vendor package.json package-lock.json composer.json composer.lock)

REPO= # checkout to sync from

usage() {
  cat <<'EOF'
Usage: setup.sh [-y] [command] [args...]

Commands:
  install            (default) purge apt Emacs, install snap Emacs 31+,
                     link/copy files listed in manifest.tsv
  pull               git pull this repo, then sync (copies and git entries updated)
  sync               apply manifest.tsv again without pulling
  lang [name...]     run lang.sh:  python3 + pip + venv, nvm + Node.js, rust
  agent [name...]    run agent.sh: ACP agents claude codex cursor antigravity opencode
  lsp [lang...]      run lsp.sh:   LSP servers python web c rust lisp php

lang, agent and lsp need no checkout (e.g. on a TRAMP remote host); see
`setup.sh <command> -h` for their own options.

Options:
  -y, --yes          answer yes to every prompt (replaced files are still backed up)
  -h, --help         show this help

Environment:
  LYANEMACS_DIR      checkout used when piped from curl (default ~/repos/lyanemacs)
  LYANEMACS_REPO     git URL to clone (default https://github.com/lyanchih/lyanemacs.git)
  LYANEMACS_SITE     where piped scripts download their siblings
                     (default https://lyanemacs.qiyecaotw.net)
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

sha() { sha256sum -- "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------- bootstrap

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
  [[ -z ${COMMON_TMP:-} ]] || rm -rf "$COMMON_TMP"
  exec bash "$LYANEMACS_DIR/scripts/setup.sh" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
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

# ---------------------------------------------------------------- commands

cmd_install() {
  need git
  need curl
  install_emacs
  check_shadowing_init
  sync_files 0
  cat <<EOF

Done.  Next:
  $REPO/scripts/setup.sh lang    # python3, Node.js (nvm), rust
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

# lang / agent / lsp live in their own scripts; hand them every other argument,
# so `setup.sh agent -h` shows agent.sh's help.
delegate() {
  local cmd=$1 arg seen=0
  local -a rest=()
  shift
  for arg in "$@"; do
    if ((!seen)) && [[ $arg == "$cmd" ]]; then
      seen=1
      continue
    fi
    rest+=("$arg")
  done
  run_script "$cmd.sh" ${rest[@]+"${rest[@]}"}
  exit
}

main() {
  load_common
  local arg
  for arg in "$@"; do
    [[ $arg == -* ]] && continue
    case $arg in lang | agent | lsp) delegate "$arg" "$@" ;; esac
    break
  done

  parse_args "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  local cmd=${1:-install}
  shift || true
  case $cmd in
    install | pull | sync) ;;
    *) usage >&2; exit 1 ;;
  esac
  [[ -n $CHECKOUT ]] || bootstrap "$cmd" "$@"
  REPO=$CHECKOUT
  setup_path

  case $cmd in
    install) cmd_install ;;
    pull) cmd_pull ;;
    sync) cmd_sync "$@" ;;
  esac
}

# Everything runs from here, so a truncated download executes nothing.
main "$@"
