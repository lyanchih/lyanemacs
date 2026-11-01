#!/usr/bin/env bash
# lyanemacs lang: install language runtimes (python3 + pip + venv, nvm + Node.js, rust).
#
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/lang.sh | bash -s -- [name...]
#   scripts/lang.sh [name...]                       (or: scripts/setup.sh lang ...)

set -euo pipefail

RUNTIMES=(python node rust)
NVM_VERSION=v0.40.3

usage() {
  cat <<'EOF'
Usage: lang.sh [-y] [--ensure] [name...]

Runtimes:
  python   python3, pip and venv (apt)
  node     nvm + Node.js LTS (also: nvm, nodejs, npm)
  rust     rustup + stable toolchain (also: rustup, cargo)

No names: ask for each missing runtime.  Names: install them, or upgrade
when already installed (Node.js keeps its global npm packages).
--ensure: only install the named runtimes when missing, after asking;
exit 1 if any is still missing (used by agent.sh and lsp.sh).

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

runtime_name() {
  case $1 in
    python | python3 | py | pip | venv) echo python ;;
    node | nodejs | nvm | npm | js) echo node ;;
    rust | rustup | cargo | rs) echo rust ;;
    *) return 1 ;;
  esac
}

runtime_installed() {
  case $1 in
    python) have python3 && python3 -m pip --version >/dev/null 2>&1 &&
      python3 -c 'import ensurepip' 2>/dev/null ;;
    node) [[ -s ${NVM_DIR:-$HOME/.nvm}/nvm.sh ]] && have node ;;
    rust) have rustup && have cargo ;;
  esac
}

runtime_version() {
  case $1 in
    python) python3 --version 2>&1 | cut -d' ' -f2 ;;
    node) node --version ;;
    rust) rustc --version 2>/dev/null | cut -d' ' -f2 ;;
  esac
}

# nvm is a shell function that does not cope with -e / -u.
nvm_run() {
  local status=0
  set +eu
  nvm "$@" || status=$?
  set -eu
  return "$status"
}

# python3 with pip and venv (Ubuntu's python3 ships without them).
install_python() {
  apt_install python3 python3-pip python3-venv
}

install_node() {
  local upgrade=$1 current latest
  if [[ ! -s ${NVM_DIR:-$HOME/.nvm}/nvm.sh ]]; then
    need curl
    log "Installing nvm $NVM_VERSION"
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash
  fi
  load_nvm || die "nvm install failed"
  current=$(nvm_run current 2>/dev/null || true)
  if [[ $current == v* ]]; then
    ((upgrade)) || return 0
    latest=$(nvm_run version-remote --lts)
    if [[ $current == "$latest" ]]; then
      ok "Node.js $current is the latest LTS"
      return 0
    fi
    log "Upgrading Node.js $current -> $latest (global npm packages carried over)"
    nvm_run install --lts --reinstall-packages-from="$current" || die "nvm install failed"
  else
    nvm_run install --lts || die "nvm install failed"
  fi
  nvm_run alias default 'lts/*' >/dev/null
}

install_rust() {
  local upgrade=$1
  if have rustup; then
    if ((upgrade)); then rustup update; fi
  else
    need curl
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
  fi
}

main() {
  load_common
  parse_args "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  local ensure=0 upgrade=0 missing=0 name arg
  local -a chosen=()
  if [[ ${1:-} == --ensure ]]; then
    ensure=1
    shift
  fi
  for arg in "$@"; do
    name=$(runtime_name "$arg") || die "Unknown runtime '$arg' (known: ${RUNTIMES[*]})"
    chosen+=("$name")
  done
  if ((${#chosen[@]})); then
    ((ensure)) || upgrade=1
  else
    ((!ensure)) || die "--ensure needs runtime names"
    chosen=("${RUNTIMES[@]}")
  fi
  setup_path

  for name in "${chosen[@]}"; do
    if ! ((upgrade)) && runtime_installed "$name"; then
      ((ensure)) || ok "$name $(runtime_version "$name")"
      continue
    fi
    if ((ensure)); then
      ask "$name is required but not installed. Install it?" y || {
        missing=1
        continue
      }
    elif ! ((upgrade)); then
      ask "Install $name?" n || {
        log "Skipped $name"
        continue
      }
    fi
    log "Installing $name"
    "install_$name" "$upgrade"
    setup_path
    if runtime_installed "$name"; then
      ok "$name $(runtime_version "$name")"
    else
      warn "$name is still not detected; open a new shell"
      missing=1
    fi
  done
  ((!ensure || !missing))
}

# Everything runs from here, so a truncated download executes nothing.
main "$@"
