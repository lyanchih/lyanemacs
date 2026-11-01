# shellcheck shell=bash
# Shared helpers for scripts/*.sh.  Sourced, never run: each script loads it
# from next to itself, or downloads it when the script is piped from curl.

LYANEMACS_SITE=${LYANEMACS_SITE:-https://lyanemacs.qiyecaotw.net}
LYANEMACS_REPO=${LYANEMACS_REPO:-https://github.com/lyanchih/lyanemacs.git}
LYANEMACS_DIR=${LYANEMACS_DIR:-$HOME/repos/lyanemacs}

# Directory of the scripts; a temporary one when piped from curl.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# Checkout the scripts belong to; empty when piped from curl.
CHECKOUT=
if [[ -f $SCRIPT_DIR/../manifest.tsv && -d $SCRIPT_DIR/../lisp ]]; then
  CHECKOUT=$(cd "$SCRIPT_DIR/.." && pwd -P)
fi

ASSUME_YES=0
FLAGS=() # options handed on to scripts started with run_script
ARGS=()  # arguments left after parse_args

# parse_args ARGS...: take out -y and -h (which calls the script's usage).
parse_args() {
  local arg
  for arg in "$@"; do
    case $arg in
      -y | --yes)
        ASSUME_YES=1
        FLAGS+=("$arg")
        ;;
      -h | --help) usage; exit 0 ;;
      *) ARGS+=("$arg") ;;
    esac
  done
}

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

# run_script NAME ARGS...: run scripts/NAME, downloading it first when this
# script was piped from curl.
run_script() {
  local name=$1
  shift
  if [[ ! -f $SCRIPT_DIR/$name ]]; then
    curl -fsSL "$LYANEMACS_SITE/scripts/$name" -o "$SCRIPT_DIR/$name" ||
      die "Cannot download $LYANEMACS_SITE/scripts/$name"
  fi
  bash "$SCRIPT_DIR/$name" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
}

# need_lang NAME...: make sure lang.sh runtimes are installed (asks first).
need_lang() {
  run_script lang.sh --ensure "$@" || die "Required runtime missing: $*"
  setup_path
}
