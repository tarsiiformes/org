;;; org-mouse.el --- Better mouse support for Org -*- lexical-binding: t; -*-

;; Copyright (C) 2006-2025 Free Software Foundation, Inc.

;; Author: Piotr Zielinski <piotr dot zielinski at gmail dot com>
;; Maintainer: Carsten Dominik <carsten.dominik@gmail.com>

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
;;
;; Org-mouse provides mouse support for org-mode.
;;
;; https://orgmode.org
;;
;; Org mouse implements the following features:
;; * following links with the left mouse button
;; * subtree expansion/collapse (org-cycle) with the left mouse button
;; * several context menus on the right mouse button:
;;    + general text
;;    + headlines
;;    + timestamps
;;    + priorities
;;    + links
;;    + tags
;; * promoting/demoting/moving subtrees with mouse-3
;;    + if the drag starts and ends in the same line then promote/demote
;;    + otherwise move the subtree
;;
;; Use
;; ---
;;
;; To use this package, put the following line in your .emacs:
;;
;;    (require 'org-mouse)
;;

;; FIXME:
;; + deal with folding / unfolding issues

;; TODO (This list is only theoretical, if you'd like to have some
;; feature implemented or a bug fix please send me an email, even if
;; something similar appears in the list below.  This will help me get
;; the priorities right.):
;;
;; + org-store-link, insert link
;; + org tables
;; + occur with the current word/tag (same menu item)
;; + ctrl-c ctrl-c, for example, renumber the current list
;; + internal links

;; Please email the maintainer with new feature suggestions / bugs

;; History:
;;
;; Since version 5.10: Changes are listed in the general Org docs.
;;
;; Version 5.09;; + Version number synchronization with Org mode.
;;
;; Version 0.25
;; + made compatible with Org 4.70 (thanks to Carsten for the patch)
;;
;; Version 0.24
;; + minor changes to the table menu
;;
;; Version 0.23
;; + preliminary support for tables and calculation marks
;; + context menu support for org-agenda-undo & org-sort-entries
;;
;; Version 0.22
;; + handles undo support for the agenda buffer (requires Org >=4.58)
;;
;; Version 0.21
;; + selected text activates its context menu
;; + shift-middleclick or right-drag inserts the text from the clipboard in the form of a link
;;
;; Version 0.20
;; + the new "TODO Status" submenu replaces the "Cycle TODO" menu item
;; + the TODO menu can now list occurrences of a specific TODO keyword
;; + #+STARTUP line is now recognized
;;
;; Version 0.19
;; + added support for dragging URLs to the org-buffer
;;
;; Version 0.18
;; + added support for agenda blocks
;;
;; Version 0.17
;; + toggle checkboxes with a single click
;;
;; Version 0.16
;; + added support for checkboxes
;;
;; Version 0.15
;; + Org now works with the Agenda buffer as well
;;
;; Version 0.14
;; + added a menu option that converts plain list items to outline items
;;
;; Version 0.13
;; + "Insert Heading" now inserts a sibling heading if the point is
;;   on "***" and a child heading otherwise
;;
;; Version 0.12
;; + compatible with Emacs 21
;; + custom agenda commands added to the main menu
;; + moving trees should now work between windows in the same frame
;;
;; Version 0.11
;; + fixed org-mouse-at-link (thanks to Carsten)
;; + removed [follow-link] bindings
;;
;; Version 0.10
;; + added a menu option to remove highlights
;; + compatible with Org 4.21 now
;;
;; Version 0.08:
;; + trees can be moved/promoted/demoted by dragging with the right
;;   mouse button (mouse-3)
;; + small changes in the above function
;;
;; Versions 0.01 -- 0.07: (I don't remember)

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'org)
(require 'cl-lib)

(defvar org-agenda-allow-remote-undo)
(defvar org-agenda-undo-list)
(defvar org-agenda-custom-commands)
(declare-function org-agenda-change-all-lines "org-agenda"
		  (newhead hdmarker &optional fixface just-this))
(declare-function org-verify-change-for-undo "org-agenda" (l1 l2))
(declare-function org-apply-on-list "org-list" (function init-value &rest args))
(declare-function org-agenda-earlier "org-agenda" (arg))
(declare-function org-agenda-later "org-agenda" (arg))

(defvar org-mouse-main-buffer nil
  "Active buffer for mouse operations.")
(defvar org-mouse-plain-list-regexp "\\([ \t]*\\)\\([-+*]\\|[0-9]+[.)]\\) "
  "Regular expression that matches a plain list.")
(defvar org-mouse-direct t
  "Internal variable indicating whether the current action is direct.

If t, then the current action has been invoked directly through the buffer
it is intended to operate on.  If nil, then the action has been invoked
indirectly, for example, through the agenda buffer.")

(defgroup org-mouse nil
  "Mouse support for `org-mode'."
  :tag "Org Mouse"
  :group 'org)

(defcustom org-mouse-punctuation ":"
  "Punctuation used when inserting text by drag and drop."
  :type 'string)

(defcustom org-mouse-features
  '(context-menu yank-link activate-stars activate-bullets activate-checkboxes)
  "The features of org-mouse that should be activated.
Changing this variable requires a restart of Emacs to get activated."
  :type '(set :greedy t
	      (const :tag "Mouse-3 shows context menu" context-menu)
	      (const :tag "C-mouse-1 and mouse-3 move trees" move-tree)
	      (const :tag "S-mouse-2 and drag-mouse-3 yank link" yank-link)
	      (const :tag "Activate headline stars" activate-stars)
	      (const :tag "Activate item bullets" activate-bullets)
	      (const :tag "Activate checkboxes" activate-checkboxes)))

(defun org-mouse-re-search-line (regexp)
  "Search the current line for a given regular expression REGEXP."
  (forward-line 0)
  (re-search-forward regexp (line-end-position) t))

(defun org-mouse-end-headline ()
  "Go to the end of current headline (ignoring tags)."
  (interactive)
  (end-of-line)
  (skip-chars-backward "\t ")
  (when (looking-back ":[A-Za-z]+:" (line-beginning-position))
    (skip-chars-backward ":A-Za-z")
    (skip-chars-backward "\t ")))

(defvar-local org-mouse-context-menu-function nil
  "Function to create the context menu.
The value of this variable is the function invoked by
`org-mouse-context-menu' as the context menu.")

(defun org-mouse-show-context-menu (event prefix)
  "Invoke the context menu.

If the value of `org-mouse-context-menu-function' is a function, then
this function is called.  Otherwise, the current major mode menu is used."
  (interactive "@e \nP")
  (if (and (= (event-click-count event) 1)
	   (or (not mark-active)
               (sit-for
                (/ (if (fboundp 'mouse-double-click-time) ; Emacs >= 29
                       (mouse-double-click-time)
                     double-click-time)
                   1000.0))))
      (progn
	(select-window (posn-window (event-start event)))
	(when (not (org-mouse-mark-active))
	  (goto-char (posn-point (event-start event)))
	  (when (not (eolp)) (save-excursion (run-hooks 'post-command-hook)))
	  (sit-for 0))
	(if (functionp org-mouse-context-menu-function)
	    (funcall org-mouse-context-menu-function event)
          (popup-menu (mouse-menu-major-mode-map) event prefix)))
    (setq this-command 'mouse-save-then-kill)
    (mouse-save-then-kill event)))

(defun org-mouse-line-position ()
  "Return `:beginning' or `:middle' or `:end', depending on the point position.

If the point is at the end of the line, return `:end'.
If the point is separated from the beginning of the line only by white
space and *'s (`org-mouse-bolp'), return `:beginning'.  Otherwise,
return `:middle'."
  (cond
   ((eolp) :end)
   ((org-mouse-bolp) :beginning)
   (t :middle)))

(defun org-mouse-empty-line ()
  "Return non-nil if the line contains only white space."
  (save-excursion (forward-line 0) (looking-at "[ \t]*$")))

(defun org-mouse-next-heading ()
  "Go to the next heading.
If there is none, ensure that the point is at the beginning of an empty line."
  (unless (outline-next-heading)
    (forward-line 0)
    (unless (org-mouse-empty-line)
      (end-of-line)
      (newline))))

(defun org-mouse-insert-heading ()
  "Insert a new heading, as `org-insert-heading'.

If the point is at the :beginning (`org-mouse-line-position') of the line,
insert the new heading before the current line.  Otherwise, insert it
after the current heading."
  (interactive)
  (cl-case (org-mouse-line-position)
    (:beginning (forward-line 0)
		(org-insert-heading))
    (t (org-mouse-next-heading)
       (org-insert-heading))))

(defun org-mouse-timestamp-today (&optional shift units)
  "Change the timestamp into SHIFT UNITS in the future.

For the acceptable UNITS, see `org-timestamp-change'."
  (interactive)
  (org-timestamp nil)
  (when shift (org-timestamp-change shift units)))

(defun org-mouse-keyword-menu (keywords function &optional selected itemformat)
  "A helper function.

Returns a menu fragment consisting of KEYWORDS.  When a keyword
is selected by the user, FUNCTION is called with the selected
keyword as the only argument.

If SELECTED is nil, then all items are normal menu items.  If
SELECTED is a function, then each item is a checkbox, which is
enabled for a given keyword if (funcall SELECTED keyword) return
non-nil.  If SELECTED is neither nil nor a function, then the
items are radio buttons.  A radio button is enabled for the
keyword `equal' to SELECTED.

ITEMFORMAT governs formatting of the elements of KEYWORDS.  If it
is a function, it is invoked with the keyword as the only
argument.  If it is a string, it is interpreted as the format
string to (format ITEMFORMAT keyword).  If it is neither a string
nor a function, elements of KEYWORDS are used directly."
  (mapcar
   (lambda (keyword)
     (vector (cond
	      ((functionp itemformat) (funcall itemformat keyword))
	      ((stringp itemformat) (format itemformat keyword))
	      (t keyword))
	     `(funcall #',function ,keyword)
	     :style (cond
		     ((null selected) t)
		     ((functionp selected) 'toggle)
		     (t 'radio))
	     :selected (if (functionp selected)
			   (and (funcall selected keyword) t)
			 (equal selected keyword))))
   keywords))

(defun org-mouse-remove-match-and-spaces ()
  "Remove the match, make just one space around the point."
  (interactive)
  (replace-match "")
  (just-one-space))

(defvar org-mouse-rest)
(defun org-mouse-replace-match-and-surround
    (_newtext &optional _fixedcase _literal _string subexp)
  "The same as `replace-match', but surrounds the replacement with spaces."
  (apply #'replace-match org-mouse-rest)
  (save-excursion
    (goto-char (match-beginning (or subexp 0)))
    (just-one-space)
    (goto-char (match-end (or subexp 0)))
    (just-one-space)))

(defun org-mouse-keyword-replace-menu (keywords &optional group itemformat
						nosurround)
  "A helper function.

Returns a menu fragment consisting of KEYWORDS.  When a keyword
is selected, group GROUP of the current match is replaced by the
keyword.  The method ensures that both ends of the replacement
are separated from the rest of the text in the buffer by
individual spaces (unless NOSURROUND is non-nil).

The final entry of the menu is always \"None\", which removes the
match.

ITEMFORMAT governs formatting of the elements of KEYWORDS.  If it
is a function, it is invoked with the keyword as the only
argument.  If it is a string, it is interpreted as the format
string to (format ITEMFORMAT keyword).  If it is neither a string
nor a function, elements of KEYWORDS are used directly."
  (setq group (or group 0))
  (let ((replace (org-mouse-match-closure
		  (if nosurround #'replace-match
		    #'org-mouse-replace-match-and-surround))))
    (append
     (org-mouse-keyword-menu
      keywords
      (lambda (keyword) (funcall replace keyword t t nil group))
      (match-string group)
      itemformat)
     `(["None" org-mouse-remove-match-and-spaces
	:style radio
	:selected ,(not (member (match-string group) keywords))]))))

(defun org-mouse-show-headlines ()
  "Change the visibility of the current org buffer to only show headlines."
  (interactive)
  (let ((this-command 'org-cycle)
	(last-command 'org-cycle)
	(org-cycle-global-status nil))
    (org-cycle '(4))
    (org-cycle '(4))))

(defun org-mouse-show-overview ()
  "Change visibility of current org buffer to first-level headlines only."
  (interactive)
  (let ((org-cycle-global-status nil))
    (org-cycle '(4))))

(defun org-mouse-set-priority (priority)
  "Set the priority of the current headline to PRIORITY."
  (org-priority priority))

(defvar org-mouse-priority-regexp "\\[#\\([A-Z]\\)\\]"
  "Regular expression matching the priority indicator.
Differs from `org-priority-regexp' in that it doesn't contain the
leading `.*?'.")

(defun org-mouse-get-priority (&optional default)
  "Return the priority of the current headline.
DEFAULT is returned if no priority is given in the headline."
  (save-excursion
    (if (org-mouse-re-search-line org-mouse-priority-regexp)
	(match-string 1)
      (when default (char-to-string org-priority-default)))))

(defun org-mouse-delete-timestamp ()
  "Deletes the current timestamp as well as the preceding keyword.
SCHEDULED: or DEADLINE: or ANYTHINGLIKETHIS:"
  (when (or (org-at-date-range-p) (org-at-timestamp-p 'lax))
    (replace-match "")			;delete the timestamp
    (skip-chars-backward " :A-Z")
    (when (looking-at " *[A-Z][A-Z]+:")
      (replace-match ""))))

(defun org-mouse-looking-at (regexp skipchars &optional movechars)
  (save-excursion
    (let ((point (point)))
      (if (looking-at regexp) t
	(skip-chars-backward skipchars)
	(forward-char (or movechars 0))
	(when (looking-at regexp)
	  (> (match-end 0) point))))))

(defun org-mouse-priority-list ()
  (cl-loop for priority from ?A to org-priority-lowest
	   collect (char-to-string priority)))

(defun org-mouse-todo-menu (state)
  "Create the menu with TODO keywords."
  (append
   (let ((kwds org-todo-keywords-1))
     (org-mouse-keyword-menu
      kwds
      #'org-todo
      (lambda (kwd) (equal state kwd))))))

(defun org-mouse-tag-menu ()		;todo
  "Create the tags menu."
  (append
   (let ((tags (org-get-tags nil t)))
     (org-mouse-keyword-menu
      (sort (mapcar #'car (org-get-buffer-tags))
            (or org-tags-sort-function #'org-string<))
      (lambda (tag)
	(org-mouse-set-tags
	 (sort (if (member tag tags)
		   (delete tag tags)
		 (cons tag tags))
	       (or org-tags-sort-function #'org-string<))))
      (lambda (tag) (member tag tags))
      ))
   '("--"
     ["Align Tags Here" (org-align-tags) t]
     ["Align Tags in Buffer" (org-align-tags t) t]
     ["Set Tags ..." (org-set-tags-command) t])))

(defun org-mouse-set-tags (tags)
  (org-set-tags tags))

(defun org-mouse-insert-checkbox ()
  (interactive)
  (and (org-at-item-p)
       (goto-char (match-end 0))
       (unless (org-at-item-checkbox-p)
	 (delete-horizontal-space)
	 (insert " [ ] "))))

(defun org-mouse-agenda-type (type)
  (pcase type
    (`tags "Tags: ")
    (`todo "TODO: ")
    (`tags-tree "Tags tree: ")
    (`todo-tree "TODO tree: ")
    (`occur-tree "Occur tree: ")
    (_ "Agenda command ???")))

(defun org-mouse-list-options-menu (alloptions &optional function)
  (let ((options (save-match-data
		   (split-string (match-string-no-properties 1)))))
    (print options)
    (cl-loop for name in alloptions
	     collect
	     (vector name
		     `(progn
			(replace-match
			 (mapconcat 'identity
				    (sort (if (member ',name ',options)
					      (delete ',name ',options)
					    (cons ',name ',options))
					  #'org-string<)
				    " ")
			 nil nil nil 1)
			(when (functionp ',function) (funcall ',function)))
		     :style 'toggle
		     :selected (and (member name options) t)))))

(defun org-mouse-clip-text (text maxlength)
  (if (> (length text) maxlength)
      (concat (substring text 0 (- maxlength 3)) "...")
    text))

(defun org-mouse-popup-global-menu ()
  (popup-menu
   `("Main Menu"
     ["Show Overview" org-mouse-show-overview t]
     ["Show Headlines" org-mouse-show-headlines t]
     ["Show All" org-show-all t]
     ["Remove Highlights" org-remove-occur-highlights
      :visible org-occur-highlights]
     "--"
     ["Check Deadlines"
      (if (functionp 'org-check-deadlines-and-todos)
	  (org-check-deadlines-and-todos org-deadline-warning-days)
	(org-check-deadlines org-deadline-warning-days))
      t]
     ["Check TODOs" org-show-todo-tree t]
     ("Check Tags"
      ,@(org-mouse-keyword-menu
	 (sort (mapcar #'car (org-get-buffer-tags))
               (or org-tags-sort-function #'org-string<))
         (lambda (tag) (org-tags-sparse-tree nil tag)))
      "--"
      ["Custom Tag ..." org-tags-sparse-tree t])
     ["Check Phrase ..." org-occur]
     "--"
     ["Display Agenda" org-agenda-list t]
     ["Display TODO List" org-todo-list t]
     ("Display Tags"
      ,@(org-mouse-keyword-menu
	 (sort (mapcar #'car (org-get-buffer-tags))
               (or org-tags-sort-function #'org-string<))
         (lambda (tag) (org-tags-view nil tag)))
      "--"
      ["Custom Tag ..." org-tags-view t])
     ["Display Calendar" org-goto-calendar t]
     "--"
     ,@(org-mouse-keyword-menu
	(mapcar #'car org-agenda-custom-commands)
        (lambda (key)
	  (org-agenda nil (string-to-char key)))
	nil
        (lambda (key)
          (let ((entry (assoc key org-agenda-custom-commands)))
            (org-mouse-clip-text
             (cond
              ((stringp (nth 1 entry)) (nth 1 entry))
              ((stringp (nth 2 entry))
               (concat (org-mouse-agenda-type (nth 1 entry))
                       (nth 2 entry)))
              (t "Agenda Command `%s'"))
             30))))
     "--"
     ["Delete Blank Lines" delete-blank-lines
      :visible (org-mouse-empty-line)]
     ["Insert Checkbox" org-mouse-insert-checkbox
      :visible (and (org-at-item-p) (not (org-at-item-checkbox-p)))]
     ["Insert Checkboxes"
      (org-mouse-for-each-item 'org-mouse-insert-checkbox)
      :visible (and (org-at-item-p) (not (org-at-item-checkbox-p)))]
     ["Plain List to Outline" org-mouse-transform-to-outline
      :visible (org-at-item-p)])))

(defun org-mouse-get-context (contextlist context)
  (let ((contextdata (assq context contextlist)))
    (when contextdata
      (save-excursion
	(goto-char (nth 1 contextdata))
	(re-search-forward ".*" (nth 2 contextdata))))))

(defun org-mouse-for-each-item (funct)
  ;; Functions called by `org-apply-on-list' need an argument.
  (let ((wrap-fun (lambda (_) (funcall funct))))
    (when (ignore-errors (goto-char (org-in-item-p)))
      (save-excursion (org-apply-on-list wrap-fun nil)))))

(defun org-mouse-bolp ()
  "Return non-nil if there only spaces, tabs, and `*' before point.
This means, between the beginning of line and the point."
  (save-excursion
    (skip-chars-backward " \t*") (bolp)))

(defun org-mouse-insert-item (text)
  (cl-case (org-mouse-line-position)
    (:beginning				; insert before
     (forward-line 0)
     (looking-at "[ \t]*")
     (open-line 1)
     (indent-to-column (- (match-end 0) (match-beginning 0)))
     (insert "+ "))
    (:middle				; insert after
     (end-of-line)
     (newline t)
     (indent-relative)
     (insert "+ "))
    (:end				; insert text here
     (skip-chars-backward " \t")
     (kill-region (point) (line-end-position))
     (unless (looking-back org-mouse-punctuation (line-beginning-position))
       (insert (concat org-mouse-punctuation " ")))))
  (insert text)
  (forward-line 0))

(advice-add 'dnd-insert-text :around #'org--mouse-dnd-insert-text)
(defun org--mouse-dnd-insert-text (orig-fun window action text &rest args)
  (if (derived-mode-p 'org-mode)
      (org-mouse-insert-item text)
    (apply orig-fun window action text args)))

(advice-add 'dnd-open-file :around #'org--mouse-dnd-open-file)
(defun org--mouse-dnd-open-file (orig-fun uri &rest args)
  (if (derived-mode-p 'org-mode)
      (org-mouse-insert-item uri)
    (apply orig-fun uri args)))

(defun org-mouse-match-closure (function)
  (let ((match (match-data t)))
    (lambda (&rest rest)
      (save-match-data
	(set-match-data match)
	(apply function rest)))))

(defun org-mouse-yank-link (click)
  (interactive "e")
  ;; Give temporary modes such as isearch a chance to turn off.
  (run-hooks 'mouse-leave-buffer-hook)
  (mouse-set-point click)
  (setq mouse-selection-click-count 0)
  (delete-horizontal-space)
  (insert-for-yank (concat " [[" (current-kill 0) "]] ")))

(defun org-mouse-context-menu (&optional event)
  (let* ((stamp-prefixes (list org-deadline-string org-scheduled-string))
	 (contextlist (org-context))
	 (get-context (lambda (context) (org-mouse-get-context contextlist context))))
    (cond
     ((org-mouse-mark-active)
      (let ((region-string (buffer-substring (region-beginning) (region-end))))
	(popup-menu
	 `(nil
	   ["Sparse Tree" (org-occur ',region-string)]
	   ["Find in Buffer" (occur ',region-string)]
	   ["Grep in Current Dir"
	    (grep (format "grep -rnH -e '%s' ./*" ',region-string))]
	   ["Grep in Parent Dir"
	    (grep (format "grep -rnH -e '%s' ../*" ',region-string))]
	   "--"
	   ["Convert to Link"
	    (progn (save-excursion (goto-char (region-beginning)) (insert "[["))
		   (save-excursion (goto-char (region-end)) (insert "]]")))]
	   ["Insert Link Here" (org-mouse-yank-link ',event)]))))
     ((save-excursion (forward-line 0) (looking-at "[ \t]*#\\+STARTUP: \\(.*\\)"))
      (popup-menu
       `(nil
	 ,@(org-mouse-list-options-menu (mapcar #'car org-startup-options)
					'org-mode-restart))))
     ((or (eolp)
	  (and (looking-at "\\(  \\|\t\\)\\(\\+:[0-9a-zA-Z_:]+\\)?\\(  \\|\t\\)+$")
	       (looking-back "  \\|\t" (- (point) 2)
			     (line-beginning-position))))
      (org-mouse-popup-global-menu))
     ((funcall get-context :checkbox)
      (popup-menu
       '(nil
	 ["Toggle" org-toggle-checkbox t]
	 ["Remove" org-mouse-remove-match-and-spaces t]
	 ""
	 ["All Clear" (org-mouse-for-each-item
		       (lambda ()
			 (when (save-excursion (org-at-item-checkbox-p))
			   (replace-match "[ ] "))))]
	 ["All Set" (org-mouse-for-each-item
		     (lambda ()
		       (when (save-excursion (org-at-item-checkbox-p))
			 (replace-match "[X] "))))]
	 ["All Toggle" (org-mouse-for-each-item 'org-toggle-checkbox) t]
	 ["All Remove" (org-mouse-for-each-item
			(lambda ()
			  (when (save-excursion (org-at-item-checkbox-p))
			    (org-mouse-remove-match-and-spaces))))]
	 )))
     ((and (org-mouse-looking-at "\\b\\w+" "a-zA-Z0-9_")
	   (member (match-string 0) org-todo-keywords-1))
      (popup-menu
       `(nil
	 ,@(org-mouse-todo-menu (match-string 0))
	 "--"
	 ["Check TODOs" org-show-todo-tree t]
	 ["List all TODO keywords" org-todo-list t]
	 [,(format "List only %s" (match-string 0))
	  (org-todo-list (match-string 0)) t]
	 )))
     ((and (org-mouse-looking-at "\\b[A-Z]+:" "A-Z")
	   (member (match-string 0) stamp-prefixes))
      (popup-menu
       `(nil
	 ,@(org-mouse-keyword-replace-menu stamp-prefixes)
	 "--"
	 ["Check Deadlines" org-check-deadlines t]
	 )))
     ((org-mouse-looking-at org-mouse-priority-regexp "[]A-Z#") ; priority
      (popup-menu `(nil ,@(org-mouse-keyword-replace-menu
			   (org-mouse-priority-list) 1 "Priority %s" t))))
     ((funcall get-context :link)
      (popup-menu
       '(nil
	 ["Open" org-open-at-point t]
	 ["Open in Emacs" (org-open-at-point t) t]
	 "--"
	 ["Copy link" (org-kill-new (match-string 0))]
	 ["Cut link"
	  (progn
	    (kill-region (match-beginning 0) (match-end 0))
	    (just-one-space))]
	 "--"
	 ["Grep for TODOs"
	  (grep (format "grep -nH -i 'todo\\|fixme' %s*" (match-string 2)))]
					;       ["Paste file link" ((insert "file:") (yank))]
	 )))
     ((org-mouse-looking-at ":\\([A-Za-z0-9_]+\\):" "A-Za-z0-9_" -1) ;tags
      (popup-menu
       `(nil
	 [,(format-message "Display `%s'" (match-string 1))
	  (org-tags-view nil ,(match-string 1))]
	 [,(format-message "Sparse Tree `%s'" (match-string 1))
	  (org-tags-sparse-tree nil ,(match-string 1))]
	 "--"
	 ,@(org-mouse-tag-menu))))
     ((org-at-timestamp-p 'lax)
      (popup-menu
       '(nil
	 ["Show Day" org-open-at-point t]
	 ["Change Timestamp" org-timestamp t]
	 ["Delete Timestamp" (org-mouse-delete-timestamp) t]
	 ["Compute Time Range" org-evaluate-time-range (org-at-date-range-p)]
	 "--"
	 ["Set for Today" org-mouse-timestamp-today]
	 ["Set for Tomorrow" (org-mouse-timestamp-today 1 'day)]
	 ["Set in 1 Week" (org-mouse-timestamp-today 7 'day)]
	 ["Set in 2 Weeks" (org-mouse-timestamp-today 14 'day)]
	 ["Set in a Month" (org-mouse-timestamp-today 1 'month)]
	 "--"
	 ["+ 1 Day" (org-timestamp-change 1 'day)]
	 ["+ 1 Week" (org-timestamp-change 7 'day)]
	 ["+ 1 Month" (org-timestamp-change 1 'month)]
	 "--"
	 ["- 1 Day" (org-timestamp-change -1 'day)]
	 ["- 1 Week" (org-timestamp-change -7 'day)]
	 ["- 1 Month" (org-timestamp-change -1 'month)])))
     ((funcall get-context :table-special)
      (let ((mdata (match-data)))
	(cl-incf (car mdata) 2)
	(store-match-data mdata))
      (message "match: %S" (match-string 0))
      (popup-menu `(nil ,@(org-mouse-keyword-replace-menu
			   '(" " "!" "^" "_" "$" "#" "*" "'") 0
			   (lambda (mark)
			     (cl-case (string-to-char mark)
			       (?  "( ) Nothing Special")
			       (?! "(!) Column Names")
			       (?^ "(^) Field Names Above")
			       (?_ "(^) Field Names Below")
			       (?$ "($) Formula Parameters")
			       (?# "(#) Recalculation: Auto")
			       (?* "(*) Recalculation: Manual")
			       (?' "(') Recalculation: None")))
			   t))))
     ((assq :table contextlist)
      (popup-menu
       '(nil
	 ["Align Table" org-ctrl-c-ctrl-c]
	 ["Blank Field" org-table-blank-field]
	 ["Edit Field" org-table-edit-field]
	 "--"
	 ("Column"
	  ["Move Column Left" org-metaleft]
	  ["Move Column Right" org-metaright]
	  ["Delete Column" org-shiftmetaleft]
	  ["Insert Column" org-shiftmetaright]
	  "--"
	  ["Enable Narrowing" (setq org-table-limit-column-width (not org-table-limit-column-width)) :selected org-table-limit-column-width :style toggle])
	 ("Row"
	  ["Move Row Up" org-metaup]
	  ["Move Row Down" org-metadown]
	  ["Delete Row" org-shiftmetaup]
	  ["Insert Row" org-shiftmetadown]
	  ["Sort lines in region" org-table-sort-lines (org-at-table-p)]
	  "--"
	  ["Insert Hline" org-table-insert-hline])
	 ("Rectangle"
	  ["Copy Rectangle" org-copy-special]
	  ["Cut Rectangle" org-cut-special]
	  ["Paste Rectangle" org-paste-special]
	  ["Fill Rectangle" org-table-wrap-region])
	 "--"
	 ["Set Column Formula" org-table-eval-formula]
	 ["Set Field Formula" (org-table-eval-formula '(4))]
	 ["Edit Formulas" org-table-edit-formulas]
	 "--"
	 ["Recalculate Line" org-table-recalculate]
	 ["Recalculate All" (org-table-recalculate '(4))]
	 ["Iterate All" (org-table-recalculate '(16))]
	 "--"
	 ["Toggle Recalculate Mark" org-table-rotate-recalc-marks]
	 ["Sum Column/Rectangle" org-table-sum
	  :active (or (org-at-table-p) (org-region-active-p))]
	 ["Field Info" org-table-field-info]
	 ["Debug Formulas"
	  (setq org-table-formula-debug (not org-table-formula-debug))
	  :style toggle :selected org-table-formula-debug]
	 )))
     ((and (assq :headline contextlist) (not (eolp)))
      (let ((priority (org-mouse-get-priority t)))
	(popup-menu
	 `("Headline Menu"
	   ("Tags and Priorities"
	    ,@(org-mouse-keyword-menu
	       (org-mouse-priority-list)
               (lambda (keyword)
                 (org-mouse-set-priority (string-to-char keyword)))
	       priority "Priority %s")
	    "--"
	    ,@(org-mouse-tag-menu))
	   ("TODO Status"
	    ,@(org-mouse-todo-menu (org-get-todo-state)))
	   ["Show Tags"
	    (with-current-buffer org-mouse-main-buffer (org-agenda-show-tags))
	    :visible (not org-mouse-direct)]
	   ["Show Priority"
	    (with-current-buffer org-mouse-main-buffer (org-agenda-show-priority))
	    :visible (not org-mouse-direct)]
	   ,@(if org-mouse-direct '("--") nil)
	   ["New Heading" org-mouse-insert-heading :visible org-mouse-direct]
	   ["Set Deadline"
	    (progn (org-mouse-end-headline) (insert " ") (org-deadline))
	    :active (not (save-excursion
			   (org-mouse-re-search-line org-deadline-regexp)))]
	   ["Schedule Task"
	    (progn (org-mouse-end-headline) (insert " ") (org-schedule))
	    :active (not (save-excursion
			   (org-mouse-re-search-line org-scheduled-regexp)))]
	   ["Insert Timestamp"
	    (progn (org-mouse-end-headline) (insert " ") (org-timestamp nil)) t]
					;	 ["Timestamp (inactive)" org-timestamp-inactive t]
	   "--"
	   ["Archive Subtree" org-archive-subtree]
	   ["Cut Subtree"  org-cut-special]
	   ["Copy Subtree"  org-copy-special]
	   ["Paste Subtree"  org-paste-special :visible org-mouse-direct]
	   ("Sort Children"
	    ["Alphabetically" (org-sort-entries nil ?a)]
	    ["Numerically" (org-sort-entries nil ?n)]
	    ["By Time/Date" (org-sort-entries nil ?t)]
	    "--"
	    ["Reverse Alphabetically" (org-sort-entries nil ?A)]
	    ["Reverse Numerically" (org-sort-entries nil ?N)]
	    ["Reverse By Time/Date" (org-sort-entries nil ?T)])
	   "--"
	   ["Move Trees" org-mouse-move-tree :active nil]
	   ))))
     (t
      (org-mouse-popup-global-menu)))))

(defun org-mouse-mark-active ()
  (and mark-active transient-mark-mode))

(defun org-mouse-in-region-p (pos)
  (and (org-mouse-mark-active)
       (>= pos (region-beginning))
       (<  pos (region-end))))

(defun org-mouse-down-mouse (event)
  (interactive "e")
  (setq this-command last-command)
  (unless (and (= 1 (event-click-count event))
	       (org-mouse-in-region-p (posn-point (event-start event))))
    (mouse-drag-region event)))

;; This function conflicts with touch screen gestures as it relays
;; events to `mouse-drag-region'.
(put 'org-mouse-down-mouse 'ignored-mouse-command t)

(add-hook 'org-mode-hook
          (lambda ()
            (setq org-mouse-context-menu-function #'org-mouse-context-menu)

            (when (memq 'context-menu org-mouse-features)
              (org-defkey org-mouse-map [mouse-3] nil)
              (org-defkey org-mode-map [mouse-3] #'org-mouse-show-context-menu))
            (org-defkey org-mode-map [down-mouse-1] #'org-mouse-down-mouse)
            (when (memq 'context-menu org-mouse-features)
              (org-defkey org-mouse-map [C-drag-mouse-1] #'org-mouse-move-tree)
              (org-defkey org-mouse-map [C-down-mouse-1] #'org-mouse-move-tree-start))
            (when (memq 'yank-link org-mouse-features)
              (org-defkey org-mode-map [S-mouse-2] #'org-mouse-yank-link)
              (org-defkey org-mode-map [drag-mouse-3] #'org-mouse-yank-link))
            (when (memq 'move-tree org-mouse-features)
              (org-defkey org-mouse-map [drag-mouse-3] #'org-mouse-move-tree)
              (org-defkey org-mouse-map [down-mouse-3] #'org-mouse-move-tree-start))

            (when (memq 'activate-stars org-mouse-features)
              (font-lock-add-keywords
               nil
               `((,org-outline-regexp-bol
                  0 `(face org-link mouse-face highlight keymap ,org-mouse-map)
                  'prepend))
               t))

            (when (memq 'activate-bullets org-mouse-features)
              (font-lock-add-keywords
               nil
               `(("^[ \t]*\\([-+*]\\|[0-9]+[.)]\\) +"
                  (1 `(face org-link keymap ,org-mouse-map mouse-face highlight)
                     'prepend)))
               t))

            (when (memq 'activate-checkboxes org-mouse-features)
              (font-lock-add-keywords
               nil
               `(("^[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+\\(?:\\[@\\(?:start:\\)?[0-9]+\\][ \t]*\\)?\\(\\[[- X]\\]\\)"
                  (1 `(face nil keymap ,org-mouse-map mouse-face highlight) prepend)))
               t))

            (advice-add 'org-open-at-point :around #'org--mouse-open-at-point)))

(defun org--mouse-open-at-point (orig-fun &rest args)
  (let ((context (org-context)))
    (cond
     ((assq :headline-stars context) (org-cycle))
     ((assq :checkbox context) (org-toggle-checkbox))
     ((assq :item-bullet context)
      (let ((org-cycle-include-plain-lists t)) (org-cycle)))
     ((org-footnote-at-reference-p) nil)
     (t (apply orig-fun args)))))

(defun org-mouse-move-tree-start (_event)
  (interactive "e")
  (message "Same line: promote/demote, (***):move before, (text): make a child"))


(defun org-mouse-make-marker (position)
  (with-current-buffer (window-buffer (posn-window position))
    (copy-marker (posn-point position))))

(defun org-mouse-move-tree (event)
  ;; todo: handle movements between different buffers
  (interactive "e")
  (save-excursion
    (let* ((start (org-mouse-make-marker (event-start event)))
	   (end (org-mouse-make-marker (event-end event)))
	   (sbuf (marker-buffer start))
	   (ebuf (marker-buffer end)))

      (when (and sbuf ebuf)
	(set-buffer sbuf)
	(goto-char start)
	(org-back-to-heading)
	(if (and (eq sbuf ebuf)
		 (equal
		  (point)
		  (save-excursion (goto-char end) (org-back-to-heading) (point))))
	    ;; if the same line then promote/demote
	    (if (>= end start) (org-demote-subtree) (org-promote-subtree))
	  ;; if different lines then move
	  (org-cut-subtree)

	  (set-buffer ebuf)
	  (goto-char end)
	  (org-back-to-heading)
	  (when  (and (eq sbuf ebuf)
		      (equal
		       (point)
		       (save-excursion (goto-char start)
				       (org-back-to-heading) (point))))
	    (progn (org-end-of-subtree nil t)
		   (unless (eobp) (backward-char)))
	    (end-of-line)
	    (if (eobp) (newline) (forward-char)))

	  (when (looking-at org-outline-regexp)
	    (let ((level (- (match-end 0) (match-beginning 0))))
	      (when (> end (match-end 0))
		(progn (org-end-of-subtree nil t)
		       (unless (eobp) (backward-char)))
		(end-of-line)
		(if (eobp) (newline) (forward-char))
		(setq level (1+ level)))
	      (org-paste-subtree level)
	      (save-excursion
		(progn (org-end-of-subtree nil t)
		       (unless (eobp) (backward-char)))
		(when (bolp) (delete-char -1))))))))))


(defun org-mouse-transform-to-outline ()
  (interactive)
  (org-back-to-heading)
  (let ((minlevel 1000)
	(replace-text (concat (make-string (org-current-level) ?*) "* ")))
    (forward-line 1)
    (save-excursion
      (while (not (or (eobp) (looking-at org-outline-regexp)))
	(when (looking-at org-mouse-plain-list-regexp)
	  (setq minlevel (min minlevel (- (match-end 1) (match-beginning 1)))))
	(forward-line)))
    (while (not (or (eobp) (looking-at org-outline-regexp)))
      (when (and (looking-at org-mouse-plain-list-regexp)
		 (eq minlevel (- (match-end 1) (match-beginning 1))))
	(replace-match replace-text))
      (forward-line))))

(defvar org-mouse-cmd) ;dynamically scoped from `org-with-remote-undo'.

(defun org-mouse-do-remotely (command)
  ;;  (org-agenda-check-no-diary)
  (when (get-text-property (point) 'org-marker)
    (let* ((anticol (- (line-end-position) (point)))
	   (marker (get-text-property (point) 'org-marker))
	   (buffer (marker-buffer marker))
	   (pos (marker-position marker))
	   (hdmarker (get-text-property (point) 'org-hd-marker))
	   (buffer-read-only nil)
	   (newhead "--- removed ---")
	   (org-mouse-direct nil)
	   (org-mouse-main-buffer (current-buffer)))
      (when (eq (with-current-buffer buffer major-mode) 'org-mode)
	(let ((endmarker (with-current-buffer buffer
			   (org-end-of-subtree nil t)
			   (unless (eobp) (forward-char 1))
			   (point-marker))))
	  (org-with-remote-undo buffer
	    (with-current-buffer buffer
	      (widen)
	      (goto-char pos)
	      (org-fold-show-hidden-entry)
	      (save-excursion
		(and (outline-next-heading)
		     (org-fold-heading nil)))   ; show the next heading
	      (org-back-to-heading)
	      (setq marker (point-marker))
              (goto-char (max (line-beginning-position) (- (line-end-position) anticol)))
	      (funcall command)
	      (message "_cmd: %S" org-mouse-cmd)
	      (message "this-command: %S" this-command)
	      (unless (eq (marker-position marker) (marker-position endmarker))
		(setq newhead (org-get-heading))))

	    (forward-line 1)
	    (save-excursion
	      (org-agenda-change-all-lines newhead hdmarker 'fixface))))
	t))))

(defun org-mouse-agenda-context-menu (&optional _event)
  (or (org-mouse-do-remotely 'org-mouse-context-menu)
      (popup-menu
       '("Agenda"
	 ("Agenda Files")
	 "--"
	 ["Undo" (progn (message "last command: %S" last-command) (setq this-command 'org-agenda-undo) (org-agenda-undo))
	  :visible (if (eq last-command 'org-agenda-undo)
		       org-agenda-pending-undo-list
		     org-agenda-undo-list)]
	 ["Rebuild Buffer" org-agenda-redo t]
	 ["New Diary Entry"
	  org-agenda-diary-entry (org-agenda-check-type nil 'agenda) t]
	 "--"
	 ["Goto Today" org-agenda-goto-today
	  (org-agenda-check-type nil 'agenda) t]
	 ["Display Calendar" org-agenda-goto-calendar
	  (org-agenda-check-type nil 'agenda) t]
	 ("Calendar Commands"
	  ["Phases of the Moon" org-agenda-phases-of-moon
	   (org-agenda-check-type nil 'agenda)]
	  ["Sunrise/Sunset" org-agenda-sunrise-sunset
	   (org-agenda-check-type nil 'agenda)]
	  ["Holidays" org-agenda-holidays
	   (org-agenda-check-type nil 'agenda)]
	  ["Convert" org-agenda-convert-date
	   (org-agenda-check-type nil 'agenda)]
	  "--"
	  ["Create iCalendar file" org-icalendar-combine-agenda-files t])
	 "--"
	 ["Day View" org-agenda-day-view
	  :active (org-agenda-check-type nil 'agenda)
	  :style radio :selected (eq org-agenda-current-span 'day)]
	 ["Week View" org-agenda-week-view
	  :active (org-agenda-check-type nil 'agenda)
	  :style radio :selected (eq org-agenda-current-span 'week)]
	 "--"
	 ["Show Logbook entries" org-agenda-log-mode
	  :style toggle :selected org-agenda-show-log
	  :active (org-agenda-check-type nil 'agenda)]
	 ["Include Diary" org-agenda-toggle-diary
	  :style toggle :selected org-agenda-include-diary
	  :active (org-agenda-check-type nil 'agenda)]
	 ["Use Time Grid" org-agenda-toggle-time-grid
	  :style toggle :selected org-agenda-use-time-grid
	  :active (org-agenda-check-type nil 'agenda)]
	 ["Follow Mode" org-agenda-follow-mode
	  :style toggle :selected org-agenda-follow-mode]
	 "--"
	 ["Quit" org-agenda-quit t]
	 ["Exit and Release Buffers" org-agenda-exit t]
	 ))))

(defun org-mouse-get-gesture (event)
  (let ((startxy (posn-x-y (event-start event)))
	(endxy (posn-x-y (event-end event))))
    (if (< (car startxy) (car endxy)) :right :left)))


					; (setq org-agenda-mode-hook nil)
(defvar org-agenda-mode-map)
(add-hook 'org-agenda-mode-hook
	  (lambda ()
	    (setq org-mouse-context-menu-function #'org-mouse-agenda-context-menu)
	    (org-defkey org-agenda-mode-map [mouse-3] #'org-mouse-show-context-menu)
	    (org-defkey org-agenda-mode-map [down-mouse-3] #'org-mouse-move-tree-start)
	    (org-defkey org-agenda-mode-map [C-mouse-4] #'org-agenda-earlier)
	    (org-defkey org-agenda-mode-map [C-mouse-5] #'org-agenda-later)
	    (org-defkey org-agenda-mode-map [drag-mouse-3]
			(lambda (event) (interactive "e")
			  (cl-case (org-mouse-get-gesture event)
			    (:left (org-agenda-earlier 1))
			    (:right (org-agenda-later 1)))))))

(provide 'org-mouse)

;;; org-mouse.el ends here
