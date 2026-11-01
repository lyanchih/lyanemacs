;;; my-agent-shell.el --- agent-shell 與各 agent 設定 -*- lexical-binding: t -*-

;;; Commentary:
;; 上半部：agent-shell 擴充 (按鍵、session、TRAMP、HQ、recall、transcript)
;; 下半部：各 agent 所需實做 (Claude、Codex、Cursor、Antigravity、OpenCode)

;;; Code:

;;;; ================================================================
;;;; 上半部：agent-shell 擴充
;;;; ================================================================

(defvar my/agent-shell-map (make-sparse-keymap)
  "Keymap for agent-shell commands.")

(keymap-global-set "C-c a" my/agent-shell-map)

(defun my-new-agent-shell ()
  "Create a new agent shell buffer, always starting an additional session.
Unlike `agent-shell' which reuses the existing shell buffer for the
current project, this always creates a new shell."
  (interactive)
  (require 'agent-shell)
  (agent-shell '(4)))

(use-package agent-shell
  :ensure t
  :config
  (setopt agent-shell-show-cost-indicator t)

  (define-key my/agent-shell-map (kbd "a")
              #'agent-shell-switch-buffer)
  (define-key my/agent-shell-map (kbd "s")
              #'my-new-agent-shell))

(setq agent-shell-session-strategy 'prompt)
(setq agent-shell-session-restore-verbosity 'full)

;; --- TRAMP 與 fork 相容 (lisp/agent-shell-tramp.el、lisp/agent-shell-fork-compat.el)

(require 'agent-shell-tramp)

(agent-shell-tramp-mode 1)

(require 'agent-shell-fork-compat)
(agent-shell-fork-compat-mode 1)

;; --- HQ 側欄與已關閉 session 瀏覽

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

;; --- transcript

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

;;;; ================================================================
;;;; 下半部：agent 所需實做
;;;; ================================================================

;; --- Claude

(with-eval-after-load 'agent-shell
  ;; 先確認變數名稱並覆寫啟動指令，讓遠端 sh 自動展開 $HOME（適用所有帳號）
  (setq agent-shell-anthropic-claude-acp-command
        '("sh" "-c" "export PATH=\"$HOME/.local/node/bin:$PATH\"; exec claude-agent-acp")))

;; --- Codex

(with-eval-after-load 'agent-shell
  (setq agent-shell-openai-authentication
        (agent-shell-openai-make-authentication :login t)))

;; --- Cursor

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

;; --- Antigravity

(with-eval-after-load 'agent-shell
  (setq agent-shell-antigravity-authentication
        (agent-shell-antigravity-make-authentication :login t)))

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

;; --- OpenCode

;; init.el 已先跑 exec-path-from-shell，這裡加的不會被覆寫
(let ((opencode-bin (expand-file-name "~/.opencode/bin/")))
  (add-to-list 'exec-path opencode-bin)
  (setenv "PATH" (concat opencode-bin path-separator (getenv "PATH"))))

;; Search OpenCode's default install directory on TRAMP hosts.
(with-eval-after-load 'tramp
  (add-to-list 'tramp-remote-path "~/.opencode/bin"))

(with-eval-after-load 'agent-shell-opencode
  ;; 明確指定 opencode 的絕對路徑與子參數 "acp"
  ;; 用 ~ 可以完美適應不同的遠端使用者 (accton, lyan 等)
  (setq agent-shell-opencode-acp-command '("opencode" "acp")))

(provide 'my-agent-shell)
;;; my-agent-shell.el ends here
