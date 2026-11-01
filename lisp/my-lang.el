;;; my-lang.el --- 各語言 mode、LSP (eglot) 與格式化 -*- lexical-binding: t -*-

;;; Commentary:
;; LSP server 由 `scripts/setup.sh lsp' 安裝，init.el 已把 repo 內的工具加進 exec-path。

;;; Code:

;; --- LSP: PHP、C/C++、Python 共用 eglot (C/C++ 用 clangd)

(use-package eglot
  :hook ((php-mode
          c-mode
          c++-mode
          c-ts-mode
          c++-ts-mode
          python-mode
          python-ts-mode)
         . eglot-ensure))

;; --- PHP

(use-package php-mode
  :ensure t
  :mode "\\.php\\'")

;; phpactor 舊的全域安裝位置 (composer global require)
(setenv "PATH"
        (concat
         (expand-file-name "~/.config/composer/vendor/bin")
         ":"
         (getenv "PATH")))

(add-to-list 'exec-path
             (expand-file-name "~/.config/composer/vendor/bin"))

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

;; LSP：typescript-language-server / vscode-langservers-extracted 由 `scripts/setup.sh lsp web` 安裝
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

;; --- Rust (rust-analyzer 由 `scripts/setup.sh lsp rust' 安裝)

(use-package rust-mode
  :ensure t
  :hook (rust-mode . eglot-ensure))

;; --- Common Lisp (sbcl 由 `scripts/setup.sh lsp lisp' 安裝)

(use-package sly
  :ensure t
  :defer t
  :custom
  (inferior-lisp-program "sbcl"))

;; --- YAML

(use-package yaml-mode
  :ensure t
  :mode ("\\.ya?ml\\'" . yaml-mode))

;; 壓縮成一行的檔案：只關掉耗效能的功能，保留原 major mode
(setq so-long-action 'so-long-minor-mode)
(global-so-long-mode 1)

;; 整檔美化：C-c f 用 prettier 排版（prettier 由 `scripts/setup.sh lsp web` 安裝）
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

(provide 'my-lang)
;;; my-lang.el ends here
