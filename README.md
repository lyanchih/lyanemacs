# lyanemacs

我的 Emacs 設定，取代原本用 gist 在家中 / 工作電腦間同步的方式。
`scripts/setup.sh` 負責安裝 Emacs、同步設定；語言環境、ACP agents、LSP 各自
獨立成 `lang.sh`、`agent.sh`、`lsp.sh`，由 `setup.sh` 轉交執行。
本機執行或 `curl | bash` 都可以。

## 使用

```sh
# 新電腦：purge apt Emacs、安裝 snap Emacs 31+、link / copy 設定檔
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash

# 拉最新設定：git pull 後更新複製的檔案 (symlink 不需處理)
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- pull

# 語言環境：沒裝的逐一詢問 y/N；指定名稱則直接安裝 / 升級
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lang
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lang node rust

# ACP agents：同上
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- agent
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- agent claude codex

# LSP：同上
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lsp
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lsp python rust
```

> 經 pipe 傳參數要用 `bash -s -- <args>`；`bash -- pull` 會把 `pull` 當成腳本檔名。

已經有 checkout 時直接跑 `scripts/setup.sh <command>` 即可。
從 curl 執行 `install` / `pull` / `sync` 時，腳本會 clone (或沿用) `~/repos/lyanemacs`，
再執行那份 checkout 裡的 `scripts/setup.sh`，所以兩種方式行為相同。
`lang` / `agent` / `lsp` 不需要 checkout：`setup.sh` 會執行 checkout 裡的
`lang.sh` / `agent.sh` / `lsp.sh`，從 pipe 執行時則下載後執行，適合只需要
agent / LSP 的 TRAMP 遠端主機。這三支也能直接執行，例如
`curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/agent.sh | bash -s -- claude`；
`setup.sh agent -h` 會顯示 `agent.sh` 自己的說明。

| 指令 | 說明 |
| --- | --- |
| `install` (預設) | purge apt Emacs (v29)、安裝 snap Emacs 31+、套用 `manifest.tsv` |
| `pull` | `git pull --ff-only`，再以新版腳本執行 `sync --update` |
| `sync` | 只重新套用 `manifest.tsv` (改了 `lisp/*.el` 之後用) |
| `lang [name...]` | `lang.sh`：`python` (python3、pip、venv) `node` (nvm + Node.js LTS) `rust` (rustup) |
| `agent [name...]` | `agent.sh`：`claude` `codex` `cursor` `antigravity` `opencode` |
| `lsp [lang...]` | `lsp.sh`：`python` `web` (html/js/ts/css/json) `c` (c/c++) `rust` `lisp` `php` |

選項：`-y` / `--yes` 所有提問都回答 yes (被取代的檔案仍會備份)。
環境變數：`LYANEMACS_DIR` (checkout 位置，沒有 checkout 時也是 `lsp` 的安裝位置)、
`LYANEMACS_REPO` (git URL)、`LYANEMACS_SITE` (從 pipe 執行時下載其他腳本的網址)。

## 目錄

```
lisp/             所有 Emacs Lisp
  init.el           基本設定：套件、環境、外觀 / layout、buffer、dired、ace-window
  my-shell.el       TRAMP、Ghostel
  my-lang.el        各語言 mode、LSP (eglot)、格式化
  my-agent-shell.el 上半部 agent-shell 擴充；下半部各 agent 所需實做
  agent-shell-*.el  agent-shell 擴充套件 (複製到 ~/.emacs.d/lisp)
scripts/
  setup.sh          安裝 Emacs、同步設定；轉交 lang / agent / lsp
  lang.sh           語言環境：python3、Node.js (nvm)、rust
  agent.sh          ACP agents
  lsp.sh            LSP servers
  common.sh         共用函式；各腳本從同目錄載入，pipe 執行時自動下載
manifest.tsv      哪些檔案 link、哪些 copy、哪些 git clone
```

## manifest.tsv 與覆寫防呆

- `link`：symlink 到 repo，`init.el` 與 `my-*.el` 用這種。在 Emacs 改這些檔
  就是改 repo，記得 commit。
- `copy`：複製到 `~/.emacs.d/lisp/`。sync 時會記錄每個檔案的 sha256
  (`~/.local/state/lyanemacs/copies`)：
  - 本機副本沒被改過 → 直接更新成 repo 版本
  - 本機副本被改過 → 顯示 diff 並詢問，同意才覆寫
- `git`：第三方套件，第一次 clone，`pull` 時 fast-forward。

任何要取代的既有檔案都會先備份成 `<檔名>.bak.<時間>`。沒有終端機可詢問時
(且沒加 `-y`) 一律視為 No，不會覆寫。`~/.emacs` / `~/.emacs.el` 存在時會讓
Emacs 忽略 `~/.emacs.d/init.el`，`install` 會提示移開。

## 語言環境

| 名稱 | 內容 | 安裝方式 |
| --- | --- | --- |
| python | python3、pip、venv | apt |
| node | nvm + Node.js LTS | nvm 官方安裝腳本；升級時帶上原本的全域 npm 套件 |
| rust | rustup + stable toolchain | https://sh.rustup.rs；升級為 `rustup update` |

`agent.sh`、`lsp.sh` 缺少所需環境時 (例如 claude / codex 需要 Node.js) 會先詢問，
再以 `lang.sh --ensure` 安裝。

## Agents

| 名稱 | 安裝方式 | 位置 |
| --- | --- | --- |
| claude | `npm i -g @agentclientprotocol/claude-agent-acp` | npm global (缺 Node.js 時由 `lang.sh` 安裝) |
| codex | `npm i -g @agentclientprotocol/codex-acp` | npm global |
| cursor | `curl https://cursor.com/install \| bash` | `~/.local/bin/cursor-agent` |
| antigravity | ACP registry 的 binary，驗 sha256 | `~/.cache/agent-shell/antigravity/<platform>`，wrapper 在 `~/.local/bin/agy_acp_server.par` |
| opencode | `curl https://opencode.ai/install \| bash` | `~/.opencode/bin` |

TRAMP 遠端要用 agent 時，在遠端主機上也跑一次 `setup.sh agent` (不需 clone repo)。

## LSP

| 語言 | Server | 位置 |
| --- | --- | --- |
| python | pylsp | repo `.venv` (專案自己的 `.venv/bin` 仍優先) |
| web | typescript-language-server、vscode-langservers-extracted、prettier | repo `node_modules` |
| c | clangd、bear | apt |
| rust | rust-analyzer | rustup component |
| lisp | sbcl (搭配 SLY) | apt |
| php | phpactor | repo `vendor` |

「repo」指執行腳本的 checkout；從 curl 執行且沒有 checkout 時，裝在
`$LYANEMACS_DIR` (預設 `~/repos/lyanemacs`)，之後 `install` 會直接在該目錄
clone repo 並保留已安裝的工具。套件清單寫在 `scripts/lsp.sh` 的
`PY_PACKAGES`、`NPM_PACKAGES`、`COMPOSER_PACKAGES`。

init.el 會把 repo 的 `.venv/bin`、`node_modules/.bin`、`vendor/bin` 加進
`exec-path`；TRAMP 遠端則找 `~/repos/lyanemacs` 下的同樣路徑。

新增語言：在 `scripts/lsp.sh` 加 `install_<name>`，並更新 `LANGS`、
`server_name`、`server_installed`。

## GitHub Pages

repo 根目錄的 `CNAME` 是 `lyanemacs.qiyecaotw.net`。在 repo Settings → Pages 從
`master` 分支發佈，並在 DNS 加一筆 `lyanemacs` CNAME → `lyanchih.github.io`。

首頁 `index.html` 是純靜態頁面：提供各指令 (可勾選語言環境 / agent / LSP) 與複製按鈕，
並依 `manifest.tsv` 列出檔案、點檔名即可在頁面中檢視。可勾選的名稱讀自
`lang.sh` 的 `RUNTIMES`、`agent.sh` 的 `AGENTS`、`lsp.sh` 的 `LANGS`，新增項目不需改頁面。

頁首右上角顯示部署版本 (commit 短碼 · 建置時間，連到該 commit)，由 GitHub Pages
的 Jekyll 在每次部署時自動填入 (`index.html` 的 front matter、`_config.yml` 設定台北時區)，
不需手動更新；檔案檢視的 GitHub 連結也指向同一個 commit。
