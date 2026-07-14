;;; gptel-cpp-complete-test.el --- Tests for gptel-cpp-complete -*- lexical-binding: t -*-

;; Copyright (C) 2025-2026 by Huming Chen

;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-cpp-complete
;; Package-Version: 20260713.416
;; Package-Revision: 650e4077dc35
;; Created: 2025-12-26
;; Keywords: convenience

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

;; Self-tests for gptel-cpp-complete.el.
;; Run with: Emacs --batch -l gptel-cpp-complete.el -l gptel-cpp-complete-test.el -f gptel-cpp-complete-run-tests

;;; Code:

(require 'gptel-cpp-complete)

;;;###autoload
(defun gptel-cpp-complete-run-tests ()
  "Run built-in self-tests.  Exit with non-zero status on failure."
  (let ((pass 0) (fail 0))
    (cl-flet ((check (name ok)
                (if ok
                    (progn (princ (format "  PASS: %s\n" name))
                           (cl-incf pass))
                  (princ (format "  FAIL: %s\n" name))
                  (cl-incf fail))))

      (princ "gptel-cpp-complete self-tests\n")
      (princ "=============================\n")

      ;; --- Helpers ---
      (check "extract-method-name basic"
             (equal "doStuff"
                    (gptel-cpp-complete--extract-method-name
                     "MyClass::doStuff(int a, int b)")))
      (check "extract-method-name no namespace"
             (equal "foo"
                    (gptel-cpp-complete--extract-method-name "foo()")))
      (check "extract-method-name nested"
             (equal "bar"
                    (gptel-cpp-complete--extract-method-name "A::B::bar(x)")))

      (check "safe-subseq normal"
             (equal '(2 3) (gptel-cpp-complete--safe-subseq '(1 2 3 4) 1 3)))
      (check "safe-subseq past end"
             (equal '(3 4) (gptel-cpp-complete--safe-subseq '(1 2 3 4) 2 99)))
      (check "safe-subseq nil"
             (null (gptel-cpp-complete--safe-subseq nil 0 5)))

      (check "word-at-overlay-start"
             (with-temp-buffer
               (insert "foo_bar")
               (equal "foo_bar" (gptel-cpp-complete--word-at-overlay-start))))
      (check "word-at-overlay-start empty"
             (with-temp-buffer
               (insert "  ")
               (equal "" (gptel-cpp-complete--word-at-overlay-start))))

      (check "in-string-or-comment (not)"
             (with-temp-buffer
               (c++-mode)
               (insert "int x = 1;")
               (not (gptel-cpp-complete--in-string-or-comment-p))))
      (check "in-string-or-comment (string)"
             (with-temp-buffer
               (emacs-lisp-mode)
               (insert "\"inside string")
               (syntax-propertize (point-max))
               (gptel-cpp-complete--in-string-or-comment-p)))
      (check "in-string-or-comment (comment)"
             (with-temp-buffer
               (emacs-lisp-mode)
               (insert "; this is a comment")
               (syntax-propertize (point-max))
               (gptel-cpp-complete--in-string-or-comment-p)))

      (check "in-preprocessor (yes)"
             (with-temp-buffer
               (insert "  #include <foo>")
               (goto-char 10)
               (gptel-cpp-complete--in-preprocessor-p)))
      (check "in-preprocessor (no)"
             (with-temp-buffer
               (insert "int x;")
               (not (gptel-cpp-complete--in-preprocessor-p))))

      ;; --- Trigger logic ---
      (check "should-trigger (default nil = any char)"
             (with-temp-buffer
               (c++-mode)
               (insert "x")
               (let ((this-command 'self-insert-command)
                     (gptel-cpp-complete-trigger-characters nil))
                 (gptel-cpp-complete--should-trigger-p))))
      (check "should-trigger (restricted, non-trigger)"
             (with-temp-buffer
               (c++-mode)
               (insert "x")
               (let ((this-command 'self-insert-command)
                     (gptel-cpp-complete-trigger-characters '(?.)))
                 (not (gptel-cpp-complete--should-trigger-p)))))
      (check "should-trigger (restricted, trigger char)"
             (with-temp-buffer
               (c++-mode)
               (insert ".")
               (let ((this-command 'self-insert-command)
                     (gptel-cpp-complete-trigger-characters '(?.)))
                 (gptel-cpp-complete--should-trigger-p))))
      (check "should-trigger (not self-insert)"
             (with-temp-buffer
               (c++-mode)
               (insert "x")
               (let ((this-command 'next-line))
                 (not (gptel-cpp-complete--should-trigger-p)))))

      ;; --- Overlay ---
      (check "overlay show/active/text"
             (with-temp-buffer
               (insert "abc")
               (gptel-cpp-complete--show-overlay " = 42;")
               (and (gptel-cpp-complete--overlay-active-p)
                    (equal " = 42;" (gptel-cpp-complete--overlay-text)))))
      (check "overlay clear"
             (with-temp-buffer
               (insert "abc")
               (gptel-cpp-complete--show-overlay "xyz")
               (gptel-cpp-complete--clear-overlay)
               (not (gptel-cpp-complete--overlay-active-p))))
      (check "overlay accept"
             (with-temp-buffer
               (insert "fo")
               (gptel-cpp-complete--show-overlay "foo_bar")
               (gptel-cpp-complete--accept-overlay)
               (equal "foo_bar" (buffer-substring-no-properties 1 (point)))))
      (check "overlay accept-word"
             (with-temp-buffer
               (insert "x")
               (gptel-cpp-complete--show-overlay "hello + world")
               (gptel-cpp-complete-accept-word)
               (and (equal "xhello" (buffer-substring-no-properties 1 (point)))
                    (equal " + world" (gptel-cpp-complete--overlay-text)))))

      ;; --- Overlay persistence (post-command) ---
      (check "overlay persists on non-edit command"
             (with-temp-buffer
               (c++-mode)
               (insert "int x = ")
               (gptel-cpp-complete--show-overlay "42;")
               (let ((this-command 'next-line))
                 (gptel-cpp-complete--post-command))
               (gptel-cpp-complete--overlay-active-p)))
      (check "overlay clears on buffer modification"
             (with-temp-buffer
               (c++-mode)
               (insert "int x = ")
               (gptel-cpp-complete--show-overlay "42;")
               (delete-char -1)
               (let ((this-command 'delete-backward-char))
                 (gptel-cpp-complete--post-command))
               (not (gptel-cpp-complete--overlay-active-p))))

      ;; --- Sequence / staleness ---
      (check "cancel bumps seq"
             (with-temp-buffer
               (c++-mode)
               (let ((old gptel-cpp-complete--request-seq))
                 (gptel-cpp-complete--cancel-request)
                 (> gptel-cpp-complete--request-seq old))))
      (check "stale response handler ignored"
             (with-temp-buffer
               (c++-mode)
               (insert "test")
               (let* ((buf (current-buffer))
                      (pos (point))
                      (seq gptel-cpp-complete--request-seq)
                      (handler (gptel-cpp-complete--make-response-handler buf pos seq)))
                 (cl-incf gptel-cpp-complete--request-seq)
                 (funcall handler "stale" nil)
                 (not (gptel-cpp-complete--overlay-active-p)))))
      (check "valid response handler shows overlay"
             (with-temp-buffer
               (c++-mode)
               (insert "test")
               (let* ((buf (current-buffer))
                      (pos (point))
                      (seq gptel-cpp-complete--request-seq)
                      (handler (gptel-cpp-complete--make-response-handler buf pos seq)))
                 (funcall handler "completion text" nil)
                 (equal "completion text" (gptel-cpp-complete--overlay-text)))))

      ;; --- Async grep ---
      (check "async grep with matches"
             (let ((done nil) (result nil))
               (with-temp-buffer
                 (c++-mode)
                 (gptel-cpp-complete--grep-search-async
                  (list "\\bmain\\s*\\(")
                  (current-buffer)
                  (lambda (r) (setq result r done t)))
                 (let ((deadline (+ (float-time) 5)))
                   (while (and (not done) (< (float-time) deadline))
                     (accept-process-output nil 0.05)
                     (sit-for 0.01))))
               (and done (> (length result) 0))))
      (check "async grep no matches"
             (let ((done nil) (result nil))
               (with-temp-buffer
                 (c++-mode)
                 (gptel-cpp-complete--grep-search-async
                  (list "\\bxyzzy_no_exist_999\\b")
                  (current-buffer)
                  (lambda (r) (setq result r done t)))
                 (let ((deadline (+ (float-time) 5)))
                   (while (and (not done) (< (float-time) deadline))
                     (accept-process-output nil 0.05)
                     (sit-for 0.01))))
               (and done (string-empty-p result))))
      (check "async grep empty patterns"
             (let ((done nil) (result nil))
               (with-temp-buffer
                 (c++-mode)
                 (gptel-cpp-complete--grep-search-async
                  nil
                  (current-buffer)
                  (lambda (r) (setq result r done t))))
               (and done (string-empty-p result))))
      (check "async grep cancel prevents callback"
             (let ((done nil))
               (with-temp-buffer
                 (c++-mode)
                 (gptel-cpp-complete--grep-search-async
                  (list "\\bmain\\s*\\(")
                  (current-buffer)
                  (lambda (_r) (setq done t)))
                 (gptel-cpp-complete--cancel-request)
                 (accept-process-output nil 1)
                 (sit-for 0.5))
               (not done)))

      ;; --- Symbol classification ---
      (check "classify-symbols"
             (let* ((syms (list '(:label "foo" :kind 3)
                                '(:label "x" :kind 6)
                                '(:label "m" :kind 5)))
                    (c (gptel-cpp-complete--classify-symbols syms)))
               (and (= 1 (length (plist-get c :funcs)))
                    (= 1 (length (plist-get c :vars)))
                    (= 1 (length (plist-get c :members))))))
      (check "grep-pattern-for-symbol function"
             (let ((pat (gptel-cpp-complete--grep-pattern-for-symbol
                         '(:label "doThing(int)" :kind 3))))
               (string-match-p "doThing" pat)))
      (check "grep-pattern-for-symbol field"
             (let ((pat (gptel-cpp-complete--grep-pattern-for-symbol
                         '(:label "myField" :kind 5))))
               (string-match-p "myField" pat)))

      ;; --- Summary ---
      (princ (format "\n%d passed, %d failed\n" pass fail))
      (when (> fail 0)
        (kill-emacs 1)))))

(provide 'gptel-cpp-complete-test)

;; Local Variables:
;; package-lint-main-file: "gptel-cpp-complete.el"
;; End:

;;; gptel-cpp-complete-test.el ends here
