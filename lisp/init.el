;;; init.el --- 基本 Emacs 設定 -*- lexical-binding: t -*-

;;; Commentary:
;; 套件、環境、外觀 / layout、buffer、dired、ace-window；其餘分到：
;;   my-shell.el        TRAMP、Ghostel
;;   my-lang.el         各語言 mode、LSP、格式化
;;   my-agent-shell.el  agent-shell 與各 agent
;; init.el 是 symlink 指回 repo，其他 lisp/*.el 由 scripts/setup.sh 放到 ~/.emacs.d/lisp

;;; Code:

;; --- 套件

(require 'package)

(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))

(package-initialize)

;; --- 環境

(use-package exec-path-from-shell
  :ensure t
  :config
  (exec-path-from-shell-initialize))

;; 確保 Emacs 本地 exec-path 包含 ~/.local/bin
(let ((local-bin (expand-file-name "~/.local/bin/")))
  (add-to-list 'exec-path local-bin)
  (setenv "PATH" (concat local-bin path-separator (getenv "PATH"))))

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

(defconst my/lyanemacs-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename (or load-file-name buffer-file-name)))))
  "Root of the lyanemacs checkout that init.el is linked from.")

;; `scripts/setup.sh lsp' 把 LSP / prettier 裝在 repo 內 (.venv、node_modules、vendor)
(dolist (dir '("vendor/bin" "node_modules/.bin" ".venv/bin"))
  (let ((bin (expand-file-name dir my/lyanemacs-root)))
    (when (file-directory-p bin)
      (add-to-list 'exec-path bin)
      (setenv "PATH" (concat bin path-separator (getenv "PATH"))))))

;; --- 外觀 / layout

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

(global-display-line-numbers-mode 1)

;; --- buffer

(setq make-backup-files nil)
(setq auto-save-default nil)
(setq create-lockfiles nil)

(setq use-short-answers t)

(setq-default indent-tabs-mode nil)
(setq tab-width 4)

;; --- 視窗

(use-package ace-window
  :ensure t
  ;; bind* 讓 M-o 優先於各 major/minor mode 自己的綁定
  :bind* ("M-o" . ace-window))

;; --- 補全

(use-package vertico
  :ensure t
  :init (vertico-mode))

(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic)))

;; --- dired

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

(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "/")
    (lambda (pattern)
      (interactive "sFind-name (filename wildcard): ")
      (find-name-dired default-directory pattern))))

;; --- git

(use-package magit
  :ensure t)

;; --- 模組

(require 'my-shell)
(require 'my-lang)
(require 'my-agent-shell)

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
