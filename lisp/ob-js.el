;;; ob-js.el --- Babel Functions for JavaScript      -*- lexical-binding: t; -*-

;; Copyright (C) 2010-2025 Free Software Foundation, Inc.

;; Author: Eric Schulte
;; Keywords: literate programming, reproducible research, js
;; URL: https://orgmode.org

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Now working with SBCL for both session and external evaluation.
;;
;; This certainly isn't optimally robust, but it seems to be working
;; for the basic use cases.

;;; Requirements:

;; - a non-browser javascript engine such as node.js https://nodejs.org/
;;   or mozrepl https://wiki.github.com/bard/mozrepl/
;;
;; - for session based evaluation mozrepl and moz.el are required see
;;   https://wiki.github.com/bard/mozrepl/emacs-integration for
;;   configuration instructions

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'ob)

(declare-function run-mozilla "ext:moz" (arg))
(declare-function httpd-start "ext:simple-httpd" ())
(declare-function run-skewer "ext:skewer-mode" ())
(declare-function skewer-repl "ext:skewer-repl" ())
(declare-function indium-run-node "ext:indium-nodejs" (command))
(declare-function indium-eval "ext:indium-interaction" (string &optional callback))

(defvar org-babel-default-header-args:js '()
  "Default header arguments for js code blocks.")

(defvar org-babel-js-eoe "org-babel-js-eoe"
  "String to indicate that evaluation has completed.")

(defcustom org-babel-js-cmd "node"
  "Name of command used to evaluate js blocks."
  :group 'org-babel
  :version "24.1"
  :type '(choice (const "node")
		 (const "mozrepl")
		 (const "skewer-mode")
		 (const "indium")
		 (const "js-comint"))
  :safe #'stringp)

(defvar org-babel-js-function-wrapper
  ;; Note that newline after %s - it makes sure that closing
  ;; parenthesis are not shadowed if the last line of the body is a
  ;; line comment.
  "require('process').stdout.write(require('util').inspect(function(){%s\n}()));"
  "JavaScript code to print value of body.")

(defun org-babel-execute:js (body params)
  "Execute JavaScript BODY according to PARAMS.
This function is called by `org-babel-execute-src-block'."
  (let* ((org-babel-js-cmd (or (cdr (assq :cmd params)) org-babel-js-cmd))
	 (session (cdr (assq :session params)))
         (result-type (cdr (assq :result-type params)))
         (full-body (org-babel-expand-body:generic
		     body params (org-babel-variable-assignments:js params)))
	 (result (cond
		  ;; no session specified, external evaluation
		  ((string= session "none")
		   (let ((script-file (org-babel-temp-file "js-script-")))
		     (with-temp-file script-file
		       (insert
			;; return the value or the output
			(if (string= result-type "value")
			    (format org-babel-js-function-wrapper full-body)
			  full-body)))
		     (org-babel-eval
		      (format "%s %s" org-babel-js-cmd
			      (org-babel-process-file-name script-file)) "")))
		  ;; Indium Node REPL.  Separate case because Indium
		  ;; REPL is not inherited from Comint mode.
		  ((string= session "*JS REPL*")
                   (org-require-package 'indium-repl "indium")
		   (unless (get-buffer session)
		     (indium-run-node org-babel-js-cmd))
		   (indium-eval full-body))
		  ;; session evaluation
		  (t
		   (let ((session (org-babel-prep-session:js
				   (cdr (assq :session params)) params)))
		     (nth 1
			  (org-babel-comint-with-output
			      (session (format "%S" org-babel-js-eoe) t body)
			    (dolist (code (list body (format "%S" org-babel-js-eoe)))
			      (insert (org-babel-chomp code))
			      (comint-send-input nil t)))))))))
    (org-babel-result-cond (cdr (assq :result-params params))
      result (org-babel-js-read result))))

(defun org-babel-js-read (results)
  "Convert RESULTS into an appropriate elisp value.
If RESULTS look like a table, then convert them into an
Emacs-lisp table, otherwise return the results as a string."
  (org-babel-read
   (if (and (stringp results)
	    (string-prefix-p "[" results)
	    (string-suffix-p "]" results))
       (org-babel-read
        (concat "'"
                (replace-regexp-in-string
                 "\\[" "(" (replace-regexp-in-string
                            "\\]" ")" (replace-regexp-in-string
                                       ",[[:space:]]" " "
				       (replace-regexp-in-string
					"'" "\"" results))))))
     results)))

(defun org-babel-js-var-to-js (var)
  "Convert VAR into a js variable.
Convert an elisp value into a string of js source code
specifying a variable of the same value."
  (if (listp var)
      (concat "[" (mapconcat #'org-babel-js-var-to-js var ", ") "]")
    (replace-regexp-in-string "\n" "\\\\n" (format "%S" var))))

(defun org-babel-prep-session:js (session params)
  "Prepare SESSION according to the header arguments specified in PARAMS."
  (let* ((session (org-babel-js-initiate-session session))
	 (var-lines (org-babel-variable-assignments:js params)))
    (when session
      (org-babel-comint-in-buffer session
	(goto-char (point-max))
	(dolist (var var-lines)
	  (insert var)
	  (comint-send-input nil t)
	  (org-babel-comint-wait-for-output session)
	  (sit-for .1)
	  (goto-char (point-max)))))
    session))

(defun org-babel-variable-assignments:js (params)
  "Return list of JavaScript statements assigning the block's variables.
The variables are defined in PARAMS."
  (mapcar
   (lambda (pair) (format "var %s=%s;"
			  (car pair) (org-babel-js-var-to-js (cdr pair))))
   (org-babel--get-vars params)))

(defun org-babel-js-initiate-session (&optional session _params)
  "If there is not a current inferior-process-buffer in `SESSION' then create.
Return the initialized session."
  (cond
   ((string= session "none")
    (warn "Session evaluation of ob-js is not supported"))
   ((string= "*skewer-repl*" session)
    (org-require-package 'skewer-repl "skewer-mode")
    (let ((session-buffer (get-buffer "*skewer-repl*")))
      (if (and session-buffer
	       (org-babel-comint-buffer-livep (get-buffer session-buffer))
	       (comint-check-proc session-buffer))
	  session-buffer
	;; start skewer REPL.
	(httpd-start)
	(run-skewer)
	(skewer-repl)
	session-buffer)))
   ;; SIC, JavaScript miscapitalized in `js-comint.el'.
   ((string= "*Javascript REPL*" session)
    (org-require-package 'js-comint)
    (let ((session-buffer "*Javascript REPL*"))
      (if (and (org-babel-comint-buffer-livep (get-buffer session-buffer))
	       (comint-check-proc session-buffer))
	  session-buffer
	(call-interactively 'run-js)
	(sit-for .5)
	session-buffer)))
   ((string= "mozrepl" org-babel-js-cmd)
    ;; FIXME: According to https://github.com/bard/mozrepl, this REPL
    ;; is outdated and does not work for Firefox >54.
    (org-require-package 'moz "mozrepl")
    (let ((session-buffer (save-window-excursion
			    (run-mozilla nil)
			    (rename-buffer session)
			    (current-buffer))))
      (if (org-babel-comint-buffer-livep session-buffer)
	  (progn (sit-for .25) session-buffer)
	(sit-for .5)
	(org-babel-js-initiate-session session))))
   ((string= "node" org-babel-js-cmd )
    (error "Session evaluation with node.js is not supported"))
   (t
    (error "Sessions are only supported with mozrepl add \":cmd mozrepl\""))))

(provide 'ob-js)

;;; ob-js.el ends here
