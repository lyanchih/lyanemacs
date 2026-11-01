;;; my-shell.el --- TRAMP 與 Ghostel 終端機 -*- lexical-binding: t -*-

;;; Code:

(require 'subr-x)

;; --- TRAMP

(require 'tramp)
;; 讓 TRAMP 讀取遠端使用者登入 shell 的 PATH (~/.profile, ~/.bashrc 等)
(add-to-list 'tramp-remote-path 'tramp-own-remote-path t)
;; 使用 ~ 動態指向當前遠端使用者的家目錄，並排在最前面優先於 /usr/bin
(add-to-list 'tramp-remote-path "~/.local/node/bin")
(add-to-list 'tramp-remote-path "~/.local/bin")
;; 遠端用預設位置 clone lyanemacs 並跑過 `scripts/setup.sh lsp' 時的 LSP
(dolist (dir '("vendor/bin" "node_modules/.bin" ".venv/bin"))
  (add-to-list 'tramp-remote-path (concat "~/repos/lyanemacs/" dir) t))

;; --- Ghostel

;; ghostel 的 :config 會加到 project-switch-commands
(require 'project)

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

(use-package ghostel
  :ensure t
  ;; 立即載入：my-new-ghostel 用 let 綁定 ghostel-buffer-name，需要它已是動態變數
  :demand t
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

(with-eval-after-load 'ghostel
  (define-key ghostel-mode-map (kbd "M-o") #'ace-window)
  (define-key ghostel-semi-char-mode-map (kbd "M-o") #'ace-window)
  (define-key ghostel-semi-char-mode-map (kbd "<f7>") #'my-switch-ghostel-buffer))

(provide 'my-shell)
;;; my-shell.el ends here
