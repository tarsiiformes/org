;;; ob-fortran.el --- Babel Functions for Fortran    -*- lexical-binding: t; -*-

;; Copyright (C) 2011-2025 Free Software Foundation, Inc.

;; Authors: Sergey Litvinov
;;       Eric Schulte
;; Maintainer: Ken Mankoff <km@kenmankoff.com>
;; Keywords: literate programming, reproducible research, fortran
;; URL: https://orgmode.org

;; This file is part of GNU Emacs.
;;
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

;; Org-Babel support for evaluating fortran code.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'ob)
(require 'org-macs)
(require 'cc-mode)
(require 'cl-lib)

(declare-function org-entry-get "org"
		  (pom property &optional inherit literal-nil))

(defvar org-babel-tangle-lang-exts)
(add-to-list 'org-babel-tangle-lang-exts '("fortran" . "F90"))

(defvar org-babel-default-header-args:fortran '())

(defcustom org-babel-fortran-compiler "gfortran"
  "Fortran command used to compile Fortran source code file."
  :group 'org-babel
  :package-version '(Org . "9.5")
  :type  'string)

(defun org-babel-execute:fortran (body params)
  "Execute Fortran BODY according to PARAMS.
This function is called by `org-babel-execute-src-block'."
  (let* ((tmp-src-file (org-babel-temp-file "fortran-src-" ".F90"))
         (tmp-bin-file (org-babel-temp-file "fortran-bin-" org-babel-exeext))
         (cmdline (cdr (assq :cmdline params)))
         (flags (cdr (assq :flags params)))
         (full-body (org-babel-expand-body:fortran body params)))
    (with-temp-file tmp-src-file (insert full-body))
    (org-babel-eval
     (format "%s -o %s %s %s"
	     org-babel-fortran-compiler
	     (org-babel-process-file-name tmp-bin-file)
	     (mapconcat 'identity
			(if (listp flags) flags (list flags)) " ")
	     (org-babel-process-file-name tmp-src-file)) "")
    (let ((results
           (org-trim
            (org-remove-indentation
	     (org-babel-eval
	      (concat tmp-bin-file (if cmdline (concat " " cmdline) "")) "")))))
      (org-babel-reassemble-table
       (org-babel-result-cond (cdr (assq :result-params params))
	 (org-babel-read results)
         (let ((tmp-file (org-babel-temp-file "f-")))
           (with-temp-file tmp-file (insert results))
           (org-babel-import-elisp-from-file tmp-file)))
       (org-babel-pick-name
        (cdr (assq :colname-names params)) (cdr (assq :colnames params)))
       (org-babel-pick-name
        (cdr (assq :rowname-names params)) (cdr (assq :rownames params)))))))

(defun org-babel-expand-body:fortran (body params)
  "Expand a fortran BODY according to its header arguments defined in PARAMS."
  (let ((vars (org-babel--get-vars params))
        (prologue (cdr (assq :prologue params)))
        (epilogue (cdr (assq :epilogue params)))
        (main-p (not (string= (cdr (assq :main params)) "no")))
        (includes (or (cdr (assq :includes params))
                      (org-babel-read (org-entry-get nil "includes" t))))
        (defines (org-babel-read
                  (or (cdr (assq :defines params))
                      (org-babel-read (org-entry-get nil "defines" t))))))
    (mapconcat 'identity
	       (list
		;; includes
		(mapconcat
		 (lambda (inc) (format "#include %s" inc))
		 (if (listp includes) includes (list includes)) "\n")
		;; defines
		(mapconcat
		 (lambda (inc) (format "#define %s" inc))
		 (if (listp defines) defines (list defines)) "\n")
		;; body
		(if main-p
		    (org-babel-fortran-ensure-main-wrap
		     (concat
		      ;; variables
		      (mapconcat 'org-babel-fortran-var-to-fortran vars "\n")
                      (and prologue (concat prologue "\n"))
		      body
                      (and prologue (concat prologue "\n")))
		     params)
                  (concat
                   (and prologue (concat prologue "\n"))
		   body
                   (and epilogue (concat "\n" epilogue "\n"))))
                "\n")
               "\n")))

(defun org-babel-fortran-ensure-main-wrap (body params)
  "Wrap BODY in a \"program ... end program\" block if none exists.
Variable assignments are derived from PARAMS."
  (if (string-match "^[ \t]*program\\>" (capitalize body))
      (let ((vars (org-babel--get-vars params)))
	(when vars (error "Cannot use :vars if `program' statement is present"))
	body)
    (format "program main\n%s\nend program main\n" body)))

(defun org-babel-prep-session:fortran (_session _params)
  "Do nothing.
This function does nothing as fortran is a compiled language with no
support for sessions."
  (error "Fortran is a compiled languages -- no support for sessions"))

(defun org-babel-load-session:fortran (_session _body _params)
  "Do nothing.
This function does nothing as fortran is a compiled language with no
support for sessions."
  (error "Fortran is a compiled languages -- no support for sessions"))

;; helper functions

(defun org-babel-fortran-var-to-fortran (pair)
  "Convert PAIR of (VAR . VAL) into a string of fortran code.
The fortran code will assign VAL to VAR variable."
  ;; TODO list support
  (let ((var (car pair))
        (val (cdr pair)))
    (when (symbolp val)
      (setq val (symbol-name val))
      (when (= (length val) 1)
        (setq val (string-to-char val))))
    (cond
     ((integerp val)
      (format "integer, parameter  ::  %S = %S\n" var val))
     ((floatp val)
      (format "real, parameter ::  %S = %S\n" var val))
     ((or (integerp val))
      (format "character, parameter :: %S = '%S'\n" var val))
     ((stringp val)
      (format "character(len=%d), parameter ::  %S = '%s'\n"
              (length val) var val))
     ;; val is a matrix
     ((and (listp val) (cl-every #'listp val))
      (format "real, parameter :: %S(%d,%d) = transpose( reshape( %s , (/ %d, %d /) ) )\n"
	      var (length val) (length (car val))
	      (org-babel-fortran-transform-list val)
	      (length (car val)) (length val)))
     ((listp val)
      (format "real, parameter :: %S(%d) = %s\n"
	      var (length val) (org-babel-fortran-transform-list val)))
     (t
      (error "The type of parameter %s is not supported by ob-fortran" var)))))

(defun org-babel-fortran-transform-list (val)
  "Return a fortran representation of enclose syntactic list VAL."
  (if (listp val)
      (concat "(/" (mapconcat #'org-babel-fortran-transform-list val ", ") "/)")
    (format "%S" val)))

(provide 'ob-fortran)

;;; ob-fortran.el ends here
