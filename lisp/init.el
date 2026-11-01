;; -*- lexical-binding: t -*-

(require 'package)

(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))

(package-initialize)

(package-install 'agent-shell)
(package-install 'ace-window)
(package-install 'php-mode)
(package-install 'yaml-mode)
(package-install 'magit)
(use-package ghostel
  :ensure t)

(use-package ace-window
  :ensure t
  ;; bind* 讓 M-o 優先於各 major/minor mode 自己的綁定
  :bind* ("M-o" . ace-window))

(require 'tramp)
;; Search the remote user's PATH and OpenCode's default install directory.
(add-to-list 'tramp-remote-path 'tramp-own-remote-path t)
(add-to-list 'tramp-remote-path "~/.opencode/bin")
(require 'subr-x)
(load-theme 'modus-vivendi t)
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode t)
(tab-bar-mode -1)

;; 隱藏左右 fringe
(fringe-mode 0)

;; 啟動時最大化
(add-to-list 'default-frame-alist '(fullscreen . maximized))

;; 邊框縮到最小
(add-to-list 'default-frame-alist '(internal-border-width . 0))


(setq-default mode-line-format nil)

(window-divider-mode 1)

(setq window-divider-default-right-width 2)
(setq window-divider-default-bottom-width 2)

(set-face-foreground 'window-divider "#666666")
(set-face-foreground 'window-divider-first-pixel "#666666")
(set-face-foreground 'window-divider-last-pixel "#666666")

(defun my-new-ghostel ()
  "Create a new Ghostel terminal.

Local:
  *ghostel*
  *ghostel*<1>
  *ghostel*<2>

TRAMP:
  *tghostel:HOST*
  *tghostel:HOST*<1>
  *tghostel:HOST*<2>

HOST may be a hostname or IP address."
  (interactive)
  (let ((ghostel-buffer-name
         (let ((remote-host (file-remote-p default-directory 'host)))
           (if remote-host
               (format "*tghostel:%s*" remote-host)
             "*ghostel*"))))
    ;; Non-numeric prefix arg = always create a new terminal
    (ghostel '(4))))

(defun my-switch-ghostel-buffer ()
  "Select an existing Ghostel buffer by number, showing its directory.
Include local *ghostel* buffers and remote *tghostel:HOST* buffers,
including numbered suffixes.  Show remote hosts and suffixes in
the completion list, and accept the number alone to switch."
  (interactive)
  (let ((name-regexp
         "\\`\\*\\(?:ghostel\\|tghostel:\\([^*]+\\)\\)\\*\\(<[0-9]+>\\)?\\'")
        buffers entries
        (index 0))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'ghostel-mode)
                   (string-match-p name-regexp (buffer-name)))
          (push buffer buffers))))
    (unless buffers
      (user-error "No Ghostel buffers"))
    (setq buffers
          (sort buffers
                (lambda (left right)
                  (string-version-lessp (buffer-name left)
                                        (buffer-name right)))))
    (dolist (buffer buffers)
      (with-current-buffer buffer
        (let* ((name (buffer-name))
               (parts (save-match-data
                        (string-match name-regexp name)
                        (list (match-string 1 name)
                              (match-string 2 name))))
               (host (or (car parts)
                         (file-remote-p default-directory 'host)))
               (directory (file-local-name default-directory))
               (description
                (if host
                    (string-join
                     (delq nil (list (cadr parts) host directory)) " ")
                  directory)))
          (push (list (number-to-string index) buffer description) entries)
          (setq index (1+ index)))))
    (setq entries (nreverse entries))
    (let* ((completions-format 'one-column)
           (completion-extra-properties
            (list :annotation-function
                  (lambda (candidate)
                    (concat " - " (nth 2 (assoc candidate entries))))))
           (choice
            (completing-read
             "Switch to Ghostel buffer (number): "
             (lambda (string predicate action)
               (if (eq action 'metadata)
                   '(metadata
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
                 (complete-with-action action entries string predicate)))
             nil t))
           (entry (assoc choice entries)))
      (unless entry
        (user-error "No Ghostel buffer selected"))
      (unless (buffer-live-p (nth 1 entry))
        (user-error "Selected Ghostel buffer no longer exists"))
      (switch-to-buffer (nth 1 entry)))))

(global-set-key (kbd "C-c t") #'my-new-ghostel)
(global-set-key (kbd "C-c e") #'my-switch-ghostel-buffer)

(setq make-backup-files nil)
(setq auto-save-default nil)
(setq create-lockfiles nil)

(setq use-short-answers t)

;; --- Add module

(add-to-list 'load-path
             (expand-file-name "~/.emacs.d/site-lisp/dired-single"))


(require 'dired-single)
(defun my-dired-init ()
  "Bunch of stuff to run for dired, either immediately or when it's
   loaded."
  ;; <add other stuff here>
  (define-key dired-mode-map [remap dired-find-file]
    'dired-single-buffer)
  (define-key dired-mode-map [remap dired-mouse-find-file-other-window]
    'dired-single-buffer-mouse)
  (define-key dired-mode-map [remap dired-up-directory]
    'dired-single-up-directory))

;; if dired's already loaded, then the keymap will be bound
(if (boundp 'dired-mode-map)
    ;; we're good to go; just add our bindings
    (my-dired-init)
  ;; it's not loaded yet, so add our bindings to the load-hook
  (add-hook 'dired-load-hook 'my-dired-init))
(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "f")
              #'dired-single-buffer)
  (define-key dired-mode-map (kbd "b")
              #'dired-single-up-directory))
(global-display-line-numbers-mode 1)

(defun my-new-agent-shell ()
  "Create a new agent shell buffer, always starting an additional session.
Unlike `agent-shell' which reuses the existing shell buffer for the
current project, this always creates a new shell."
  (interactive)
  (require 'agent-shell)
  (agent-shell '(4)))

(defvar my/agent-shell-map (make-sparse-keymap)
  "Keymap for agent-shell commands.")

(keymap-global-set "C-c a" my/agent-shell-map)

(use-package agent-shell
  :ensure t
  :config
  (setopt agent-shell-show-cost-indicator t)
  (setq agent-shell-openai-authentication
        (agent-shell-openai-make-authentication :login t))
  (setq agent-shell-antigravity-authentication
        (agent-shell-antigravity-make-authentication :login t))

  (define-key my/agent-shell-map (kbd "a")
              #'agent-shell-switch-buffer)
  (define-key my/agent-shell-map (kbd "s")
              #'my-new-agent-shell)
  )

(use-package exec-path-from-shell
  :ensure t
  :config
  (exec-path-from-shell-initialize)
  ;; Add this after importing PATH so initialization does not overwrite it.
  (let ((opencode-bin (expand-file-name "~/.opencode/bin/")))
    (add-to-list 'exec-path opencode-bin)
    (setenv "PATH" (concat opencode-bin path-separator (getenv "PATH")))))

;; --- lyanemacs
;; init.el 是 symlink 指回 repo；其他 lisp/*.el 由 scripts/setup 複製到 ~/.emacs.d/lisp
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

(defconst my/lyanemacs-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename (or load-file-name buffer-file-name)))))
  "Root of the lyanemacs checkout that init.el is linked from.")

;; `scripts/setup lsp' 把 LSP / prettier 裝在 repo 內 (.venv、node_modules、vendor)
(dolist (dir '("vendor/bin" "node_modules/.bin" ".venv/bin"))
  (let ((bin (expand-file-name dir my/lyanemacs-root)))
    (when (file-directory-p bin)
      (add-to-list 'exec-path bin)
      (setenv "PATH" (concat bin path-separator (getenv "PATH"))))))

(require 'agent-shell-tramp)

(agent-shell-tramp-mode 1)

(with-eval-after-load 'tramp
  ;; 1. 讓 TRAMP 自動讀取遠端使用者的個人設定檔 (~/.profile, ~/.bashrc 等) 裡的 PATH
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)
  ;; 2. 使用 ~ 動態指向當前遠端使用者的家目錄，並排在最前面優先於 /usr/bin
  (add-to-list 'tramp-remote-path "~/.local/node/bin")
  (add-to-list 'tramp-remote-path "~/.opencode/bin")
  (add-to-list 'tramp-remote-path "~/.local/bin")
  ;; 遠端用預設位置 clone lyanemacs 並跑過 `scripts/setup lsp' 時的 LSP
  (dolist (dir '("vendor/bin" "node_modules/.bin" ".venv/bin"))
    (add-to-list 'tramp-remote-path (concat "~/repos/lyanemacs/" dir) t)))

(with-eval-after-load 'agent-shell
  ;; 先確認變數名稱並覆寫啟動指令，讓遠端 sh 自動展開 $HOME（適用所有帳號）
  (setq agent-shell-anthropic-claude-acp-command
        '("sh" "-c" "export PATH=\"$HOME/.local/node/bin:$PATH\"; exec claude-agent-acp")))

(with-eval-after-load 'agent-shell-opencode
  ;; 明確指定 opencode 的絕對路徑與子參數 "acp"
  ;; 用 ~ 可以完美適應不同的遠端使用者 (accton, lyan 等)
  (setq agent-shell-opencode-acp-command '("opencode" "acp")))



;; 1. 確保 Emacs 本地 exec-path 包含 ~/.local/bin
(let ((local-bin (expand-file-name "~/.local/bin/")))
  (add-to-list 'exec-path local-bin)
  (setenv "PATH" (concat local-bin path-separator (getenv "PATH"))))

;; 2. 設定 agent-shell 的 Cursor 指令與認證
(with-eval-after-load 'agent-shell
  ;; 如果你的執行檔是 cursor-agent（或需要指定絕對路徑）：
  (setq agent-shell-cursor-acp-command '("cursor-agent" "acp"))
  ;; 若執行檔是 agent，則為：
  ;; (setq agent-shell-cursor-acp-command '("agent" "acp"))

  ;; 登入認證方式：
  ;; 若已在終端機執行過 `agent login` / `cursor-agent login`，保持預設 :none 即可：
  (setq agent-shell-cursor-authentication
        (agent-shell-cursor-make-authentication :none t))
  ;; 若想讓 Emacs 觸發登入流程，可改為 :login t：
  ;; (setq agent-shell-cursor-authentication
  ;;       (agent-shell-cursor-make-authentication :login t))
  )

(require 'agent-shell-fork-compat)
(agent-shell-fork-compat-mode 1)

(setq-default indent-tabs-mode nil)
(setq tab-width 4)
(use-package yaml-mode
  :ensure t
  :mode ("\\.ya?ml\\'" . yaml-mode))

;; --- git

(use-package magit
  :ensure t)

;; --- dired

(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "/")
    (lambda (pattern)
      (interactive "sFind-name (filename wildcard): ")
      (find-name-dired default-directory pattern))))

;; --- PHP

(use-package php-mode
  :ensure t
  :mode "\\.php\\'")

(use-package eglot
  :hook ((php-mode
          c-mode
          c++-mode
          c-ts-mode
          c++-ts-mode
          python-mode
          python-ts-mode)
         . eglot-ensure))

(setenv "PATH"
        (concat
         (expand-file-name "~/.config/composer/vendor/bin")
         ":"
         (getenv "PATH")))

(add-to-list 'exec-path
             (expand-file-name "~/.config/composer/vendor/bin"))

(use-package posframe
  :ensure t
  :defer t)

(use-package agent-shell-hq
  :vc (:url "https://github.com/sreenivasvrao/agent-shell-hq"
            :rev :newest)
  :commands (agent-shell-hq-toggle
             agent-shell-hq-peek
             agent-shell-hq-label)
  :custom
  (agent-shell-hq-toggle-sidebar-width 40)
  (agent-shell-hq-peek-position 'right)
  (agent-shell-hq-peek-width 50)
  (agent-shell-hq-peek-height 40)
  :config
  (keymap-set my/agent-shell-map "t"
              #'agent-shell-hq-toggle)
  (keymap-set my/agent-shell-map "p"
              #'agent-shell-hq-peek))

(use-package agent-recall
  :vc (:url "https://github.com/mrx-xo/agent-recall"
       :rev :newest)
  :commands (agent-recall-browse
             agent-recall-search
             agent-recall-resume
             agent-recall-reindex)
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :custom
  ;; 改成你的專案根目錄
  (agent-recall-search-paths '("~/repos" "~/.emacs"))
  ;; 最近使用的 Session 排最前面
  (agent-recall-browse-sort 'modified-desc)
  :config
  (keymap-set my/agent-shell-map "r"
              #'agent-recall-browse))

(use-package agent-shell-hq-recall
  :ensure nil
  :demand t
  :config
  (keymap-set my/agent-shell-map "i"
              #'agent-shell-hq-recall-index)
  (keymap-set my/agent-shell-map "l"
              #'agent-shell-hq-recall-here))

;; --- agent-shell

(setq agent-shell-session-strategy 'prompt)
(setq agent-shell-session-restore-verbosity 'full)

(defun my-agent-shell--transcript-user (file except-buffer)
  "Return a shell using transcript FILE other than EXCEPT-BUFFER."
  (seq-find
   (lambda (buffer)
     (and (not (eq buffer except-buffer))
          (with-current-buffer buffer
            (and (derived-mode-p 'agent-shell-mode)
                 agent-shell--transcript-file
                 (or (equal (expand-file-name file)
                            (expand-file-name agent-shell--transcript-file))
                     (file-equal-p file agent-shell--transcript-file))))))
   (buffer-list)))

(defun my-agent-shell-close-and-delete-transcript ()
  "Close the current agent shell and delete its Markdown transcript.
Works from shell and viewport buffers.  Keep the transcript if closing
is cancelled or another live shell uses the same file.  This does not
delete the agent's stored session."
  (interactive)
  (require 'agent-shell)
  (let* ((shell-buffer (or (agent-shell--current-shell)
                           (user-error "Not in an agent-shell or viewport buffer")))
         (shell-name (buffer-name shell-buffer))
         (transcript
          (with-current-buffer shell-buffer
            (when agent-shell--transcript-file
              (expand-file-name agent-shell--transcript-file))))
         (shared (and transcript
                      (my-agent-shell--transcript-user transcript shell-buffer))))
    (when shared
      (user-error "Transcript is also used by %s; shell and file kept"
                  (buffer-name shared)))
    (unless (and (kill-buffer shell-buffer)
                 (not (buffer-live-p shell-buffer)))
      (user-error "Shell closing cancelled; transcript kept"))
    (if (and transcript (file-exists-p transcript))
        (progn
          (when (my-agent-shell--transcript-user transcript nil)
            (user-error "Shell closed; another shell uses transcript %s, so it was kept"
                        transcript))
          (condition-case err
              (progn
                (delete-file transcript)
                (message "Closed %s and deleted %s" shell-name transcript))
            (file-error
             (user-error "Shell closed; could not delete %s: %s"
                         transcript (error-message-string err)))))
      (message "Closed %s; no transcript file to delete" shell-name))))

;; --- Python

(defun my-python-use-project-venv ()
  (let* ((root (locate-dominating-file default-directory ".venv"))
         (venv (and root
                    (expand-file-name ".venv" root)))
         (bin (and venv
                   (expand-file-name "bin" venv)))
         ;; TRAMP:
         ;; /ssh:sone:/home/.../.venv/bin
         ;; 轉成:
         ;; /home/.../.venv/bin
         (process-bin (and bin
                           (file-local-name bin))))
    (when (and bin (file-directory-p bin))
      (setq-local process-environment
                  (copy-sequence process-environment))

      (setenv "PATH"
              (concat process-bin
                      path-separator
                      (getenv "PATH")))

      ;; exec-path 對目前 buffer 也一起調整
      (setq-local exec-path
                  (cons process-bin exec-path)))))

(add-hook 'python-mode-hook #'my-python-use-project-venv)
(add-hook 'python-ts-mode-hook #'my-python-use-project-venv)

;; --- Web: HTML / JS / TS / JSON / CSS

;; Emacs 29 內建的 tree-sitter 查詢只相容舊版 grammar，所以鎖定版本
(setq treesit-language-source-alist
      '((javascript "https://github.com/tree-sitter/tree-sitter-javascript" "v0.20.1" "src")
        (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "v0.20.3" "typescript/src")
        (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "v0.20.3" "tsx/src")
        (json "https://github.com/tree-sitter/tree-sitter-json" "v0.20.2")
        (css "https://github.com/tree-sitter/tree-sitter-css" "v0.20.0")))

;; 第一次啟動時自動編譯缺少的 grammar
(dolist (lang (mapcar #'car treesit-language-source-alist))
  (unless (treesit-language-available-p lang)
    (condition-case err
        (treesit-install-language-grammar lang)
      (error (message "Could not install %s grammar: %s"
                      lang (error-message-string err))))))

(setq major-mode-remap-alist
      (append '((js-mode . js-ts-mode)
                (javascript-mode . js-ts-mode)
                (js-json-mode . json-ts-mode)
                (css-mode . css-ts-mode))
              major-mode-remap-alist))
(add-to-list 'auto-mode-alist '("\\.[cm]?jsx?\\'" . js-ts-mode))
(add-to-list 'auto-mode-alist '("\\.[cm]?ts\\'" . typescript-ts-mode))
(add-to-list 'auto-mode-alist '("\\.tsx\\'" . tsx-ts-mode))
(add-to-list 'auto-mode-alist '("\\.json\\'" . json-ts-mode))

;; 縮排與 prettier 預設一致
(setq js-indent-level 2
      typescript-ts-mode-indent-offset 2
      json-ts-mode-indent-offset 2
      css-indent-offset 2)

(use-package web-mode
  :ensure t
  :mode "\\.html?\\'"
  :custom
  (web-mode-markup-indent-offset 2)
  (web-mode-css-indent-offset 2)
  (web-mode-code-indent-offset 2)
  (web-mode-enable-auto-pairing t)
  (web-mode-enable-auto-closing t)
  (web-mode-enable-current-element-highlight t))

;; LSP：typescript-language-server / vscode-langservers-extracted 由 `scripts/setup lsp web` 安裝
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(web-mode . ("vscode-html-language-server" "--stdio"))))
(dolist (hook '(js-ts-mode-hook
                typescript-ts-mode-hook
                tsx-ts-mode-hook
                json-ts-mode-hook
                css-ts-mode-hook
                web-mode-hook))
  (add-hook hook #'eglot-ensure))

;; --- Rust (rust-analyzer 由 `scripts/setup lsp rust' 安裝)

(use-package rust-mode
  :ensure t
  :hook (rust-mode . eglot-ensure))

;; --- Common Lisp (sbcl 由 `scripts/setup lsp lisp' 安裝)

(use-package sly
  :ensure t
  :defer t
  :custom
  (inferior-lisp-program "sbcl"))

;; 壓縮成一行的檔案：只關掉耗效能的功能，保留原 major mode
(setq so-long-action 'so-long-minor-mode)
(global-so-long-mode 1)

;; 整檔美化：C-c f 用 prettier 排版（prettier 由 `scripts/setup lsp web` 安裝）
;; 不開 format-on-save，避免存檔時意外重排整個壓縮檔
(defun my-format-buffer ()
  "Reformat the whole buffer.
JSON uses the built-in pretty printer so every object is expanded;
other modes use prettier through apheleia."
  (interactive)
  (if (derived-mode-p 'json-ts-mode 'js-json-mode)
      (json-pretty-print-buffer)
    (call-interactively #'apheleia-format-buffer)))

(use-package apheleia
  :ensure t
  :bind ("C-c f" . my-format-buffer)
  :config
  ;; TRAMP 遠端檔案也用本機的 prettier
  (setq apheleia-remote-algorithm 'local)
  (setf (alist-get 'web-mode apheleia-mode-alist) 'prettier-html))

;; --- AI ---
(defun my/agent-subscription-quota ()
  "自動偵測當前 Buffer (支援 TRAMP 遠端與本機)，抓取 Claude 與 Codex 的訂閱額度剩餘比例。"
  (interactive)
  (message "正在查詢訂閱額度剩餘比例 (%s)..."
           (or (file-remote-p default-directory) "localhost"))
  (let ((py-code "
import json, os, urllib.request
from datetime import datetime, timezone

def fmt_reset(ts):
    if not ts: return '-'
    try:
        if isinstance(ts, (int, float)):
            dt = datetime.fromtimestamp(ts, timezone.utc)
        else:
            dt = datetime.fromisoformat(str(ts).replace('Z', '+00:00'))
        diff = int((dt - datetime.now(timezone.utc)).total_seconds())
        if diff <= 0: return '即將重置'
        d, r = divmod(diff, 86400)
        h, r = divmod(r, 3600)
        m, _ = divmod(r, 60)
        return f'{d}d{h}h' if d > 0 else f'{h}h{m}m'
    except Exception:
        return '-'

out = []

# 1. 查詢 Claude Code 訂閱額度
c_path = os.path.expanduser('~/.claude/.credentials.json')
if os.path.exists(c_path):
    try:
        with open(c_path) as f:
            token = json.load(f).get('claudeAiOauth', {}).get('accessToken')
        if token:
            req = urllib.request.Request(
                'https://api.anthropic.com/api/oauth/usage',
                headers={
                    'Authorization': f'Bearer {token}',
                    'anthropic-beta': 'oauth-2025-04-20',
                    'User-Agent': 'claude-code/1.0.0'
                }
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode())
                h5 = data.get('five_hour') or {}
                d7 = data.get('seven_day') or {}
                rem5 = 100 - (h5.get('utilization') or 0)
                rem7 = 100 - (d7.get('utilization') or 0)
                rst5 = fmt_reset(h5.get('resets_at'))
                rst7 = fmt_reset(d7.get('resets_at'))
                out.append(f'[Claude] 5h剩餘: {rem5:.0f}% (重置: {rst5}) | 7d剩餘: {rem7:.0f}% (重置: {rst7})')
    except Exception as e:
        out.append(f'[Claude] 查詢失敗 ({e})')

# 2. 查詢 OpenAI Codex 訂閱額度
x_path = os.path.expanduser('~/.codex/auth.json')
if os.path.exists(x_path):
    try:
        with open(x_path) as f:
            d = json.load(f)
            token = (d.get('tokens') or {}).get('access_token') or d.get('access_token')
        if token:
            req = urllib.request.Request(
                'https://chatgpt.com/backend-api/wham/usage',
                headers={
                    'Authorization': f'Bearer {token}',
                    'Accept': 'application/json',
                    'User-Agent': 'codex-cli'
                }
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode())
                rl = data.get('rate_limit') or {}
                p = rl.get('primary_window') or {}
                s = rl.get('secondary_window') or {}
                rem_p = 100 - (p.get('used_percent') or 0)
                rem_s = 100 - (s.get('used_percent') or 0)
                rst_p = fmt_reset(p.get('reset_at'))
                rst_s = fmt_reset(s.get('reset_at'))
                out.append(f'[Codex] 5h剩餘: {rem_p:.0f}% (重置: {rst_p}) | 7d剩餘: {rem_s:.0f}% (重置: {rst_s})')
    except Exception as e:
        out.append(f'[Codex] 查詢失敗 ({e})')

print('  ||  '.join(out) if out else '找不到 ~/.claude 或 ~/.codex 登入憑證')
"))
    (with-temp-buffer
      (process-file "python3" nil t nil "-c" py-code)
      (message "%s" (string-trim (buffer-string))))))


;; --- ghost ---
(use-package ghostel
  :bind (("C-x m" . ghostel)
         :map ghostel-semi-char-mode-map
         ("C-s"  . consult-line)
         ("C-k"  . my/ghostel-send-C-k-and-kill)
         ;; ;; I'm used to go up/down the shell history with M-n/p from eshell
         ;; ;; Simulate this behavior in ghostel by sending C-p and C-n
         ("M-p" . (lambda () (interactive) (ghostel-send-key "p" "ctrl")))
         ("M-n" . (lambda () (interactive) (ghostel-send-key "n" "ctrl")))
         :map project-prefix-map
         ("m" . ghostel-project)
         ("M" . ghostel-project-list-buffers))
  :config
  (defun my/ghostel-send-C-k-and-kill ()
    "Send `C-k' to ghostel.
Like normal Emacs `C-k'.  Kill to end of line and put content in kill-ring."
    (interactive)
    (kill-ring-save (point) (line-end-position))
    (ghostel-send-key "k" "ctrl"))

  (add-to-list 'project-switch-commands '(ghostel-project "Ghostel") t)
  (add-to-list 'project-switch-commands '(ghostel-project-list-buffers "Ghostel buffers") t)
  (add-to-list 'ghostel-eval-cmds '("magit-status-setup-buffer" magit-status-setup-buffer)))

(use-package ghostel-eshell
  :hook (eshell-load . ghostel-eshell-visual-command-mode))

(use-package ghostel-compile
  :hook (after-init . ghostel-compile-global-mode))

(use-package ghostel-shell-command
  :hook (after-init . ghostel-shell-command-global-mode))

(use-package ghostel-comint
  :hook (after-init . ghostel-comint-global-mode))

(use-package ghostel-org
  :after org)


(use-package vertico
  :ensure t
  :init (vertico-mode))

(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic)))


(with-eval-after-load 'ghostel
  (define-key ghostel-mode-map (kbd "M-o") #'ace-window)
  (define-key ghostel-semi-char-mode-map (kbd "M-o") #'ace-window)
  (define-key ghostel-semi-char-mode-map (kbd "<f7>") #'my-switch-ghostel-buffer))

(defun agent-shell-antigravity-bootstrap (&optional force)
  "Download and install the latest Antigravity ACP server binary."
  (interactive "P")
  (let* ((arch (pcase (car (split-string system-configuration "-"))
                 ((or "x86_64" "amd64") "x86_64")
                 ((or "aarch64" "arm64") "aarch64")
                 (a a)))
         (os (pcase system-type ('darwin "darwin") ('windows-nt "windows") (_ "linux")))
         (platform (format "%s-%s" os arch))
         (install-dir (agent-shell-cache-dir "antigravity" platform))
         (bin-name (file-name-nondirectory (car agent-shell-antigravity-acp-command)))
         (bin-path (expand-file-name bin-name install-dir)))
    (unless (and (not force) (file-executable-p bin-path))
      (message "Antigravity: bootstrapping server for %s..." platform)
      (make-directory install-dir t)
      (let* ((reg-url "https://raw.githubusercontent.com/agentclientprotocol/registry/main/antigravity-acp/agent.json")
             (reg (with-temp-buffer
                    (url-insert-file-contents reg-url)
                    (json-parse-buffer :object-type 'alist)))
             (archive-url (map-nested-elt reg `(distribution binary ,(intern platform) archive)))
             (zip (expand-file-name "server.zip" install-dir)))
        (url-copy-file archive-url zip t)
        (call-process "unzip" nil nil nil "-o" "-q" zip "-d" install-dir)
        (delete-file zip)
        (set-file-modes bin-path #o755)))
    (setq agent-shell-antigravity-acp-command
          (cons bin-path (cdr agent-shell-antigravity-acp-command)))
    (message "Antigravity: using ACP server at %s" bin-path)
    bin-path))
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(ace-window agent-recall agent-shell agent-shell-hq apheleia eat
                exec-path-from-shell ghostel magit orderless php-mode
                posframe vertico web-mode yaml-mode))
 '(package-vc-selected-packages
   '((agent-shell-hq :url
                     "https://github.com/sreenivasvrao/agent-shell-hq"))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
