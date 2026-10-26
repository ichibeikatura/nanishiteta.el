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
(require 'time-date)

(declare-function project-root "project" (project))
(declare-function project-roots "project" (project))
(declare-function vc-responsible-backend "vc" (file &optional no-error))
(declare-function vc-call-backend "vc-hooks" (backend function-name &rest args))

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

(defcustom nanishiteta-span-days 7
  "Number of days to look back, counting today."
  :type 'natnum
  :group 'nanishiteta)

(defcustom nanishiteta-gap-lookback-days 90
  "How many days before the span to search for earlier visits.
Paths not seen within this many days before the span have an
unknown gap."
  :type 'natnum
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

;;;; Reading

(defconst nanishiteta--kind-systems
  '(("visit" . files)
    ("save" . files)
    ("term" . directories)
    ("revert" . directories))
  "Which list each known kind of event belongs to.
Kinds missing here are skipped when reading.")

(cl-defstruct (nanishiteta-entry
               (:constructor nanishiteta-entry-create)
               (:copier nil))
  "One row of the list."
  path age last-time (count 0) gap by-hand first-day)

(cl-defstruct (nanishiteta-data
               (:constructor nanishiteta-data-create)
               (:copier nil))
  "Everything the buffer shows, as collected from the log."
  directories files hours days start-time end-time approx)

(defvar nanishiteta--lines-read 0
  "Number of log lines read by the last `nanishiteta--collect'.")

(defconst nanishiteta--time-regexp
  (concat "\\`\\([0-9]\\{4\\}\\)-\\([0-9][0-9]\\)-\\([0-9][0-9]\\)"
          "T\\([0-9][0-9]\\):\\([0-9][0-9]\\):\\([0-9][0-9]\\)"
          "\\(?:Z\\|\\([+-]\\)\\([0-9][0-9]\\):?\\([0-9][0-9]\\)\\)\\'")
  "Regexp matching the timestamps written to the log.")

(defun nanishiteta--parse-time (string)
  "Return the time STRING denotes, or nil if it is malformed."
  (when (string-match nanishiteta--time-regexp string)
    (let ((field (lambda (n) (string-to-number (match-string n string)))))
      (encode-time
       (list (funcall field 6) (funcall field 5) (funcall field 4)
             (funcall field 3) (funcall field 2) (funcall field 1)
             nil nil
             (if (match-beginning 7)
                 (* (if (equal (match-string 7 string) "-") -1 1)
                    (+ (* 3600 (funcall field 8)) (* 60 (funcall field 9))))
               0))))))

(defun nanishiteta--parse-line (line)
  "Return (TIME KIND PATH) for LINE, or nil if LINE is to be skipped.
Fields after the third are ignored, as are unknown kinds."
  (let ((fields (split-string line "\t")))
    (when (>= (length fields) 3)
      (let ((time (nanishiteta--parse-time (nth 0 fields)))
            (kind (nth 1 fields))
            (path (nth 2 fields)))
        (when (and time
                   (assoc kind nanishiteta--kind-systems)
                   (file-name-absolute-p path)
                   (not (nanishiteta--excluded-p path)))
          (list time kind path))))))

(defun nanishiteta--map-lines-backward (file function)
  "Call FUNCTION on each line of FILE, from the last line to the first.
Stop as soon as FUNCTION returns non-nil."
  (let ((pos (file-attribute-size (file-attributes file)))
        (carry "")
        (done nil))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (while (and (not done) (> pos 0))
        (let ((beg (max 0 (- pos 65536))))
          (erase-buffer)
          (insert-file-contents-literally file nil beg pos)
          (goto-char (point-max))
          (insert carry)
          (setq pos beg)
          (let ((end (point-max)))
            (while (and (not done) end)
              (goto-char end)
              (if (search-backward "\n" nil t)
                  (let ((line (buffer-substring (1+ (point)) end)))
                    (setq end (point))
                    (unless (string-empty-p line)
                      (setq done (funcall function
                                          (decode-coding-string line 'utf-8)))))
                (if (> beg 0)
                    (setq carry (buffer-substring (point-min) end))
                  (let ((line (buffer-substring (point-min) end)))
                    (unless (string-empty-p line)
                      (setq done (funcall function
                                          (decode-coding-string line 'utf-8))))))
                (setq end nil)))))))))

(defun nanishiteta--top-directory-p (dir)
  "Return non-nil if DIR is the home directory or a root directory."
  (or (string= dir (file-name-as-directory (expand-file-name "~")))
      (string= dir (file-name-directory (directory-file-name dir)))))

(defun nanishiteta--project-root (dir)
  "Return the root of the project DIR belongs to, or nil."
  (ignore-errors
    (let ((project (project-current nil dir)))
      (when project
        (if (fboundp 'project-root)
            (project-root project)
          (with-no-warnings (car (project-roots project))))))))

(defun nanishiteta--vc-root (dir)
  "Return the root of the version-controlled tree holding DIR, or nil."
  (ignore-errors
    (let ((backend (vc-responsible-backend dir t)))
      (when backend
        (vc-call-backend backend 'root dir)))))

(defun nanishiteta--normalize-directory (dir)
  "Return the directory that events in DIR are counted under.
That is the project root, else the version control root, else DIR
itself.  The home directory and root directories are never used."
  (or (cl-loop for root in (list (nanishiteta--project-root dir)
                                 (nanishiteta--vc-root dir))
               for expanded = (and root (file-name-as-directory
                                         (expand-file-name root)))
               when (and expanded
                         (not (nanishiteta--top-directory-p expanded)))
               return expanded)
      dir))

(defun nanishiteta--event-key (kind path cache)
  "Return (SYSTEM . KEY) for an event of KIND on PATH.
CACHE is a hash table remembering normalized directories."
  (let ((system (cdr (assoc kind nanishiteta--kind-systems))))
    (cons system
          (if (eq system 'files)
              path
            (let ((dir (file-name-as-directory
                        (if (equal kind "revert")
                            (file-name-directory path)
                          path))))
              (or (gethash dir cache)
                  (puthash dir (nanishiteta--normalize-directory dir)
                           cache)))))))

(defun nanishiteta--day-start (time days-back)
  "Return local midnight DAYS-BACK days before the day of TIME."
  (let ((decoded (decode-time time)))
    (encode-time (list 0 0 0
                       (- (nth 3 decoded) days-back)
                       (nth 4 decoded) (nth 5 decoded)
                       nil -1 nil))))

(defun nanishiteta--count-by-hand (directories files)
  "Set the `by-hand' slot of each of DIRECTORIES from FILES."
  (dolist (dir directories)
    (setf (nanishiteta-entry-by-hand dir)
          (cl-count-if (lambda (file)
                         (string-prefix-p (nanishiteta-entry-path dir)
                                          (nanishiteta-entry-path file)))
                       files))))

(defun nanishiteta--collect (&optional now)
  "Read the log and return a `nanishiteta-data' for the span ending at NOW.
NOW defaults to the current time.  The log is read from its end
and reading stops once the earlier visits of every path in the
span are found, or `nanishiteta-gap-lookback-days' are exhausted."
  (let* ((now (or now (current-time)))
         (span (max 1 nanishiteta-span-days))
         (today (time-to-days now))
         (start-day (- today (1- span)))
         (stop-day (- start-day nanishiteta-gap-lookback-days))
         (tables (list (cons 'directories (make-hash-table :test #'equal))
                       (cons 'files (make-hash-table :test #'equal))))
         (hours (make-vector 24 0))
         (days (make-vector span 0))
         (cache (make-hash-table :test #'equal))
         (pending nil))
    (setq nanishiteta--lines-read 0)
    (when (file-readable-p nanishiteta-log-file)
      (nanishiteta--map-lines-backward
       nanishiteta-log-file
       (lambda (line)
         (cl-incf nanishiteta--lines-read)
         (let* ((event (nanishiteta--parse-line line))
                (time (car event))
                (day (and event (time-to-days time))))
           (cond
            ((null event) nil)
            ((and (not pending) (>= day start-day))
             (let* ((key (nanishiteta--event-key (nth 1 event) (nth 2 event)
                                                 cache))
                    (table (cdr (assq (car key) tables)))
                    (entry (or (gethash (cdr key) table)
                               (puthash (cdr key)
                                        (nanishiteta-entry-create
                                         :path (cdr key)
                                         :age (max 0 (- today day))
                                         :last-time time)
                                        table))))
               (cl-incf (nanishiteta-entry-count entry))
               (setf (nanishiteta-entry-first-day entry) day)
               (cl-incf (aref hours (nth 2 (decode-time time))))
               (cl-incf (aref days (min (1- span) (- day start-day))))
               nil))
            (t
             (unless pending
               (setq pending (make-hash-table :test #'equal))
               (dolist (table tables)
                 (maphash (lambda (key _)
                            (puthash (cons (car table) key) t pending))
                          (cdr table))))
             (cond
              ((< day stop-day) t)
              ((>= day start-day) nil)
              (t
               (let ((key (nanishiteta--event-key (nth 1 event) (nth 2 event)
                                                  cache)))
                 (when (gethash key pending)
                   (remhash key pending)
                   (let ((entry (gethash (cdr key)
                                         (cdr (assq (car key) tables)))))
                     (setf (nanishiteta-entry-gap entry)
                           (- (nanishiteta-entry-first-day entry) day)))))
               (zerop (hash-table-count pending))))))))))
    (let ((directories (hash-table-values (cdr (assq 'directories tables))))
          (files (hash-table-values (cdr (assq 'files tables)))))
      (nanishiteta--count-by-hand directories files)
      (nanishiteta-data-create
       :directories directories
       :files files
       :hours hours
       :days days
       :start-time (nanishiteta--day-start now (1- span))
       :end-time now))))

(provide 'nanishiteta)

;;; nanishiteta.el ends here
