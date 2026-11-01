;;; agent-shell-hq-recall.el --- HQ-like browser for closed agent sessions -*- lexical-binding: t; -*-
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (agent-shell-hq "0") (agent-recall "0"))
;; This is an independent extension; it does not patch HQ source files.

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'agent-shell-hq)
(require 'agent-recall)

(defgroup agent-shell-hq-recall nil
  "Browse closed agent-shell sessions with a two-pane interface."
  :group 'agent-shell)

(defcustom agent-shell-hq-recall-sidebar-width 48
  "Width of the session list in columns."
  :type 'integer :group 'agent-shell-hq-recall)

(defconst agent-shell-hq-recall--list-buffer "*HQ Recall Sessions*")
(defconst agent-shell-hq-recall--preview-buffer "*HQ Recall Preview*")
(defvar-local agent-shell-hq-recall--scope 'index)
(defvar-local agent-shell-hq-recall--root nil)
(defvar-local agent-shell-hq-recall--items nil)
(defvar-local agent-shell-hq-recall--positions nil)
(defvar-local agent-shell-hq-recall--selected 0)
(defvar-local agent-shell-hq-recall--saved-windows nil)
(defvar-local agent-shell-hq-recall--preview-window nil)

(defun agent-shell-hq-recall--project-root ()
  "Use HQ highlighted project when available, otherwise current project."
  (or (and (boundp 'agent-shell-hq-toggle--entries)
           (boundp 'agent-shell-hq-toggle--current-idx)
           (string= (buffer-name) " *agent-shell-hq-sidebar*")
           (plist-get (nth agent-shell-hq-toggle--current-idx
                           agent-shell-hq-toggle--entries) :root))
      (when-let* ((pr (project-current nil))) (project-root pr))
      default-directory))

(defun agent-shell-hq-recall--yaml-field (file field)
  "Read scalar FIELD from FILE's initial, bounded YAML front matter."
  (let (yaml)
    (with-temp-buffer
      (insert-file-contents file nil 0 65536)
      (goto-char (point-min))
      (when (looking-at "---[ \t]*\r?\n")
        (forward-line 1)
        (let ((start (point)))
          (when (re-search-forward "^---[ \t]*\r?$" nil t)
            (let ((end (line-beginning-position)))
              (goto-char start)
              (when (re-search-forward
                     (concat "^" (regexp-quote field) ":[ \t]*\\(.*?\\)[ \t]*\r?$") end t)
                (setq yaml (string-trim (match-string-no-properties 1)))
                (when (and (> (length yaml) 1)
                           (memq (aref yaml 0) '(?\" ?\'))
                           (= (aref yaml 0) (aref yaml (1- (length yaml)))))
                  (setq yaml (substring yaml 1 -1)))
                (when (string-empty-p yaml) (setq yaml nil))))))))
    yaml))

(defun agent-shell-hq-recall--read-session-id (file)
  "Read FILE's explicit YAML or legacy session ID; refuse conflicts."
  (let ((legacy (agent-recall--read-embedded-session-id file))
        (yaml (agent-shell-hq-recall--yaml-field file "session_id")))
    (when (and legacy yaml (not (equal (downcase legacy) (downcase yaml))))
      (user-error "YAML and legacy transcript Session IDs conflict; nothing deleted"))
    (or yaml legacy)))

(defun agent-shell-hq-recall--provider (file entry)
  "Identify FILE's agent before falling back to Recall's cached provider."
  (let ((agent (or (agent-shell-hq-recall--yaml-field file "agent")
                   (agent-recall--read-agent-name file)
                   (plist-get entry :agent))))
    (if (and agent (string-match-p "antigravity" (downcase agent)))
        'antigravity
      (or (agent-recall--provider-for-name agent)
          (agent-recall--entry-provider file entry)))))

(defun agent-shell-hq-recall--native-providers (provider)
  "Return native deletion providers for PROVIDER, refusing unsupported agents."
  (cond ((memq provider '(openai anthropic)) (list provider))
        ((null provider) '(openai anthropic))
        (t (user-error
            "Native deletion is not supported for %s; use d to delete Recall transcript only (provider history is kept)"
            provider))))

(defun agent-shell-hq-recall--make-item (file &optional entry)
  "Build one displayed ITEM from transcript FILE and index ENTRY."
  (let* ((entry (or entry (gethash file agent-recall--index)))
         (sid (or (agent-shell-hq-recall--read-session-id file)
                  (plist-get entry :session-id)
                  (agent-recall--resolve-session-id file)))
         (root (agent-recall--project-root-for-session file))
         (project (or (plist-get entry :project)
                      (and root (file-name-nondirectory (directory-file-name root)))
                      "Unknown")))
    (unless (and sid (agent-recall--find-session-buffer sid))
      (list :file file :id sid :root root :project project
            :provider (agent-shell-hq-recall--provider file entry)
            :title (or (plist-get entry :title)
                       (agent-recall--read-session-title file)
                       (plist-get entry :preview)
                       (agent-recall--transcript-preview file)
                       (file-name-nondirectory file))
            :time (file-attribute-modification-time (file-attributes file))))))

(defun agent-shell-hq-recall--collect (scope root)
  "Collect closed sessions for SCOPE (`index' or `here') and ROOT."
  (agent-recall--index-ensure)
  (let (items)
    (pcase scope
      ('index
       (maphash (lambda (file entry)
                  (when (and (file-regular-p file) (not (file-symlink-p file)))
                    (when-let* ((item (agent-shell-hq-recall--make-item file entry)))
                      (push item items))))
                agent-recall--index))
      ('here
       (let ((dir (expand-file-name agent-recall-transcript-dir-name root)))
         (when (file-directory-p dir)
           (dolist (file (agent-recall--list-transcript-files dir))
             (when (and (file-regular-p file) (not (file-symlink-p file)))
               (when-let* ((item (agent-shell-hq-recall--make-item file)))
                 (push item items)))))))
      (_ (error "Unknown scope: %S" scope)))
    (sort items
          (lambda (a b)
            (let ((pa (plist-get a :project)) (pb (plist-get b :project)))
              (if (equal pa pb)
                  (time-less-p (plist-get b :time) (plist-get a :time))
                (string-lessp pa pb)))))))

(defun agent-shell-hq-recall--selected-item ()
  "Return selected record."
  (nth agent-shell-hq-recall--selected agent-shell-hq-recall--items))

(defun agent-shell-hq-recall--preview ()
  "Preview selected transcript without visiting/altering the file buffer."
  (let ((item (agent-shell-hq-recall--selected-item))
        (preview (get-buffer-create agent-shell-hq-recall--preview-buffer)))
    (with-current-buffer preview
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (and item (file-readable-p (plist-get item :file)))
            (progn
              (insert-file-contents (plist-get item :file))
              (goto-char (point-min)))
          (insert "No session selected.\n"))
        (special-mode)))
    (when (window-live-p agent-shell-hq-recall--preview-window)
      (set-window-buffer agent-shell-hq-recall--preview-window preview)
      (set-window-point agent-shell-hq-recall--preview-window 1))))

(defun agent-shell-hq-recall--render (&optional keep-file fallback-index)
  "Render sidebar, preserving KEEP-FILE or selecting FALLBACK-INDEX.
Clamp FALLBACK-INDEX to the remaining items after deletion."
  (let ((inhibit-read-only t)
        (last-project nil)
        (selected-index (or fallback-index 0))
        (index 0))
    (setq agent-shell-hq-recall--items
          (agent-shell-hq-recall--collect agent-shell-hq-recall--scope
                                          agent-shell-hq-recall--root)
          agent-shell-hq-recall--positions nil)
    (erase-buffer)
    (insert (format "HQ Recall — %s\n" (if (eq agent-shell-hq-recall--scope 'index)
                                           "Indexed history" "Current project")))
    (when (eq agent-shell-hq-recall--scope 'here)
      (insert (format "%s\n" agent-shell-hq-recall--root)))
    (insert "j/k move  RET resume  o open  d Recall-only  D Delete session (provider-dependent)\n")
    (insert "i index  p project  v identity  L link  g refresh  q back\n\n")
    (dolist (item agent-shell-hq-recall--items)
      (let ((project (plist-get item :project)))
        (unless (equal project last-project)
          (setq last-project project)
          (insert (propertize (format "▼ %s\n" project) 'face 'font-lock-keyword-face)))
        (let* ((title (replace-regexp-in-string
                       "[\n\r\t]+" " " (format "%s" (plist-get item :title))))
               (provider (or (plist-get item :provider) "unknown"))
               (date (format-time-string "%m-%d" (plist-get item :time))))
          (push (copy-marker (point)) agent-shell-hq-recall--positions)
          (insert (format "  %-5s %-7s %s\n"
                          date provider (truncate-string-to-width title 37 nil nil "…")))))
      (when (equal (plist-get item :file) keep-file)
        (setq selected-index index))
      (setq index (1+ index)))
    (unless agent-shell-hq-recall--items
      (insert "No closed transcripts found.\n"))
    (setq agent-shell-hq-recall--positions (nreverse agent-shell-hq-recall--positions)
          agent-shell-hq-recall--selected
          (max 0 (min selected-index (1- (length agent-shell-hq-recall--items)))))
    (agent-shell-hq-recall--highlight)))

(defun agent-shell-hq-recall--highlight ()
  "Move point to selected row and preview it."
  (when-let* ((marker (nth agent-shell-hq-recall--selected
                         agent-shell-hq-recall--positions)))
    (goto-char marker)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (set-window-point window marker)))
  (agent-shell-hq-recall--preview))

(defun agent-shell-hq-recall-next ()
  "Select next session."
  (interactive)
  (when agent-shell-hq-recall--items
    (setq agent-shell-hq-recall--selected
          (min (1- (length agent-shell-hq-recall--items))
               (1+ agent-shell-hq-recall--selected)))
    (agent-shell-hq-recall--highlight)))

(defun agent-shell-hq-recall-previous ()
  "Select previous session."
  (interactive)
  (setq agent-shell-hq-recall--selected
        (max 0 (1- agent-shell-hq-recall--selected)))
  (agent-shell-hq-recall--highlight))

(defun agent-shell-hq-recall-refresh ()
  "Rebuild the list without rebuilding the persistent index."
  (interactive)
  (agent-shell-hq-recall--render
   (plist-get (agent-shell-hq-recall--selected-item) :file)))

(defun agent-shell-hq-recall-switch-index ()
  "Switch browser to indexed transcripts."
  (interactive)
  (setq agent-shell-hq-recall--scope 'index)
  (agent-shell-hq-recall--render))

(defun agent-shell-hq-recall-switch-project ()
  "Switch browser to selected transcript's project, or the original project."
  (interactive)
  (when-let* ((root (plist-get (agent-shell-hq-recall--selected-item) :root)))
    (setq agent-shell-hq-recall--root root))
  (setq agent-shell-hq-recall--scope 'here)
  (agent-shell-hq-recall--render))

(defun agent-shell-hq-recall-quit ()
  "Restore the previous window configuration."
  (interactive)
  (when (window-configuration-p agent-shell-hq-recall--saved-windows)
    (set-window-configuration agent-shell-hq-recall--saved-windows)))

(defun agent-shell-hq-recall-open ()
  "Open selected transcript normally, without resuming the agent."
  (interactive)
  (unless (agent-shell-hq-recall--selected-item)
    (user-error "No transcript selected"))
  (let ((file (plist-get (agent-shell-hq-recall--selected-item) :file)))
    (agent-shell-hq-recall-quit)
    (find-file file)
    (agent-recall-transcript-mode 1)))

(defun agent-shell-hq-recall-resume ()
  "Resume the selected closed session using agent-recall."
  (interactive)
  (let* ((item (or (agent-shell-hq-recall--selected-item)
                   (user-error "No transcript selected")))
         (id (plist-get item :id)))
    (unless id (user-error "This transcript has no Session ID"))
    (agent-shell-hq-recall-quit)
    (agent-recall--start-resume id (plist-get item :file))))

(defun agent-shell-hq-recall--remove-recall (file id)
  "Remove FILE and sidecar summaries; update Recall index and metadata for ID."
  (let ((base (file-name-sans-extension file)))
    (when-let* ((buf (get-file-buffer file)))
      (when (buffer-modified-p buf)
        (user-error "Transcript buffer is modified; save or discard first"))
      (kill-buffer buf))
    (when (file-exists-p file) (delete-file file))
    (dolist (extension '(".summary.md" ".summary.org"))
      (let ((summary (concat base extension)))
        (when (and (file-regular-p summary) (not (file-symlink-p summary)))
          (delete-file summary))))
    (agent-recall--index-ensure)
    (remhash file agent-recall--index)
    (when (file-exists-p agent-recall-index-file)
      (agent-recall--index-save))
    (when id
      (when (hash-table-p agent-recall--session-id-cache)
        (remhash file agent-recall--session-id-cache))
      (agent-recall--metadata-ensure)
      (unless (cl-loop for record being the hash-values of agent-recall--index
                       thereis (equal id (plist-get record :session-id)))
        (remhash id agent-recall--metadata)
        (agent-recall--metadata-save)))))

(defun agent-shell-hq-recall--confirm (item description)
  "Ask exactly one y/n question about deleting ITEM as DESCRIPTION."
  (unless (y-or-n-p
           (format "%s: %s? " description
                   (truncate-string-to-width
                    (format "%s" (plist-get item :title)) 42 nil nil "…")))
    (user-error "Deletion cancelled")))

(defun agent-shell-hq-recall--check-closed (item &optional resolved-id)
  "Refuse deletion if ITEM's transcript or RESOLVED-ID is open in Emacs."
  (let ((file (plist-get item :file))
        (id (or resolved-id (plist-get item :id))))
    (when (and id (agent-recall--find-session-buffer id))
      (user-error "Session is open in Emacs; close it in HQ first"))
    (when (fboundp 'agent-shell-buffers)
      (dolist (buffer (agent-shell-buffers))
        (when (and (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (and (boundp 'agent-shell--transcript-file)
                          agent-shell--transcript-file
                          (equal (expand-file-name agent-shell--transcript-file)
                                 (expand-file-name file)))))
          (user-error "Transcript is open in an agent-shell buffer"))))))

(defun agent-shell-hq-recall-delete-transcript ()
  "After a single y/n confirmation, remove Recall transcript and metadata."
  (interactive)
  (let ((item (or (agent-shell-hq-recall--selected-item)
                  (user-error "No transcript selected"))))
    (agent-shell-hq-recall--check-closed item)
    (agent-shell-hq-recall--confirm item "Delete Recall transcript/index (keep provider history)")
    (agent-shell-hq-recall--remove-recall (plist-get item :file) (plist-get item :id))
    (agent-shell-hq-recall--render nil agent-shell-hq-recall--selected)
    (message "Recall transcript removed; provider session history is kept")))

(defun agent-shell-hq-recall--uuid-p (id)
  "Return non-nil if ID is a UUID (required for provider-native deletion)."
  (and (stringp id)
       (string-match-p
        "\\`[[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}\\'"
        id)))

(defun agent-shell-hq-recall--remove-path (path)
  "Remove PATH if it is an actual directory or file, never follow symlinks."
  (when (file-symlink-p path)
    (error "Refusing to delete symlink %s" path))
  (cond ((file-directory-p path) (delete-directory path t))
        ((file-regular-p path) (delete-file path))))

(defun agent-shell-hq-recall--strip-history (file id)
  "Atomically drop only JSONL history lines matching session ID."
  (when (file-regular-p file)
    (when (file-symlink-p file) (error "Refusing symlink history: %s" file))
    (let* ((old-mode (file-modes file))
           (temp (make-temp-file (concat file ".hq-")))
           (removed 0))
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (while (not (eobp))
                (let* ((start (line-beginning-position))
                       (end (line-end-position))
                       (line (buffer-substring-no-properties start end))
                       (record (ignore-errors (json-parse-string line :object-type 'hash-table))))
                  (if (and (hash-table-p record)
                           (equal id (or (gethash "sessionId" record)
                                         (gethash "session_id" record))))
                      (progn
                        (delete-region start (min (point-max) (1+ end)))
                        (cl-incf removed))
                    (forward-line 1))))
              (write-region (point-min) (point-max) temp nil 'silent))
            (set-file-modes temp old-mode)
            (rename-file temp file t)
            removed)
        (when (file-exists-p temp) (delete-file temp))))))

(defconst agent-shell-hq-recall--delete-error-buffer "*HQ Recall Delete Error*")

(defun agent-shell-hq-recall--delete-codex (id)
  "Ask Codex CLI to delete ID; retain detailed diagnostics on failure.
Do not remove Recall records or scrub history unless the CLI succeeds."
  (let ((program (or (executable-find "codex")
                     (user-error "codex executable not found; nothing deleted")))
        (home (expand-file-name (or (getenv "CODEX_HOME") "~/.codex")))
        (directory default-directory)
        (process-environment (copy-sequence process-environment)))
    (setenv "RUST_BACKTRACE" "1")
    (with-temp-buffer
      (let ((exit (call-process program nil t nil "delete" id "--force")))
        (unless (and (integerp exit) (= exit 0))
          (let ((output (buffer-string))
                (version (with-temp-buffer
                           (call-process program nil t nil "--version")
                           (string-trim (buffer-string)))))
            (with-current-buffer
                (get-buffer-create agent-shell-hq-recall--delete-error-buffer)
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (format
                         "Codex deletion failed; Recall record kept.\n\nExecutable: %s\nVersion: %s\nCODEX_HOME: %s\nWorking directory: %s\nSession ID: %s\nExit: %s\n\n%s"
                         program version home directory id exit output))
                (goto-char (point-min))
                (special-mode)))
            (display-buffer agent-shell-hq-recall--delete-error-buffer)
            (error "codex delete failed (%s); Recall kept. See %s: %s"
                   exit agent-shell-hq-recall--delete-error-buffer
                   (string-trim output))))))
    (agent-shell-hq-recall--strip-history
     (expand-file-name "history.jsonl" home) id)))

(defun agent-shell-hq-recall--native-text (value)
  "Extract text from a native JSONL content VALUE."
  (cond
   ((stringp value) value)
   ((listp value)
    (cl-loop for entry in value
             when (and (hash-table-p entry)
                       (equal (gethash "type" entry) "text")
                       (stringp (gethash "text" entry)))
             return (gethash "text" entry)))))

(defun agent-shell-hq-recall--inspect-native (file provider)
  "Read native FILE's early session ID, working directory and first user text.
Read a bounded prefix, never execute contents."
  (when (and (file-regular-p file) (not (file-symlink-p file)))
    (let ((native-id nil) (cwd nil) (first nil))
      (with-temp-buffer
        (insert-file-contents file nil 0
                              (min 1048576 (file-attribute-size (file-attributes file))))
        (goto-char (point-min))
        (while (and (not first) (not (eobp)))
          (let* ((line (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
                 (record (ignore-errors
                           (json-parse-string line :object-type 'hash-table
                                              :array-type 'list)))
                 (kind (and (hash-table-p record) (gethash "type" record)))
                 (payload (and (hash-table-p record) (gethash "payload" record))))
            (pcase provider
              ('openai
               (cond
                ((and (equal kind "session_meta") (hash-table-p payload))
                 (setq native-id (or (gethash "id" payload)
                                     (gethash "session_id" payload))
                       cwd (gethash "cwd" payload)))
                ((and (equal kind "event_msg") (hash-table-p payload)
                      (equal (gethash "type" payload) "user_message"))
                 (let ((text (gethash "message" payload)))
                   (when (and (stringp text) (not (string-prefix-p "<" text)))
                     (setq first text))))))
              ('anthropic
               (when (equal kind "user")
                 (let* ((msg (gethash "message" record))
                        (content (and (hash-table-p msg) (gethash "content" msg)))
                        (text (agent-shell-hq-recall--native-text content)))
                   (when (and text (not (string-prefix-p "<" text)))
                     (setq first text))))))
            (forward-line 1))))
      (list :id (if (eq provider 'anthropic)
                    (file-name-sans-extension (file-name-nondirectory file))
                  native-id)
            :cwd cwd :first first))))

(defun agent-shell-hq-recall--same-project-p (root cwd)
  "Check whether CWD is ROOT or a subdirectory of ROOT."
  (and (stringp root) (stringp cwd)
       (file-directory-p root) (file-directory-p cwd)
       (let ((r (file-truename root)) (c (file-truename cwd)))
         (or (equal (directory-file-name r) (directory-file-name c))
             (file-in-directory-p c r)))))

(defun agent-shell-hq-recall--native-files (provider root)
  "Find candidate provider files, limited to the project for Claude."
  (pcase provider
    ('anthropic
     (let ((dir (agent-recall--claude-project-dir root)))
       (when (and dir (not (file-symlink-p dir)))
         (directory-files dir t
                          "\\`[[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}\\.jsonl\\'"))))
    ('openai
     (let* ((home (expand-file-name (or (getenv "CODEX_HOME") "~/.codex")))
            (dirs (list (expand-file-name "sessions" home)
                        (expand-file-name "archived_sessions" home))))
       (cl-loop for dir in dirs
                when (and (file-directory-p dir) (not (file-symlink-p dir)))
                append (directory-files-recursively
                        dir "rollout-.*\\.jsonl\\'" nil nil nil))))))

(defun agent-shell-hq-recall--candidate-id (item)
  "Return verified transcript ID, or reject conflicting recorded IDs.
An embedded transcript header is preferred to Recall's indexed/resolved ID.
Do not derive a deletion identity from matching prompts or timestamps."
  (let* ((file (plist-get item :file))
         (embedded (agent-shell-hq-recall--read-session-id file))
         (indexed (plist-get (gethash file agent-recall--index) :session-id))
         (resolved (plist-get item :id)))
    (when (and embedded (not (agent-shell-hq-recall--uuid-p embedded)))
      (user-error "Transcript has a non-UUID Session ID; native deletion unsupported"))
    (when (and embedded (agent-shell-hq-recall--uuid-p indexed)
               (not (equal (downcase embedded) (downcase indexed))))
      (user-error "Transcript and Recall index have conflicting Session IDs; nothing deleted"))
    (when (and embedded (agent-shell-hq-recall--uuid-p resolved)
               (not (equal (downcase embedded) (downcase resolved))))
      (user-error "Transcript and resolved Session IDs conflict; nothing deleted"))
    (when (and (agent-shell-hq-recall--uuid-p indexed)
               (agent-shell-hq-recall--uuid-p resolved)
               (not (equal (downcase indexed) (downcase resolved))))
      (user-error "Recall index and resolved Session IDs conflict; nothing deleted"))
    (let ((id (or embedded indexed resolved)))
      (unless (agent-shell-hq-recall--uuid-p id)
        (user-error (concat "No trustworthy native Session ID; nothing deleted. "
                            "Use M-x agent-recall-backfill then retry")))
      (downcase id))))

(defun agent-shell-hq-recall--verified-target (item)
  "Locate exactly one native session by an ID recorded by Recall.
Check its provider, native metadata, and project.  Never delete by the
first prompt: forked and resumed sessions often share that prompt."
  (agent-recall--index-ensure)
  (let* ((id (agent-shell-hq-recall--candidate-id item))
         (provider (plist-get item :provider))
         (providers (agent-shell-hq-recall--native-providers provider))
         (root (plist-get item :root))
         (matches nil))
    (unless (and (stringp root) (file-directory-p root))
      (user-error "Project directory unavailable; native deletion refused"))
    (dolist (type providers)
      (dolist (native (agent-shell-hq-recall--native-files type root))
        ;; The filename must first identify the exact requested ID.
        ;; This avoids reading unrelated JSONL files during verification.
        (when (and (not (file-symlink-p native))
                   (if (eq type 'anthropic)
                       (equal (downcase (file-name-base native)) id)
                     (string-suffix-p (concat id ".jsonl")
                                      (downcase native))))
          (let* ((info (agent-shell-hq-recall--inspect-native native type))
                 (native-id (plist-get info :id))
                 (cwd (plist-get info :cwd)))
            (when (and (agent-shell-hq-recall--uuid-p native-id)
                       (equal (downcase native-id) id)
                       ;; Codex has explicit cwd in session_meta.  Claude's
                       ;; directory name encodes the project path.
                       (if (eq type 'openai)
                           (agent-shell-hq-recall--same-project-p root cwd)
                         (equal (file-truename (file-name-directory native))
                                (file-truename
                                 (file-name-as-directory
                                  (agent-recall--claude-project-dir root))))))
              (push (list :id id :native native :provider type) matches))))))
    (pcase (length matches)
      (0 (user-error
          (concat "No native session matches ID %s in this project; "
                  "nothing deleted. Check CODEX_HOME/CLAUDE_CONFIG_DIR or session origin") id))
      (1 (car matches))
      (_ (user-error "Several native files match ID %s; deletion refused" id)))))

(defun agent-shell-hq-recall-inspect-identity ()
  "Display the stored ID, provider and project of the selected transcript.
This command never modifies any files."
  (interactive)
  (let* ((item (or (agent-shell-hq-recall--selected-item)
                   (user-error "No transcript selected")))
         (file (plist-get item :file))
         (record (and (hash-table-p agent-recall--index)
                      (gethash file agent-recall--index))))
    (message "Provider: %s | header ID: %s | index ID: %s | resolved ID: %s | root: %s"
             (or (plist-get item :provider) "unknown")
             (or (agent-shell-hq-recall--read-session-id file) "none")
             (or (plist-get record :session-id) "none")
             (or (plist-get item :id) "none")
             (or (plist-get item :root) "none"))))

(defun agent-shell-hq-recall-link-session ()
  "Link a legacy transcript to an explicitly chosen native session ID.
For transcripts missing an ID, select a native Claude/Codex session in the
same project.  This step does NOT delete files or call any AI model."
  (interactive)
  (let* ((item (or (agent-shell-hq-recall--selected-item)
                   (user-error "No transcript selected")))
         (file (plist-get item :file))
         (root (plist-get item :root))
         (provider (plist-get item :provider))
         (providers (agent-shell-hq-recall--native-providers provider))
         (options nil))
    (agent-shell-hq-recall--check-closed item)
    (agent-recall--index-ensure)
    (when (or (agent-shell-hq-recall--read-session-id file)
              (agent-shell-hq-recall--uuid-p
               (plist-get (gethash file agent-recall--index) :session-id)))
      (user-error "Transcript already has a Session ID; refusing to overwrite"))
    (unless (and root (file-directory-p root))
      (user-error "Project directory unavailable"))
    (dolist (type providers)
      (dolist (native (agent-shell-hq-recall--native-files type root))
        (unless (file-symlink-p native)
          (let* ((info (agent-shell-hq-recall--inspect-native native type))
                 (id (plist-get info :id))
                 (cwd (plist-get info :cwd)))
            (when (and (agent-shell-hq-recall--uuid-p id)
                       (if (eq type 'openai)
                           (and (string-suffix-p (concat (downcase id) ".jsonl")
                                                 (downcase native))
                                (agent-shell-hq-recall--same-project-p root cwd))
                         (and (equal (downcase (file-name-base native))
                                     (downcase id))
                              (equal (file-truename (file-name-directory native))
                                     (file-truename
                                      (file-name-as-directory
                                       (agent-recall--claude-project-dir root)))))))
              (let* ((date (format-time-string
                            "%F %R" (file-attribute-modification-time
                                      (file-attributes native))))
                     (label (format "%s  %s  %s" date type id)))
                (push (cons label (list :id (downcase id) :provider type))
                      options)))))))
    (unless options
      (user-error "No native Claude/Codex sessions found for project"))
    (let* ((choice (completing-read "Link native session: " options nil t))
           (target (cdr (assoc choice options)))
           (id (plist-get target :id))
           (candidate (plist-put (copy-sequence item) :id id)))
      ;; Check the exact ID and project BEFORE modifying the transcript.
      (let ((matched (agent-shell-hq-recall--verified-target candidate)))
        (unless (eq (plist-get matched :provider) (plist-get target :provider))
          (user-error "Provider mismatch; link refused")))
      (unless (y-or-n-p (format "Link this transcript to %s %s? "
                                (plist-get target :provider) id))
        (user-error "Link cancelled"))
      (when-let* ((buf (get-file-buffer file)))
        (when (buffer-modified-p buf)
          (user-error "Transcript buffer modified; save or discard it first")))
      (agent-recall--write-session-id-to-file file id)
      (agent-recall--index-add file id)
      (agent-shell-hq-recall--render file)
      (message "Linked transcript to %s; D can now verify the native session"))))

(defun agent-shell-hq-recall--delete-claude (id native)
  "Delete exactly the verified Claude NATIVE session and known sidecars."
  (unless (and (file-regular-p native)
               (not (file-symlink-p native))
               (equal (downcase (file-name-base native)) id))
    (error "Invalid Claude session path; no files deleted"))
  (let ((home (expand-file-name agent-recall-claude-config-dir)))
    (agent-shell-hq-recall--remove-path native)
    (agent-shell-hq-recall--remove-path (concat native ".meta"))
    (agent-shell-hq-recall--remove-path
     (expand-file-name id (file-name-directory native)))
    (dolist (subdir '("file-history" "tasks" "session-env"))
      (agent-shell-hq-recall--remove-path
       (expand-file-name (concat subdir "/" id) home)))
    (agent-shell-hq-recall--strip-history
     (expand-file-name "history.jsonl" home) id)))

(defun agent-shell-hq-recall--session-transcripts (item id provider)
  "Find Recall transcripts explicitly linked to ID and PROVIDER.
Include the index and adjacent transcripts, even when they are not indexed.
Preflight every matching file before deleting the native session."
  (agent-recall--index-ensure)
  (let* ((selected (plist-get item :file))
         (files (delete-dups
                 (append (list selected)
                         (hash-table-keys agent-recall--index)
                         (agent-recall--list-transcript-files
                          (file-name-directory selected)))))
         matches)
    (dolist (file files)
      (when (and (file-regular-p file) (not (file-symlink-p file)))
        (let* ((entry (gethash file agent-recall--index))
               (embedded (agent-shell-hq-recall--read-session-id file))
               (indexed (plist-get entry :session-id))
               (type (agent-shell-hq-recall--provider file entry)))
          (when (and (or (null type) (eq type provider))
                     (cl-some (lambda (value)
                                (and (stringp value) (equal (downcase value) id)))
                              (list embedded indexed)))
            ;; Conflicting explicit/indexed identities must stop the whole operation.
            (agent-shell-hq-recall--candidate-id
             (list :file file :id (or embedded indexed)))
            (agent-shell-hq-recall--check-closed (list :file file :id id) id)
            (when-let* ((buffer (get-file-buffer file)))
              (when (buffer-modified-p buffer)
                (user-error "Transcript buffer is modified: %s" file)))
            (push file matches)))))
    (unless (member selected matches)
      (user-error "Selected transcript identity changed; refresh before deleting"))
    (nreverse matches)))

(defun agent-shell-hq-recall-delete-local-session ()
  "Delete the selected session after one explicit confirmation.
For providers without native deletion support, offer Recall-only deletion.
Never use the first message or timestamp as proof of identity."
  (interactive)
  (let* ((item (or (agent-shell-hq-recall--selected-item)
                   (user-error "No transcript selected")))
         (provider (plist-get item :provider)))
    (agent-shell-hq-recall--check-closed item)
    (if (and provider (not (memq provider '(openai anthropic))))
        (progn
          (agent-shell-hq-recall--confirm
           item (format "Delete Recall transcript/index only (%s native history will be kept)"
                        provider))
          (agent-shell-hq-recall--remove-recall
           (plist-get item :file) (plist-get item :id))
          (agent-shell-hq-recall--render nil agent-shell-hq-recall--selected)
          (message "Recall transcript removed; %s native history is kept" provider))
      (let* ((target (agent-shell-hq-recall--verified-target item))
           (id (plist-get target :id))
           (native (plist-get target :native))
           (files (agent-shell-hq-recall--session-transcripts
                   item id (plist-get target :provider))))
      (setq provider (plist-get target :provider))
      (agent-shell-hq-recall--check-closed item id)
      (agent-shell-hq-recall--confirm
       item (format "PERMANENTLY DELETE local %s session %s + %d Recall transcripts"
                    provider id (length files)))
      ;; Provider FIRST; if it fails, preserve the Recall record.
      (pcase provider
        ('openai (agent-shell-hq-recall--delete-codex id))
        ('anthropic (agent-shell-hq-recall--delete-claude id native)))
      (dolist (file files)
        (agent-shell-hq-recall--remove-recall file id))
      (agent-shell-hq-recall--render nil agent-shell-hq-recall--selected)
      (message "Deleted known local history; cloud, backups and forks not included")))))

(defvar agent-shell-hq-recall-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "j") #'agent-shell-hq-recall-next)
    (define-key map (kbd "n") #'agent-shell-hq-recall-next)
    (define-key map (kbd "k") #'agent-shell-hq-recall-previous)
    (define-key map (kbd "p") #'agent-shell-hq-recall-switch-project)
    (define-key map (kbd "i") #'agent-shell-hq-recall-switch-index)
    (define-key map (kbd "g") #'agent-shell-hq-recall-refresh)
    (define-key map (kbd "v") #'agent-shell-hq-recall-inspect-identity)
    (define-key map (kbd "L") #'agent-shell-hq-recall-link-session)
    (define-key map (kbd "RET") #'agent-shell-hq-recall-resume)
    (define-key map (kbd "o") #'agent-shell-hq-recall-open)
    (define-key map (kbd "d") #'agent-shell-hq-recall-delete-transcript)
    (define-key map (kbd "D") #'agent-shell-hq-recall-delete-local-session)
    (define-key map (kbd "q") #'agent-shell-hq-recall-quit)
    (define-key map (kbd "C-g") #'agent-shell-hq-recall-quit)
    map))

(define-derived-mode agent-shell-hq-recall-mode special-mode "HQ-Recall"
  "Two-pane HQ-like browser of closed session transcripts.")

(defun agent-shell-hq-recall--start (scope root)
  "Show two-pane browser with SCOPE and ROOT."
  (let* ((saved (current-window-configuration))
         (listbuf (get-buffer-create agent-shell-hq-recall--list-buffer)))
    (delete-other-windows)
    (set-window-buffer (selected-window) listbuf)
    (let ((right (split-window-right
                  (min agent-shell-hq-recall-sidebar-width
                       (max 25 (/ (frame-width) 2))))))
      (with-current-buffer listbuf
        (agent-shell-hq-recall-mode)
        (setq-local agent-shell-hq-recall--scope scope
                    agent-shell-hq-recall--root (expand-file-name root)
                    agent-shell-hq-recall--saved-windows saved
                    agent-shell-hq-recall--preview-window right)
        (agent-shell-hq-recall--render))
      (select-window (get-buffer-window listbuf)))))

;;;###autoload
(defun agent-shell-hq-recall-index ()
  "List closed sessions from agent-recall persistent index in an HQ-like UI."
  (interactive)
  (agent-shell-hq-recall--start 'index (agent-shell-hq-recall--project-root)))

;;;###autoload
(defun agent-shell-hq-recall-here (&optional exact-directory)
  "Scan current project's transcripts directly, without reindexing.
With prefix EXACT-DIRECTORY, use `default-directory' instead."
  (interactive "P")
  (agent-shell-hq-recall--start
   'here (if exact-directory default-directory
           (agent-shell-hq-recall--project-root))))

;; Commands from the HQ sidebar. K still means CLOSE; D in Recall means DELETE.
(with-eval-after-load 'agent-shell-hq-toggle
  (define-key agent-shell-hq-toggle-map (kbd "H")
    #'agent-shell-hq-recall-index)
  (define-key agent-shell-hq-toggle-map (kbd "P")
    #'agent-shell-hq-recall-here))

(provide 'agent-shell-hq-recall)
;;; agent-shell-hq-recall.el ends here
