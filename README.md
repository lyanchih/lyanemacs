# lyanemacs

我的 Emacs 設定，取代原本用 gist 在家中 / 工作電腦間同步的方式。
一支 `scripts/setup.sh` 負責安裝 Emacs、同步設定、安裝 ACP agents 與 LSP，
本機執行或 `curl | bash` 都可以。

## 使用

```sh
# 新電腦：purge apt Emacs、安裝 snap Emacs 31+、link / copy 設定檔
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash

# 拉最新設定：git pull 後更新複製的檔案 (symlink 不需處理)
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- pull

# ACP agents：沒裝的逐一詢問 y/N；指定名稱則直接安裝 / 升級
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- agents
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- agents claude codex

# LSP：同上
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lsp
curl -fsSL https://lyanemacs.qiyecaotw.net/scripts/setup.sh | bash -s -- lsp python rust
```

> 經 pipe 傳參數要用 `bash -s -- <args>`；`bash -- pull` 會把 `pull` 當成腳本檔名。

已經有 checkout 時直接跑 `scripts/setup.sh <command>` 即可。
從 curl 執行時，腳本會 clone (或沿用) `~/repos/lyanemacs`，
再執行那份 checkout 裡的 `scripts/setup.sh`，所以兩種方式行為相同。

| 指令 | 說明 |
| --- | --- |
| `install` (預設) | purge apt Emacs (v29)、安裝 snap Emacs 31+、套用 `manifest.tsv` |
| `pull` | `git pull --ff-only`，再以新版腳本執行 `sync --update` |
| `sync` | 只重新套用 `manifest.tsv` (改了 `lisp/*.el` 之後用) |
| `agents [name...]` | `claude` `codex` `cursor` `antigravity` `opencode` |
| `lsp [lang...]` | `python` `web` (html/js/ts/css/json) `c` (c/c++) `rust` `lisp` `php` |

選項：`-y` / `--yes` 所有提問都回答 yes (被取代的檔案仍會備份)。
環境變數：`LYANEMACS_DIR` (checkout 位置)、`LYANEMACS_REPO` (git URL)。

## 目錄

```
lisp/             所有 Emacs Lisp，包括 init.el
scripts/setup.sh  安裝 / 同步腳本
manifest.tsv      哪些檔案 link、哪些 copy、哪些 git clone
requirements.txt / package.json / composer.json
                  `setup.sh lsp` 裝在本 repo 的 .venv / node_modules / vendor
```

## manifest.tsv 與覆寫防呆

- `link`：symlink 到 repo，`~/.emacs.d/init.el` 用這種。在 Emacs 改 init.el
  就是改 repo，記得 commit。
- `copy`：複製到 `~/.emacs.d/lisp/`。sync 時會記錄每個檔案的 sha256
  (`~/.local/state/lyanemacs/copies`)：
  - 本機副本沒被改過 → 直接更新成 repo 版本
  - 本機副本被改過 → 顯示 diff 並詢問，同意才覆寫
- `git`：第三方套件，第一次 clone，`pull` 時 fast-forward。

任何要取代的既有檔案都會先備份成 `<檔名>.bak.<時間>`。沒有終端機可詢問時
(且沒加 `-y`) 一律視為 No，不會覆寫。`~/.emacs` / `~/.emacs.el` 存在時會讓
Emacs 忽略 `~/.emacs.d/init.el`，`install` 會提示移開。

## Agents

| 名稱 | 安裝方式 | 位置 |
| --- | --- | --- |
| claude | `npm i -g @agentclientprotocol/claude-agent-acp` | npm global (沒有 Node 會先裝 nvm) |
| codex | `npm i -g @agentclientprotocol/codex-acp` | npm global |
| cursor | `curl https://cursor.com/install \| bash` | `~/.local/bin/cursor-agent` |
| antigravity | ACP registry 的 binary，驗 sha256 | `~/.cache/agent-shell/antigravity/<platform>`，wrapper 在 `~/.local/bin/agy_acp_server.par` |
| opencode | `curl https://opencode.ai/install \| bash` | `~/.opencode/bin` |

TRAMP 遠端要用 agent 時，在遠端主機上也跑一次 `setup.sh agents`。

## LSP

| 語言 | Server | 位置 |
| --- | --- | --- |
| python | pylsp | repo `.venv` (專案自己的 `.venv/bin` 仍優先) |
| web | typescript-language-server、vscode-langservers-extracted、prettier | repo `node_modules` |
| c | clangd、bear | apt |
| rust | rust-analyzer | rustup component |
| lisp | sbcl (搭配 SLY) | apt |
| php | phpactor | repo `vendor` |

init.el 會把 repo 的 `.venv/bin`、`node_modules/.bin`、`vendor/bin` 加進 `exec-path`。

新增語言：在 `scripts/setup.sh` 加 `install_lang_<name>`，並更新 `LANGS`、
`lang_name`、`lang_installed`。

## GitHub Pages

repo 根目錄的 `CNAME` 是 `lyanemacs.qiyecaotw.net`。在 repo Settings → Pages 從
`master` 分支發佈，並在 DNS 加一筆 `lyanemacs` CNAME → `lyanchih.github.io`。
