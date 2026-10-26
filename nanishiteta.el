;;; nanishiteta.el --- What was I doing? -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `M-x nanishiteta' shows one buffer listing the directories you
;; worked in and the files you edited by hand over the last few days.
;;
;; Turn on `nanishiteta-mode' to start recording.  Recording appends
;; one line per hook run to `nanishiteta-log-file' and does nothing
;; else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup nanishiteta nil
  "Remember what you were doing."
  :group 'convenience
  :prefix "nanishiteta-")

(defcustom nanishiteta-log-file
  (expand-file-name "nanishiteta.log" user-emacs-directory)
  "File that recorded events are appended to.
Emacs only ever appends to this file."
  :type 'file
  :group 'nanishiteta)

(defcustom nanishiteta-exclude-file
  (expand-file-name "nanishiteta-exclude" user-emacs-directory)
  "File holding extra exclusion regexps, one per line.
The `x' command appends to it.  Its regexps are used together
with `nanishiteta-exclude-regexps'."
  :type 'file
  :group 'nanishiteta)

(defcustom nanishiteta-exclude-regexps
  '("authinfo"
    "\\.gpg\\'"
    "/\\.git/"
    "COMMIT_EDITMSG"
    "\\`/tmp/"
    "recentf"
    "savehist"
    "nanishiteta\\.log\\'"
    "nanishiteta-exclude\\'")
  "Regexps of paths that are never recorded nor shown.
These are used together with the lines of `nanishiteta-exclude-file'."
  :type '(repeat regexp)
  :group 'nanishiteta)

;;;; Recording

(defconst nanishiteta--hooks
  '((find-file-hook . nanishiteta--record-visit)
    (after-save-hook . nanishiteta--record-save)
    (after-revert-hook . nanishiteta--record-revert)
    (eat-mode-hook . nanishiteta--record-term)
    (vterm-mode-hook . nanishiteta--record-term)
    (eshell-mode-hook . nanishiteta--record-term)
    (shell-mode-hook . nanishiteta--record-term)
    (term-mode-hook . nanishiteta--record-term))
  "Hooks used for recording, and the function each one runs.")

(defvar nanishiteta--exclude-file-regexps nil
  "Regexps read from `nanishiteta-exclude-file'.")

(defun nanishiteta--load-exclude-file ()
  "Read `nanishiteta-exclude-file' into `nanishiteta--exclude-file-regexps'.
A missing file counts as empty."
  (setq nanishiteta--exclude-file-regexps
        (when (file-readable-p nanishiteta-exclude-file)
          (with-temp-buffer
            (let ((coding-system-for-read 'utf-8))
              (insert-file-contents nanishiteta-exclude-file))
            (cl-remove-if #'string-empty-p
                          (split-string (buffer-string) "\n"))))))

(defun nanishiteta--excluded-p (path)
  "Return non-nil if PATH must not be recorded or shown."
  (or (file-remote-p path)
      (cl-some (lambda (re) (string-match-p re path))
               (append nanishiteta-exclude-regexps
                       nanishiteta--exclude-file-regexps))))

(defun nanishiteta--record (kind path)
  "Append one line saying that KIND happened on PATH."
  (when (and path
             (not (string-match-p "[\t\n]" path))
             (not (nanishiteta--excluded-p path)))
    (with-demoted-errors "nanishiteta: %S"
      (let ((coding-system-for-write 'utf-8-unix)
            (create-lockfiles nil)
            (write-region-inhibit-fsync t))
        (write-region (format "%s\t%s\t%s\n"
                              (format-time-string "%FT%T%z")
                              kind path)
                      nil nanishiteta-log-file t 'silent)))))

(defun nanishiteta--record-visit ()
  "Record that the current file was visited."
  (nanishiteta--record "visit" buffer-file-name))

(defun nanishiteta--record-save ()
  "Record that the current file was saved."
  (nanishiteta--record "save" buffer-file-name))

(defun nanishiteta--record-revert ()
  "Record that the current file was reverted."
  (nanishiteta--record "revert" buffer-file-name))

(defun nanishiteta--record-term ()
  "Record that a terminal was started in the current directory."
  (nanishiteta--record "term" (expand-file-name default-directory)))

;;;###autoload
(define-minor-mode nanishiteta-mode
  "Record visited, saved and reverted files and started terminals.
Each event appends one line to `nanishiteta-log-file'.  Turning the
mode off removes the hooks and stops all recording."
  :global t
  :group 'nanishiteta
  (dolist (hook nanishiteta--hooks)
    (if nanishiteta-mode
        (add-hook (car hook) (cdr hook))
      (remove-hook (car hook) (cdr hook))))
  (when nanishiteta-mode
    (nanishiteta--load-exclude-file)))

(provide 'nanishiteta)

;;; nanishiteta.el ends here
