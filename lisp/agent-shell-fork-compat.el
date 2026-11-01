;;; agent-shell-fork-compat.el --- Load Codex forks before use -*- lexical-binding: t; -*-

;; codex-acp 2.1.1 unsubscribes a newly forked thread.  Loading it before
;; the first prompt reattaches the event stream (codex-acp issue/PR #466).
;; Keep this workaround outside package-managed agent-shell sources.

;;; Code:

(require 'agent-shell)
(require 'cl-lib)
(require 'map)
(require 'seq)

(defun agent-shell-fork-compat--inherit-context (session-id state)
  "Copy the parent SESSION-ID's last context measurement into STATE.
Token totals and cost belong to the new session and are not copied."
  (when-let* ((parent
               (seq-find
                (lambda (buffer)
                  (with-current-buffer buffer
                    (and (derived-mode-p 'agent-shell-mode)
                         (equal session-id
                                (map-nested-elt agent-shell--state
                                                '(:session :id))))))
                (buffer-list)))
              (usage (map-elt (buffer-local-value 'agent-shell--state parent)
                              :usage))
              (used (map-elt usage :context-used))
              (size (map-elt usage :context-size))
              ((and (numberp used) (>= used 0)
                    (numberp size) (> size 0))))
    (let ((new-usage (map-elt state :usage)))
      (map-put! new-usage :context-used used)
      (map-put! new-usage :context-size size)
      (map-put! state :usage new-usage))
    (agent-shell--update-header-and-mode-line)))

(cl-defun agent-shell-fork-compat--codex-fork
    (&key session-id shell-buffer on-session-init)
  "Fork Codex SESSION-ID, then load it before ON-SESSION-INIT.
Do not expose an active session id or report readiness until loading
succeeds.  Retain the fork id for recovery if loading fails."
  (let* ((state (agent-shell--state))
         (error-handler (agent-shell--make-error-handler
                         :state state :shell-buffer shell-buffer))
         (on-failure
          (lambda (acp-error raw-message)
            (map-put! state :pending-restore nil)
            (funcall error-handler acp-error raw-message))))
    (agent-shell-fork-compat--inherit-context session-id state)
    (agent-shell--update-bootstrapping-fragment
     :state state :block-id "starting"
     :body (format "\n\nForking session %s..." session-id) :append t)
    (agent-shell--send-request
     :state state :client (map-elt state :client) :buffer shell-buffer
     :request (acp-make-session-fork-request
               :session-id session-id
               :cwd (agent-shell--resolve-path (agent-shell-cwd))
               :mcp-servers (agent-shell--mcp-servers)
               :meta (map-nested-elt state '(:agent-config :session-meta)))
     :on-failure on-failure
     :on-success
     (lambda (fork-response)
       (let ((fork-id (map-elt fork-response 'sessionId)))
         (if (not (and (stringp fork-id) (not (string-empty-p fork-id))))
             (funcall on-failure
                      '((message . "Fork response missing sessionId")) nil)
           ;; A later retry must load this fork, rather than fork the parent
           ;; again.  :session :id stays nil, so submit remains guarded.
           (map-put! state :resume-session-id fork-id)
           (map-put! state :fork-session-id nil)
           ;; Always buffer load's replay, including minimal verbosity.
           ;; Render it only after bootstrapping; minimal discards it.
           (map-put! state :pending-restore
                     (agent-shell--make-pending-restore))
           (agent-shell--update-bootstrapping-fragment
            :state state :block-id "starting"
            :body "\n\nLoading fork before use..." :append t)
           (agent-shell--send-request
            :state state :client (map-elt state :client) :buffer shell-buffer
            :request (acp-make-session-load-request
                      :session-id fork-id
                      :cwd (agent-shell--resolve-path (agent-shell-cwd))
                      :mcp-servers (agent-shell--mcp-servers)
                      :meta (map-nested-elt state '(:agent-config :session-meta)))
            :on-failure on-failure
            :on-success
            (lambda (load-response)
              ;; Use load's current metadata, retaining fork metadata for
              ;; agents whose load response omits optional fields.
              (agent-shell--set-session-from-response
               :acp-response (append load-response fork-response)
               :acp-session-id fork-id)
              (agent-shell--emit-event
               :event 'session-selected
               :data (list (cons :session-id fork-id)))
              (agent-shell--update-bootstrapping-fragment
               :state state :block-id "forked_session"
               :label-left
               (format "%s %s"
                       (agent-shell--make-status-kind-label :status "completed")
                       (propertize "Forked session"
                                   'font-lock-face 'agent-shell-section-heading))
               :expanded t :body fork-id)
              (agent-shell--finalize-session-init
               :on-session-init
               (lambda ()
                 (if (eq (agent-shell--effective-restore-verbosity state) 'minimal)
                     (map-put! state :pending-restore nil)
                   (agent-shell--render-pending-restore state))
                 (funcall on-session-init)))))))))))

(defun agent-shell-fork-compat--around-fork (original &rest args)
  "Use fork then load for Codex; call ORIGINAL with ARGS for other agents."
  (if (eq (map-nested-elt (agent-shell--state) '(:agent-config :identifier))
          'codex)
      (apply #'agent-shell-fork-compat--codex-fork args)
    (apply original args)))

(define-minor-mode agent-shell-fork-compat-mode
  "Load newly forked Codex sessions before allowing prompts."
  :global t
  :group 'agent-shell
  (if agent-shell-fork-compat-mode
      (advice-add 'agent-shell--initiate-session-fork-by-id :around
                  #'agent-shell-fork-compat--around-fork)
    (advice-remove 'agent-shell--initiate-session-fork-by-id
                   #'agent-shell-fork-compat--around-fork)))

(provide 'agent-shell-fork-compat)
;;; agent-shell-fork-compat.el ends here
