;;; gptel-cpp-complete.el --- GPTel-powered C++ completion -*- lexical-binding: t -*-

;; Copyright (C) 2025-2026 by Huming Chen

;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-cpp-complete
;; Version: 0.3.0
;; Created: 2025-12-26
;; Keywords: programming, convenience
;; Package-Requires: ((emacs "30.1") (eglot "1.19") (gptel "0.9.8"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; C++ code completion powered by eglot/clangd, tree-sitter, rg/ag and the fantastic gptel.

;;; Install:

;; Put this file into load-path directory, and byte compile it if
;; desired. And put the following expression into your ~/.emacs.d
;;
;; (require 'gptel-cpp-complete)
;; (when (display-graphic-p)
;;   (dolist (c-mode-hook '(c-mode-common-hook c-ts-mode-hook c++-ts-mode-hook))
;;     (add-hook c-mode-hook #'gptel-cpp-complete-mode)))

;;; Change Log:
;;
;; 0.0.2 Replace MIT license with GPL license
;; 0.1.1 Enhanced system prompt for C++ code completion
;; 0.1.2 Add minor mode `gptel-cpp-complete-mode'
;; 0.1.3 Adding `/no_think' for system prompt
;; 0.1.4 Replace run-with-idle-time with run-with-timer
;; 0.1.5 Fix <return> conflict between `corfu-insert' and `gptel-cpp-complete'
;; 0.1.6 Remove duplicated texts from completion
;; 0.1.7 Retrieve completion-symbols and fix ag search issue
;; 0.1.8 Show completion only when location didn't change
;; 0.1.9 Add rg support
;; 0.2.0 Improve stability.
;; 0.3.0 Major robustness overhaul:
;;        - Fix async callback buffer-context bugs
;;        - Fix timer buffer-locality issues
;;        - Make grep searches use combined patterns (single process)
;;        - Cache file contents in snippet extraction
;;        - Add escape to dismiss overlay, customizable accept key
;;        - Add partial word-accept command
;;        - Use cl-remove-duplicates instead of destructive delete-dups
;;        - Smarter trigger logic (trigger characters only)
;;        - Add unload function

;;; Code:

(require 'eglot)
(require 'gptel)
(require 'cl-lib)
(require 'treesit)
(require 'which-func)

;; Silence byte-compiler for eglot internals
(declare-function eglot--pos-to-lsp-position "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function eglot-uri-to-path "eglot")
(declare-function eglot--lsp-position-to-point "eglot")
(declare-function eglot-current-server "eglot")
(declare-function jsonrpc-request "jsonrpc")

;; ------------------------------------------------------------
;; Configuration
;; ------------------------------------------------------------
(defgroup gptel-cpp-complete nil
  "GPTel-based C++ code completion."
  :group 'tools)

(defcustom gptel-cpp-complete-delay 1.5
  "Delay time before regenerating GPTel completion."
  :type 'number
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-include-call-hierarchy t
  "Include caller-hierarchy, takes more time."
  :type 'boolean
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-completion-max 8
  "Max number of completion symbols used for validation."
  :type 'integer
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-ag-cmd "ag --cpp --nobreak --noheading -C 3 %s | cut -d: -f2- | head -n 30"
  "Ag command to search similar pattern.
The %s placeholder is replaced with the shell-quoted search pattern."
  :type 'string
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-rg-cmd "rg -t cpp -C 3 %s --no-heading --color never | head -n 30"
  "Rg command to search similar pattern.
The %s placeholder is replaced with the shell-quoted search pattern."
  :type 'string
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-accept-key "<tab>"
  "Key to accept ghost completion."
  :type 'string
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-trigger-characters nil
  "Characters that trigger completion.
When non-nil, completion is only scheduled when `self-insert-command' inserts
one of these characters.  When nil (the default), any self-insert triggers
completion (original behavior)."
  :type '(repeat character)
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-lsp-timeout 2
  "Timeout in seconds for LSP requests (completion, call hierarchy).
Prevents blocking Emacs when clangd is slow."
  :type 'number
  :group 'gptel-cpp-complete)

(defcustom gptel-cpp-complete-debug nil
  "When non-nil, log warnings for internal errors instead of silencing them."
  :type 'boolean
  :group 'gptel-cpp-complete)


;; ------------------------------------------------------------
;; Helpers
;; ------------------------------------------------------------
(defun gptel-cpp-complete--extract-method-name (func-name)
  "Given FUNC-NAME, return a SHORT-FUNC, e.g: class::method(arg1, arg2) => method."
  (when-let* ((temp-split (split-string func-name "("))
              (short-func-with-namespace (car temp-split))
              (short-func (car (last (split-string short-func-with-namespace "::")))))
    short-func))

(defun gptel-cpp-complete--goto-function-name ()
  "Move cursor to current function name."
  (treesit-beginning-of-defun)
  (when-let* ((func-name (which-function))
              (not-empty (not (string-empty-p func-name)))
              (func-name (gptel-cpp-complete--extract-method-name func-name))
              (not-empty (not (string-empty-p func-name))))
    (search-forward func-name nil t)))

(defun gptel-cpp-complete--safe-subseq (seq start end)
  "Safely extracts a subseq from SEQ from START to END (not included)."
  (when seq
    (cl-subseq seq start (min end (length seq)))))

(defun gptel-cpp-complete--word-at-overlay-start ()
  "Return the identifier/word immediately before point, or empty string."
  (save-excursion
    (let ((end (point)))
      (skip-chars-backward "A-Za-z0-9_")
      (buffer-substring-no-properties (point) end))))

(defun gptel-cpp-complete--in-string-or-comment-p ()
  "Return non-nil if point is inside a string or comment."
  (let ((state (syntax-ppss)))
    (or (nth 3 state)  ;; string
        (nth 4 state)))) ;; comment

(defun gptel-cpp-complete--in-preprocessor-p ()
  "Return non-nil if point is in a C/C++ preprocessor directive."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "\\s-*#")))

;; ------------------------------------------------------------
;; Extract completion-symbols
;; ------------------------------------------------------------
(defun gptel-cpp-complete--completion-symbols-lite ()
  "Return a limited list of LSP completion items at point."
  (when-let* ((server (eglot-current-server))
              (pos    (eglot--pos-to-lsp-position (point)))
              (params `(:textDocument (:uri ,(eglot-path-to-uri
                                              (buffer-file-name)))
                                      :position ,pos
                                      :context (:triggerKind 1)))
              (result (ignore-errors
                        (jsonrpc-request server
                                         :textDocument/completion
                                         params
                                         :timeout gptel-cpp-complete-lsp-timeout))))
    (let ((items (cond
                  ((vectorp result) result)
                  ((plist-get result :items))
                  (t nil))))
      (cl-subseq (append items nil)
                 0 (min gptel-cpp-complete-completion-max
                        (length items))))))

(defun gptel-cpp-complete--completion-item->entry (item)
  "Convert a completion ITEM into an internal symbol entry."
  (let ((label (plist-get item :label))
        (kind  (plist-get item :kind)))
    (cons
     label
     (list
      :label  label
      :kind   kind
      :source 'completion))))

(defun gptel-cpp-complete--in-scope-symbols+kind ()
  "Return merged in-scope symbols using completion validation."
  (let ((comp-syms
         (mapcar
          #'gptel-cpp-complete--completion-item->entry
          (or (gptel-cpp-complete--completion-symbols-lite) '()))))
    comp-syms))

;; ------------------------------------------------------------
;; Extraction current function
;; ------------------------------------------------------------
(defun gptel-cpp-complete--cpp-current-function ()
  "Return current C++ function definition as string."
  (if (not (treesit-ready-p 'cpp t))
      (progn
        (when gptel-cpp-complete-debug
          (display-warning 'gptel-cpp-complete
                           "tree-sitter cpp grammar not available"
                           :warning))
        nil)
    (save-excursion
      (condition-case err
          (let ((cursor-pos (point)) func-start func-end
                prefix suffix)
            (treesit-beginning-of-defun)
            (setq func-start (point))
            (treesit-end-of-defun)
            (setq func-end (point)
                  prefix (buffer-substring-no-properties func-start cursor-pos)
                  suffix (buffer-substring-no-properties cursor-pos func-end))
            (concat prefix "<-- HERE -->" suffix))
        (error
         (when gptel-cpp-complete-debug
           (display-warning 'gptel-cpp-complete
                            (format "Error in --cpp-current-function: %s" err)
                            :warning))
         nil)))))

;; ------------------------------------------------------------
;; Extraction similar pattern (combined single-process grep)
;; ------------------------------------------------------------
(defun gptel-cpp-complete--classify-symbols (symbols)
  "Classify SYMBOLS into different kind."
  (cl-loop for s in symbols
           if (memq (plist-get s :kind) '(2 3 4)) collect s into funcs
           else if (memq (plist-get s :kind) '(6 21)) collect s into vars
           else if (memq (plist-get s :kind) '(5 10 20)) collect s into members
           finally return `(:funcs ,funcs :vars ,vars :members ,members)))

(defun gptel-cpp-complete--select-search-symbols (classified)
  "Select symbols to search based on CLASSIFIED."
  (append
   (gptel-cpp-complete--safe-subseq (plist-get classified :funcs) 0 2)
   (gptel-cpp-complete--safe-subseq (plist-get classified :vars) 0 1)
   (gptel-cpp-complete--safe-subseq (plist-get classified :members) 0 1)))

(defun gptel-cpp-complete--grep-pattern-for-symbol (symbol)
  "Format SYMBOL for searching with `ag' or `rg'."
  (let* ((name (plist-get symbol :label))
         (kind (plist-get symbol :kind)))
    (cond
     ((memq kind '(2 3 4)) ;; method/function/ctor
      (when (string-match "\\b\\([A-Za-z_][A-Za-z0-9_]*\\)\\s-*(" name)
        (setq name (match-string 1 name)))
      (setq name (gptel-cpp-complete--extract-method-name name))
      (format "\\b%s\\s*\\(" name))
     ((eq kind 20) ;; enum member
      (format "::%s\\b" name))
     ((memq kind '(5 10)) ;; field/property
      (format "(\\.|->|::)%s\\b" name))
     (t
      (format "\\b%s\\b" name)))))

(defun gptel-cpp-complete--sh-quote-argument (arg)
  "Quote ARG for /bin/sh, independent of `shell-file-name'.
Wraps ARG in single quotes, escaping any embedded single quotes."
  (concat "'" (replace-regexp-in-string "'" "'\\\\''" arg) "'"))

(defun gptel-cpp-complete--kill-grep-buffer (buf)
  "Kill BUF safely, suppressing process-query prompts.
Also kills the associated stderr buffer if present."
  (when (buffer-live-p buf)
    (when-let* ((proc (get-buffer-process buf)))
      (set-process-query-on-exit-flag proc nil)
      ;; Clean up stderr buffer
      (when-let* ((stderr-buf (process-get proc :stderr-buffer)))
        (when (buffer-live-p stderr-buf)
          (kill-buffer stderr-buf)))
      (when (process-live-p proc)
        (delete-process proc)))
    (kill-buffer buf)))

(defun gptel-cpp-complete--start-grep-process (output-buf full-cmd)
  "Start grep process running FULL-CMD with output to OUTPUT-BUF.
Uses /bin/sh explicitly to avoid shell compatibility issues (e.g. tcsh),
and discards stderr so diagnostic messages don't pollute results."
  (let* ((stderr-buf (generate-new-buffer " *gptel-grep-stderr*"))
         (proc (make-process
                :name "gptel-grep"
                :buffer output-buf
                :command (list "/bin/sh" "-c" full-cmd)
                :stderr stderr-buf
                :noquery t)))
    ;; Also suppress query on stderr pipe process
    (when-let* ((stderr-proc (get-buffer-process stderr-buf)))
      (set-process-query-on-exit-flag stderr-proc nil))
    ;; Store stderr-buf for cleanup
    (process-put proc :stderr-buffer stderr-buf)
    proc))

(defun gptel-cpp-complete--grep-search-async (patterns owner-buf callback)
  "Search PATTERNS asynchronously, call CALLBACK with result string.
OWNER-BUF is the buffer that owns this request (for process tracking)."
  (if (not patterns)
      (funcall callback "")
    (let* ((combined (format "(%s)" (string-join patterns "|")))
           (cmd-template (cond ((executable-find "rg") gptel-cpp-complete-rg-cmd)
                               ((executable-find "ag") gptel-cpp-complete-ag-cmd)
                               (t nil)))
           (full-cmd (when cmd-template
                       (format cmd-template (gptel-cpp-complete--sh-quote-argument combined)))))
      (if (not full-cmd)
          ;; Fallback to standard grep if rg/ag not available
          (let ((fallback-cmd (format "grep -E -R -n -e %s ."
                                    (gptel-cpp-complete--sh-quote-argument combined))))
            (let ((output-buf (generate-new-buffer " *gptel-grep*")))
              (condition-case err
                  (let ((proc (gptel-cpp-complete--start-grep-process
                               output-buf fallback-cmd)))
                    (when (buffer-live-p owner-buf)
                      (with-current-buffer owner-buf
                        (setq gptel-cpp-complete--grep-process proc)))
                    (set-process-sentinel
                     proc
                     (lambda (proc _event)
                       (when (memq (process-status proc) '(exit signal))
                         (let ((result (when (and (buffer-live-p output-buf)
                                             (eq (process-status proc) 'exit))
                                         (with-current-buffer output-buf
                                           (buffer-string)))))
                           (gptel-cpp-complete--kill-grep-buffer output-buf)
                           (when (buffer-live-p owner-buf)
                             (with-current-buffer owner-buf
                               (setq gptel-cpp-complete--grep-process nil)))
                           (when (eq (process-status proc) 'exit)
                             (funcall callback (or result "")))))))
                (error
                 (gptel-cpp-complete--kill-grep-buffer output-buf)
                 (when gptel-cpp-complete-debug
                   (display-warning 'gptel-cpp-complete
                                    (format "Grep async error: %s" err)
                                    :warning))
                 (funcall callback ""))))))
        (let ((output-buf (generate-new-buffer " *gptel-grep*")))
          (condition-case err
              (let ((proc (gptel-cpp-complete--start-grep-process
                           output-buf full-cmd)))
                ;; Track process in owner buffer for cancellation
                (when (buffer-live-p owner-buf)
                  (with-current-buffer owner-buf
                    (setq gptel-cpp-complete--grep-process proc)))
                (set-process-sentinel
                 proc
                 (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (let ((result (when (and (buffer-live-p output-buf)
                                             (eq (process-status proc) 'exit))
                                     (with-current-buffer output-buf
                                       (buffer-string)))))
                       (gptel-cpp-complete--kill-grep-buffer output-buf)
                       (when (buffer-live-p owner-buf)
                         (with-current-buffer owner-buf
                           (setq gptel-cpp-complete--grep-process nil)))
                       ;; Only invoke callback on exit (any code), not signal
                       ;; rg/ag exit 1 = no matches, which is fine
                       (when (eq (process-status proc) 'exit)
                         (funcall callback (or result ""))))))))
            (error
             (gptel-cpp-complete--kill-grep-buffer output-buf)
             (when gptel-cpp-complete-debug
               (display-warning 'gptel-cpp-complete
                                (format "Grep async error: %s" err)
                                :warning))
             (funcall callback ""))))))))


;; ------------------------------------------------------------
;; Extraction caller and callee (with file caching)
;; ------------------------------------------------------------
(defun gptel-cpp-complete--call-hierarchy-item ()
  "Prepare call hierarchy item at point."
  (save-excursion
    (gptel-cpp-complete--goto-function-name)
    (when-let* ((server (eglot-current-server))
                (pos (eglot--pos-to-lsp-position (point)))
                (params `(:textDocument (:uri ,(eglot-path-to-uri
                                                (buffer-file-name)))
                                        :position ,pos))
                (result (ignore-errors
                          (jsonrpc-request server
                                           :textDocument/prepareCallHierarchy
                                           params
                                           :timeout gptel-cpp-complete-lsp-timeout)))
                (valid (not (seq-empty-p result))))
      (aref result 0))))

(defun gptel-cpp-complete--incoming-calls (item)
  "Query incoming call of ITEM."
  (when-let* ((item item)
              (server (eglot-current-server)))
    (ignore-errors
      (jsonrpc-request server
                       :callHierarchy/incomingCalls
                       `(:item ,item)
                       :timeout gptel-cpp-complete-lsp-timeout))))

(defun gptel-cpp-complete--outgoing-calls (item)
  "Query outgoing call of ITEM."
  (when-let* ((item item)
              (server (eglot-current-server)))
    (ignore-errors
      (jsonrpc-request server
                       :callHierarchy/outgoingCalls
                       `(:item ,item)
                       :timeout gptel-cpp-complete-lsp-timeout))))

(defun gptel-cpp-complete--snippet-from-range (uri range file-cache)
  "Extract code snippets based on URI and RANGE, using FILE-CACHE hash table."
  (let* ((path (eglot-uri-to-path uri))
         (content (or (gethash path file-cache)
                      (let ((text (with-temp-buffer
                                    (insert-file-contents path)
                                    (buffer-string))))
                        (puthash path text file-cache)
                        text))))
    (with-temp-buffer
      (insert content)
      (goto-char (point-min))
      (forward-line (plist-get (plist-get (aref range 0) :start) :line))
      (let ((beg (line-beginning-position))
            (end (line-end-position 5)))
        (buffer-substring-no-properties beg end)))))

(defun gptel-cpp-complete--format-callers (callers file-cache)
  "Format CALLERS using FILE-CACHE."
  (when (and callers (not (seq-empty-p callers)))
    (string-join
     (cl-loop for call across (cl-subseq callers 0 (min 3 (length callers)))
              collect
              (gptel-cpp-complete--snippet-from-range
               (plist-get (plist-get call :from) :uri)
               (plist-get call :fromRanges)
               file-cache))
     "\n\n")))

(defun gptel-cpp-complete--format-callees (callees file-cache)
  "Format CALLEES using FILE-CACHE."
  (when (and callees (not (seq-empty-p callees)))
    (string-join
     (cl-loop for call across (cl-subseq callees 0 (min 3 (length callees)))
              collect
              (gptel-cpp-complete--snippet-from-range
               (plist-get (plist-get call :to) :uri)
               (plist-get call :fromRanges)
               file-cache))
     "\n\n")))

(defun gptel-cpp-complete--call-hierarchy-context ()
  "Retrieve caller and callee information."
  (ignore-errors
    (when-let* ((item (gptel-cpp-complete--call-hierarchy-item)))
      (let ((file-cache (make-hash-table :test #'equal))
            (incoming (gptel-cpp-complete--incoming-calls item))
            (outgoing (gptel-cpp-complete--outgoing-calls item)))
        (cons
         (or (gptel-cpp-complete--format-callers incoming file-cache) "None")
         (or (gptel-cpp-complete--format-callees outgoing file-cache) "None"))))))


;; ------------------------------------------------------------
;; Prompt Construction
;; ------------------------------------------------------------
(defconst gptel-cpp-complete--system-prompt
  "/no_think
You are a precise C++ code completion assistant operating inside a large existing codebase.
## ROLE
You function as an intelligent, conservative autocomplete. Your only job is to continue the code exactly at the cursor position (marked <-- HERE -->).

## PROVIDED CONTEXT (always analyze this first)
- The current function body or statement with cursor location
- Full list of in-scope symbols (variables, functions, types, macros, namespaces)
- Repository usage patterns and similar code examples
- Callers of the current function (how it is invoked)
- Callees (what the current function already calls)

## ABSOLUTE RULES — NEVER VIOLATE
1. **Use ONLY symbols and constructs from the provided context.** Do not invent any new functions, classes, templates, macros, variables, or #includes.
2. **Never modify or repeat code outside the exact completion region.** Output solely the continuation starting at the cursor.
3. **Match the codebase style perfectly:** indentation, bracing style ({ on same line or next), naming conventions, const/ref qualifiers, error handling, and idioms seen in the provided patterns and callers/callees.
4. **Respect C++ semantics:** const-correctness, lifetimes, ownership (RAII, smart pointers, moves), exception safety, template constraints, and overload resolution.
5. **Guarantee compilability** in this specific codebase. Prefer simple, obviously correct code over clever or optimized solutions.

## PRIORITIES (in strict order)
1. Reuse existing helper functions, patterns, and idioms from the similar usage examples provided.
2. Follow conventions visible in the function's callers and callees.
3. Be as minimal and conservative as possible — shortest reasonable completion that makes semantic sense.
4. Prefer readability and obvious correctness over brevity or performance tricks.

## OUTPUT FORMAT — CRITICAL
- Respond with **ONLY** the exact code to insert at the cursor position. Nothing else.
- No explanations, comments, markdown, backticks, or reasoning.
- Do not repeat any code that already appears before the cursor.
- If the completion is a partial statement or expression, output only what's needed to continue naturally.
- If multiple options exist, choose the shortest one that is clearly correct and consistent.

Think step-by-step internally: What symbols are available? What patterns match the context best? Then output only the continuation."
  "Enhanced system prompt for C++ code completion in gptel.")

(defconst gptel-cpp-complete--user-prompt
  "Current function:
%s

In-scope symbols:
%s

Similar patterns in this repository:
%s

Callers of this function:
%s

Callees of this function:
%s
"
  "Completion user prompt.")

(defun gptel-cpp-complete--build-prompt ()
  "Assemble GPTel completion prompt synchronously (used by async pipeline)."
  (let* ((func (or (gptel-cpp-complete--cpp-current-function) "N/A"))
         (symbols+kind (or (gptel-cpp-complete--in-scope-symbols+kind) '()))
         (symbols (or (cl-remove-duplicates (mapcar #'car symbols+kind)
                                            :test #'equal)
                      '()))
         (s+k (or (mapcar #'cdr symbols+kind) '()))
         (calls (and gptel-cpp-complete-include-call-hierarchy
                     (gptel-cpp-complete--call-hierarchy-context)))
         (incoming (or (car calls) "None found"))
         (outgoing (or (cdr calls) "None found")))
    (list :func func :symbols symbols :s+k s+k
          :incoming incoming :outgoing outgoing)))

(defun gptel-cpp-complete--format-prompt (parts patterns)
  "Format the final prompt from PARTS and grep PATTERNS result."
  (let ((pat-str (if (or (null patterns) (string-empty-p patterns))
                     "None found" patterns)))
    (format gptel-cpp-complete--user-prompt
            (plist-get parts :func)
            (string-join (plist-get parts :symbols) "\n\n")
            pat-str
            (plist-get parts :incoming)
            (plist-get parts :outgoing))))

;; ------------------------------------------------------------
;; Overlay Management
;; ------------------------------------------------------------
(defvar-local gptel-cpp-complete--overlay nil)

(defun gptel-cpp-complete--clear-overlay ()
  "Remove GPTel completion overlay."
  (interactive)
  (when (overlayp gptel-cpp-complete--overlay)
    (delete-overlay gptel-cpp-complete--overlay))
  (setq gptel-cpp-complete--overlay nil
        gptel-cpp-complete--last-tick nil))

(defun gptel-cpp-complete--overlay-active-p ()
  "Return non-nil if GPTel overlay is active."
  (and (overlayp gptel-cpp-complete--overlay)
       (overlay-buffer gptel-cpp-complete--overlay)))

(defun gptel-cpp-complete--show-overlay (text)
  "Show TEXT as ghost completion at point."
  (gptel-cpp-complete--clear-overlay)
  (setq gptel-cpp-complete--overlay (make-overlay (point) (point)))
  (overlay-put gptel-cpp-complete--overlay
               'after-string
               (propertize text 'face 'shadow))
  (setq gptel-cpp-complete--last-tick (buffer-chars-modified-tick)))

(defun gptel-cpp-complete--overlay-text ()
  "Return the text of the current overlay, or nil."
  (when (gptel-cpp-complete--overlay-active-p)
    (substring-no-properties
     (overlay-get gptel-cpp-complete--overlay 'after-string))))

(defun gptel-cpp-complete--accept-overlay ()
  "Insert overlay completion into buffer."
  (let* ((completion (gptel-cpp-complete--overlay-text))
         (prefix (gptel-cpp-complete--word-at-overlay-start)))
    (gptel-cpp-complete--clear-overlay)
    (when completion
      ;; Remove common prefix to avoid duplication
      (if (and (not (string-empty-p prefix))
               (string-prefix-p prefix completion))
          (insert (substring completion (length prefix)))
        (insert completion)))))

;;;###autoload
(defun gptel-cpp-complete-accept-word ()
  "Accept the next word/token from the ghost completion overlay."
  (interactive)
  (when-let* ((text (gptel-cpp-complete--overlay-text))
              (not-empty (not (string-empty-p text))))
    (let* ((prefix (gptel-cpp-complete--word-at-overlay-start))
           (rest (if (and (not (string-empty-p prefix))
                          (string-prefix-p prefix text))
                     (substring text (length prefix))
                   text))
           ;; Find the next word boundary in rest
           (word-end (or (and (string-match "\\`\\s-+" rest)
                              (match-end 0))
                         (string-match "[^A-Za-z0-9_]" rest 1)
                         (length rest)))
           (word (substring rest 0 word-end))
           (remaining (substring rest word-end)))
      (gptel-cpp-complete--clear-overlay)
      (insert word)
      ;; Show remaining text as new overlay if non-empty
      (when (not (string-empty-p remaining))
        (gptel-cpp-complete--show-overlay remaining)))))

;;;###autoload
(defun gptel-cpp-complete-accept ()
  "Accept the full ghost completion."
  (interactive)
  (if (gptel-cpp-complete--overlay-active-p)
      (gptel-cpp-complete--accept-overlay)
    ;; Fallback: run whatever was bound before
    (let ((gptel-cpp-complete-mode nil))
      (call-interactively (key-binding (this-command-keys))))))

;;;###autoload
(defun gptel-cpp-complete-return ()
  "Handle completion, `corfu-insert' and `newline'."
  (interactive)
  (cond
   ((gptel-cpp-complete--overlay-active-p)
    (gptel-cpp-complete--accept-overlay))
   ((and (fboundp 'corfu-insert)
         (boundp 'corfu--index)
         (>= corfu--index 0))
    (call-interactively #'corfu-insert))
   (t (call-interactively #'newline))))


;; ------------------------------------------------------------
;; GPTel Interaction
;; ------------------------------------------------------------
(defvar-local gptel-cpp-complete--regenerate-timer nil)
(defvar-local gptel-cpp-complete--request nil)
(defvar-local gptel-cpp-complete--grep-process nil)
(defvar-local gptel-cpp-complete--request-seq 0
  "Sequence number to detect stale async callbacks.")

(defun gptel-cpp-complete--cancel-request ()
  "Cancel any in-flight gptel request, grep process, or timer for this buffer."
  (when gptel-cpp-complete--regenerate-timer
    (cancel-timer gptel-cpp-complete--regenerate-timer)
    (setq gptel-cpp-complete--regenerate-timer nil))
  ;; Kill in-flight grep process
  (when (and gptel-cpp-complete--grep-process
             (process-live-p gptel-cpp-complete--grep-process))
    (delete-process gptel-cpp-complete--grep-process))
  (setq gptel-cpp-complete--grep-process nil)
  ;; Bump sequence to invalidate any pending async callbacks
  (cl-incf gptel-cpp-complete--request-seq)
  (when gptel-cpp-complete--request
    (ignore-errors
      (gptel-abort gptel-cpp-complete--request))
    (setq gptel-cpp-complete--request nil)))

(defun gptel-cpp-complete--make-response-handler (buf pos seq)
  "Return a response handler bound to BUF, POS, and SEQ for staleness detection."
  (lambda (response _info)
    (when (and response (stringp response)
               (buffer-live-p buf))
      (with-current-buffer buf
        (setq gptel-cpp-complete--request nil)
        (message "")
        ;; Only show if sequence hasn't changed (no new request started)
        ;; and point hasn't moved.  If stale, just ignore — do NOT clear
        ;; an overlay that may belong to a newer valid response.
        (when (and (= seq gptel-cpp-complete--request-seq)
                   (= (point) pos))
          (gptel-cpp-complete--show-overlay response))))))

(defun gptel-cpp-complete--fire-request ()
  "Start a new AI completion request with async grep.
Gathers LSP data synchronously (fast), runs grep asynchronously,
then fires the gptel request once grep completes."
  (let* ((buf (current-buffer))
         (pos (point))
         (seq gptel-cpp-complete--request-seq)
         (parts (gptel-cpp-complete--build-prompt))
         (s+k (plist-get parts :s+k))
         (classified (gptel-cpp-complete--classify-symbols s+k))
         (targets (gptel-cpp-complete--select-search-symbols classified))
         (patterns (cl-loop for sym in targets
                            for pat = (gptel-cpp-complete--grep-pattern-for-symbol sym)
                            when pat collect pat)))
    (gptel-cpp-complete--grep-search-async
     patterns
     buf
     (lambda (grep-result)
       ;; Only proceed if this request is still current
       (when (and (buffer-live-p buf)
                  (with-current-buffer buf
                    (and (= seq gptel-cpp-complete--request-seq)
                         (= (point) pos))))
         (with-current-buffer buf
           (let ((prompt (gptel-cpp-complete--format-prompt parts grep-result)))
             (setq gptel-cpp-complete--request
                   (gptel-request prompt
                     :system gptel-cpp-complete--system-prompt
                     :callback (gptel-cpp-complete--make-response-handler
                                buf pos seq))))))))))

(defun gptel-cpp-complete--do-complete (buf pos)
  "Actually fire the completion request for BUF at POS.
Only proceeds if the buffer is alive and point hasn't moved."
  (when (and (buffer-live-p buf)
             (eq buf (current-buffer))
             (= (point) pos))
    (message "Generating completion...")
    (gptel-cpp-complete--fire-request)))

(defun gptel-cpp-complete--schedule-regenerate ()
  "Schedule GPTel completion after delay, with proper buffer/position capture."
  (gptel-cpp-complete--cancel-request)
  (let ((buf (current-buffer))
        (pos (point)))
    (setq gptel-cpp-complete--regenerate-timer
          (run-with-timer
           gptel-cpp-complete-delay nil
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq gptel-cpp-complete--regenerate-timer nil)
                 (gptel-cpp-complete--do-complete buf pos))))))))

;; ------------------------------------------------------------
;; Input Handling
;; ------------------------------------------------------------
(defun gptel-cpp-complete--should-trigger-p ()
  "Return non-nil if we should trigger GPT completion.
Only triggers on configured trigger characters (or any char if nil),
outside strings/comments/preprocessor."
  (and
   (eq this-command 'self-insert-command)
   (not (gptel-cpp-complete--in-string-or-comment-p))
   (not (gptel-cpp-complete--in-preprocessor-p))
   (or (null gptel-cpp-complete-trigger-characters)
       (memq (char-before) gptel-cpp-complete-trigger-characters))))

(defvar-local gptel-cpp-complete--last-tick nil
  "Buffer modification tick when overlay was shown.")

(defun gptel-cpp-complete--post-command ()
  "Post-command hook driving GPTel completion."
  (when (derived-mode-p 'c++-mode 'c++-ts-mode 'c-mode)
    (cond
     ;; Typing: clear overlay, cancel old request, maybe start new one
     ((gptel-cpp-complete--should-trigger-p)
      (gptel-cpp-complete--clear-overlay)
      (gptel-cpp-complete--cancel-request)
      (gptel-cpp-complete--schedule-regenerate))
     ;; Buffer was modified by something other than self-insert (delete, yank, etc.)
     ((and gptel-cpp-complete--last-tick
           (not (= gptel-cpp-complete--last-tick (buffer-chars-modified-tick))))
      (gptel-cpp-complete--clear-overlay)
      (gptel-cpp-complete--cancel-request))
     ;; Non-editing command (movement, scroll) — leave overlay alone
     (t nil))))

;; ------------------------------------------------------------
;; Mode Definition
;; ------------------------------------------------------------
(defvar gptel-cpp-complete-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<return>") #'gptel-cpp-complete-return)
    (define-key map (kbd "<escape>") #'gptel-cpp-complete--clear-overlay)
    (define-key map (kbd gptel-cpp-complete-accept-key) #'gptel-cpp-complete-accept)
    (define-key map (kbd "M-<right>") #'gptel-cpp-complete-accept-word)
    map))

;;;###autoload
(define-minor-mode gptel-cpp-complete-mode
  "Mode for ai-assisted C++ completion powered by eglot + gptel."
  :group 'gptel-cpp-complete :keymap gptel-cpp-complete-mode-map
  (cond
   (gptel-cpp-complete-mode
    (add-hook 'post-command-hook #'gptel-cpp-complete--post-command nil t)
    (setq-local eglot-extend-to-xref t))
   (t
    (remove-hook 'post-command-hook #'gptel-cpp-complete--post-command t)
    (gptel-cpp-complete--clear-overlay)
    (gptel-cpp-complete--cancel-request)
    (kill-local-variable 'eglot-extend-to-xref))))

(defun gptel-cpp-complete-unload-function ()
  "Clean up when the package is unloaded."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when gptel-cpp-complete-mode
        (gptel-cpp-complete-mode -1)))))

(provide 'gptel-cpp-complete)
;;; gptel-cpp-complete.el ends here
