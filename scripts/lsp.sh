#!/usr/bin/env bash
# lyanemacs lsp: install the language servers used by eglot in lisp/my-lang.el.
#
#   curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/lsp.sh | bash -s -- [lang...]
#   scripts/lsp.sh [lang...]                        (or: scripts/setup.sh lsp ...)

set -euo pipefail

LANGS=(python web c rust lisp php)

# Project-local packages, installed into $TOOLS_DIR.
PY_PACKAGES=('python-lsp-server[all]')
NPM_PACKAGES=(typescript typescript-language-server vscode-langservers-extracted prettier)
COMPOSER_PACKAGES=(phpactor/phpactor)

TOOLS_DIR= # the checkout, else $LYANEMACS_DIR

usage() {
  cat <<'EOF'
Usage: lsp.sh [-y] [lang...]

Languages:
  python   pylsp                                  -> .venv
  web      typescript-language-server,
           vscode-langservers-extracted, prettier -> node_modules
  c        clangd, bear (c / c++)                 -> apt
  rust     rust-analyzer                          -> rustup component
  lisp     sbcl (Common Lisp, used with SLY)      -> apt
  php      phpactor                               -> vendor

No names: ask for each missing one.  Names: install or upgrade them.
.venv, node_modules and vendor go into the checkout this script runs from,
else $LYANEMACS_DIR (default ~/repos/lyanemacs), where init.el looks for them.
Missing runtimes (python, Node.js, rust) are installed by lang.sh after asking.

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

server_name() {
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

server_installed() {
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
install_python() {
  need_lang python
  mkdir -p "$TOOLS_DIR"
  [[ -x $TOOLS_DIR/.venv/bin/python ]] || python3 -m venv "$TOOLS_DIR/.venv"
  "$TOOLS_DIR/.venv/bin/pip" install --quiet --upgrade pip
  "$TOOLS_DIR/.venv/bin/pip" install --upgrade "${PY_PACKAGES[@]}"
}

# typescript-language-server, vscode-langservers-extracted and prettier in
# $TOOLS_DIR/node_modules.  Tree-sitter grammars are compiled on first start, so a
# C compiler is needed too.
install_web() {
  need cc build-essential
  need_lang node
  mkdir -p "$TOOLS_DIR"
  npm install --prefix "$TOOLS_DIR" --no-fund --no-audit "${NPM_PACKAGES[@]/%/@latest}"
}

# Projects need compile_commands.json (cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON,
# or `bear -- make` for Makefile projects).
install_c() { apt_install clangd bear; }

install_rust() {
  need_lang rust
  rustup component add rust-analyzer
}

install_lisp() { apt_install sbcl; }

install_php() {
  apt_install php-cli php-xml php-mbstring unzip composer
  mkdir -p "$TOOLS_DIR"
  composer require --no-interaction --working-dir="$TOOLS_DIR" "${COMPOSER_PACKAGES[@]}"
}

main() {
  load_common
  parse_args "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  TOOLS_DIR=${CHECKOUT:-$LYANEMACS_DIR}
  setup_path

  local name arg upgrade=0
  local -a chosen=()
  for arg in "$@"; do
    name=$(server_name "$arg") || die "Unknown language '$arg' (known: ${LANGS[*]})"
    chosen+=("$name")
  done
  if ((${#chosen[@]})); then upgrade=1; else chosen=("${LANGS[@]}"); fi

  for name in "${chosen[@]}"; do
    if ! ((upgrade)) && server_installed "$name"; then
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
    "install_$name"
    if server_installed "$name"; then ok "$name installed"; else warn "$name is still not detected"; fi
  done
}

# Everything runs from here, so a truncated download executes nothing.
main "$@"
