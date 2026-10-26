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

(defcustom nanishiteta-limit 7
  "Number of rows shown in each list before the rest is folded."
  :type 'natnum
  :group 'nanishiteta)

(defcustom nanishiteta-annotation-limit 3
  "Most commit subjects `nanishiteta-git-annotation' returns."
  :type 'natnum
  :group 'nanishiteta)

(defcustom nanishiteta-annotation-functions '(nanishiteta-git-annotation)
  "Functions that describe what happened in a directory.
Each is called with (DIRECTORY START-TIME END-TIME) and returns a
list of short strings, or nil.  Must not signal.  They are called
only for the directories shown."
  :type '(repeat function)
  :group 'nanishiteta)

(defcustom nanishiteta-sections
  '(nanishiteta-section-directories
    nanishiteta-section-files)
  "Functions that each insert one section of the nanishiteta buffer.
Each is called with no arguments and inserts its contents at point.
The heading, taken from the function's `nanishiteta-heading'
property, and the blank line before it are inserted by the caller.
The collected data is in `nanishiteta--data'."
  :type '(repeat function)
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

(defvar-local nanishiteta--data nil
  "The `nanishiteta-data' the buffer shows.")

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

;;;; Sorting

(defconst nanishiteta--sort-orders
  '((recent age-asc count-desc)
    (oldest age-desc count-desc)
    (most count-desc age-asc)
    (least count-asc age-asc)
    (gap gap-desc age-asc))
  "Sort orders cycled by `s', each (NAME FIRST-KEY SECOND-KEY).")

(defvar-local nanishiteta--sort 'recent
  "Name of the current sort order, from `nanishiteta--sort-orders'.")

(defun nanishiteta--sort-key (key entry)
  "Return the number KEY sorts ENTRY by, smaller first."
  (pcase key
    ('age-asc (nanishiteta-entry-age entry))
    ('age-desc (- (nanishiteta-entry-age entry)))
    ('count-asc (nanishiteta-entry-count entry))
    ('count-desc (- (nanishiteta-entry-count entry)))
    ('gap-desc (let ((gap (nanishiteta-entry-gap entry)))
                 (if gap (- gap) -1.0e+INF)))))

(defun nanishiteta--sort-entries (entries)
  "Return ENTRIES sorted by the current sort order.
Ties left by both keys are broken by path."
  (let ((keys (cdr (assq nanishiteta--sort nanishiteta--sort-orders))))
    (sort (copy-sequence entries)
          (lambda (a b)
            (cl-loop for key in keys
                     for ka = (nanishiteta--sort-key key a)
                     for kb = (nanishiteta--sort-key key b)
                     unless (= ka kb) return (< ka kb)
                     finally return (string< (nanishiteta-entry-path a)
                                             (nanishiteta-entry-path b)))))))

;;;; Annotations

(defun nanishiteta-git-annotation (directory start-time end-time)
  "Return subjects of commits in DIRECTORY between START-TIME and END-TIME.
At most `nanishiteta-annotation-limit' subjects are returned, newest
first.  Return nil if DIRECTORY is not in a git repository."
  (when (and (not (file-remote-p directory))
             (file-directory-p directory)
             (executable-find "git"))
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory))
            (coding-system-for-read 'utf-8)
            (process-environment (cons "GIT_OPTIONAL_LOCKS=0"
                                       process-environment)))
        (when (eq 0 (ignore-errors
                      (call-process
                       "git" nil '(t nil) nil
                       "-c" "log.showSignature=false" "log"
                       (format "--max-count=%d" nanishiteta-annotation-limit)
                       (concat "--since="
                               (format-time-string "%FT%T%z" start-time))
                       (concat "--until="
                               (format-time-string "%FT%T%z" end-time))
                       "--format=%s")))
          (split-string (buffer-string) "\n" t))))))

(defvar-local nanishiteta--annotations nil
  "Hash table of annotations already computed, keyed by directory.")

(defun nanishiteta--annotations (directory)
  "Return the strings `nanishiteta-annotation-functions' give DIRECTORY."
  (unless nanishiteta--annotations
    (setq nanishiteta--annotations (make-hash-table :test #'equal)))
  (let ((cached (gethash directory nanishiteta--annotations 'none)))
    (if (not (eq cached 'none))
        cached
      (puthash directory
               (cl-loop
                for function in nanishiteta-annotation-functions
                append (cl-remove-if-not
                        #'stringp
                        (condition-case nil
                            (funcall function directory
                                     (nanishiteta-data-start-time
                                      nanishiteta--data)
                                     (nanishiteta-data-end-time
                                      nanishiteta--data))
                          (error nil))))
               nanishiteta--annotations))))

;;;; Drawing

(defconst nanishiteta-buffer-name "*nanishiteta*"
  "Name of the buffer `nanishiteta' shows.")

(defvar-local nanishiteta--expanded nil
  "Sections currently shown without the row limit.")

(defvar-local nanishiteta--width 80
  "Window width the buffer was last drawn for.")

(defconst nanishiteta--glyphs
  '((top . "┌─") (branch . "├─") (last . "└─") (stem . "│")
    (bottom . "└─") (bullet . "●") (ellipsis . "…") (dot . "·"))
  "Characters used to draw the buffer.")

(defun nanishiteta--glyph (name)
  "Return the string drawn for NAME."
  (cdr (assq name nanishiteta--glyphs)))

(defun nanishiteta--rule (name)
  "Return the glyph NAME marked as a rule, left out when copying."
  (propertize (nanishiteta--glyph name) 'nanishiteta-rule t))

(defun nanishiteta--align (column)
  "Return a space that extends to COLUMN."
  (propertize " " 'display `(space :align-to ,column)))

(defun nanishiteta--right-column ()
  "Return the last column text may use."
  (1- (max 60 nanishiteta--width)))

(defun nanishiteta--count-end ()
  "Return the column the count column ends at."
  (- (nanishiteta--right-column) 12))

(defun nanishiteta--age-end ()
  "Return the column the age column ends at."
  (- (nanishiteta--count-end) 5))

(defun nanishiteta--truncate-left (string width)
  "Return STRING cut from the left to fit in WIDTH columns."
  (if (<= (string-width string) width)
      string
    (let ((ellipsis (nanishiteta--glyph 'ellipsis))
          (tail string))
      (while (and (> (length tail) 0)
                  (> (+ (string-width ellipsis) (string-width tail)) width))
        (setq tail (substring tail 1)))
      (concat ellipsis tail))))

(defun nanishiteta--format-age (entry)
  "Return the age column for ENTRY."
  (let ((age (nanishiteta-entry-age entry)))
    (cond ((null age) "")
          ((<= nanishiteta-span-days 1)
           (format-time-string "%H:%M" (nanishiteta-entry-last-time entry)))
          ((= age 0) "today")
          (t (format "%dd" age)))))

(defun nanishiteta--format-marker (entry)
  "Return the marker put before the path of ENTRY."
  (let ((gap (nanishiteta-entry-gap entry)))
    (cond ((null (nanishiteta-entry-age entry)) "")
          ((null gap) "+ ")
          ((> gap nanishiteta-span-days) (format "+%dd " gap))
          (t ""))))

(define-button-type 'nanishiteta-entry
  'action #'nanishiteta--open-button
  'follow-link t
  'face nil
  'help-echo "mouse-1, RET: open")

(define-button-type 'nanishiteta-toggle
  'action #'nanishiteta--toggle-button
  'follow-link t
  'face 'shadow
  'help-echo "mouse-1, RET: show all or fewer")

(defun nanishiteta--insert-annotations (entry last)
  "Insert the annotations of the directory ENTRY under its row.
LAST non-nil means the row ends its list."
  (let ((path (nanishiteta-entry-path entry))
        (prefix (concat " " (if last " " (nanishiteta--glyph 'stem)) "  ")))
    (dolist (note (nanishiteta--annotations path))
      (insert (propertize prefix 'nanishiteta-rule t)
              (propertize
               (truncate-string-to-width
                (concat (nanishiteta--glyph 'bullet) " " note)
                (- (nanishiteta--right-column) (string-width prefix))
                nil nil (nanishiteta--glyph 'ellipsis))
               'face 'shadow
               'nanishiteta-path path)
              "\n"))))

(defun nanishiteta--insert-entry (entry last &optional annotate)
  "Insert the row for ENTRY.  LAST non-nil means it ends its list.
ANNOTATE non-nil means insert the annotations of ENTRY below it."
  (let* ((prefix (concat " " (nanishiteta--glyph (if last 'last 'branch)) " "))
         (age (nanishiteta--format-age entry))
         (count (if (nanishiteta-entry-age entry)
                    (number-to-string (nanishiteta-entry-count entry))
                  ""))
         (by-hand (nanishiteta-entry-by-hand entry))
         (marker (nanishiteta--format-marker entry))
         (path (nanishiteta-entry-path entry))
         (room (- (nanishiteta--age-end) 6 (string-width prefix)
                  (string-width marker)))
         (start nil))
    (insert (propertize prefix 'nanishiteta-rule t))
    (setq start (point))
    (insert marker (nanishiteta--truncate-left (abbreviate-file-name path)
                                               room))
    (make-text-button start (point)
                      'type 'nanishiteta-entry
                      'nanishiteta-path path)
    (insert (nanishiteta--align (- (nanishiteta--age-end) (string-width age)))
            age
            (nanishiteta--align (- (nanishiteta--count-end)
                                   (string-width count)))
            count)
    (when (and by-hand (> by-hand 0))
      (insert (nanishiteta--align (+ (nanishiteta--count-end) 2))
              (format "%d by hand" by-hand)))
    (insert "\n")
    (when (and annotate (nanishiteta-entry-age entry))
      (nanishiteta--insert-annotations entry last))))

(defun nanishiteta--insert-toggle (section hidden)
  "Insert the row folding or unfolding SECTION.
HIDDEN is the number of rows folded away, or nil when unfolded."
  (insert (propertize (concat " " (nanishiteta--glyph 'last) " ")
                      'nanishiteta-rule t))
  (let ((start (point)))
    (insert (nanishiteta--glyph 'ellipsis)
            (if hidden (format " %d more" hidden) " less"))
    (make-text-button start (point)
                      'type 'nanishiteta-toggle
                      'nanishiteta-toggle section))
  (insert "\n"))

(defun nanishiteta--insert-entries (section entries &optional annotate)
  "Insert ENTRIES as the rows of SECTION, folded past `nanishiteta-limit'.
ANNOTATE non-nil means insert the annotations of each row shown."
  (let* ((sorted (nanishiteta--sort-entries entries))
         (total (length sorted))
         (foldable (> total nanishiteta-limit))
         (expanded (memq section nanishiteta--expanded))
         (shown (if (and foldable (not expanded))
                    (cl-subseq sorted 0 nanishiteta-limit)
                  sorted)))
    (if (null shown)
        (insert (propertize (concat " " (nanishiteta--glyph 'last) " ")
                            'nanishiteta-rule t)
                (propertize "nothing yet" 'face 'shadow) "\n")
      (cl-loop for (entry . rest) on shown
               do (nanishiteta--insert-entry entry
                                             (and (null rest) (not foldable))
                                             annotate))
      (when foldable
        (nanishiteta--insert-toggle
         section (and (not expanded) (- total nanishiteta-limit)))))))

(defun nanishiteta-section-directories ()
  "Insert the directories worked in."
  (nanishiteta--insert-entries 'directories
                               (nanishiteta-data-directories nanishiteta--data)
                               t))
(put 'nanishiteta-section-directories 'nanishiteta-heading "worked in")

(defun nanishiteta-section-files ()
  "Insert the files edited by hand."
  (nanishiteta--insert-entries 'files (nanishiteta-data-files nanishiteta--data)))
(put 'nanishiteta-section-files 'nanishiteta-heading "edited by hand")

(defun nanishiteta--header-label ()
  "Return the text at the right end of the first line."
  (format "last %d day%s %s %s"
          nanishiteta-span-days
          (if (= nanishiteta-span-days 1) "" "s")
          (nanishiteta--glyph 'dot)
          nanishiteta--sort))

(defun nanishiteta--insert-header ()
  "Insert the first line of the buffer."
  (let ((label (nanishiteta--header-label)))
    (insert (nanishiteta--rule 'top) " "
            (propertize "nanishiteta" 'face 'bold)
            (nanishiteta--align (- (nanishiteta--right-column)
                                   (string-width label)))
            label "\n")))

(defun nanishiteta--render ()
  "Draw the buffer from `nanishiteta--data', keeping point's line."
  (let* ((window (get-buffer-window (current-buffer)))
         (line (line-number-at-pos))
         (column (current-column))
         (inhibit-read-only t))
    (setq nanishiteta--width (if window (window-body-width window) 80))
    (erase-buffer)
    (nanishiteta--insert-header)
    (dolist (section nanishiteta-sections)
      (insert "\n")
      (let ((heading (and (symbolp section)
                          (get section 'nanishiteta-heading))))
        (when heading
          (insert " " (propertize heading 'face 'bold) "\n")))
      (funcall section))
    (insert (nanishiteta--rule 'bottom) "\n")
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (when window
      (set-window-point window (point)))))

(defun nanishiteta--visible-text (&optional drop)
  "Return the buffer text as it looks, with aligned spaces expanded.
Text whose property DROP is non-nil becomes spaces of equal width,
and lines holding nothing but such text are left out."
  (let ((lines nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((pos (point))
              (end (line-end-position))
              (column 0)
              (kept nil)
              (dropped nil)
              (out nil))
          (while (< pos end)
            (let* ((char (buffer-substring-no-properties pos (1+ pos)))
                   (display (get-text-property pos 'display))
                   (text (if (eq (car-safe display) 'space)
                             (make-string
                              (max 1 (- (plist-get (cdr display) :align-to)
                                        column))
                              ?\s)
                           char)))
              (if (and drop (get-text-property pos drop))
                  (setq text (make-string (string-width text) ?\s)
                        dropped t)
                (unless (string-blank-p text)
                  (setq kept t)))
              (push text out)
              (setq column (+ column (string-width text))
                    pos (1+ pos))))
          (when (or kept (not dropped))
            (push (string-trim-right (apply #'concat (nreverse out))) lines))
          (forward-line 1))))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun nanishiteta--on-resize (window)
  "Redraw the buffer of WINDOW if its width changed."
  (with-current-buffer (window-buffer window)
    (when (and (derived-mode-p 'nanishiteta-list-mode)
               nanishiteta--data
               (/= (window-body-width window) nanishiteta--width))
      (nanishiteta--render))))

;;;; Commands

(defun nanishiteta--line-button ()
  "Return the button on the current line, or nil."
  (let ((button (next-button (line-beginning-position) t)))
    (and button
         (<= (button-start button) (line-end-position))
         button)))

(defun nanishiteta--line-path ()
  "Return the path the current line is about, or nil."
  (let ((pos (line-beginning-position))
        (end (line-end-position))
        (path nil))
    (while (and (not path) (< pos end))
      (setq path (get-text-property pos 'nanishiteta-path)
            pos (1+ pos)))
    path))

(defun nanishiteta--visit (path)
  "Visit PATH, with Dired if it is a directory."
  (unless (file-exists-p path)
    (user-error "No longer exists: %s" path))
  (find-file path))

(defun nanishiteta--open-button (button)
  "Visit the path of BUTTON."
  (nanishiteta--visit (button-get button 'nanishiteta-path)))

(defun nanishiteta--toggle-button (button)
  "Fold or unfold the section of BUTTON."
  (let ((section (button-get button 'nanishiteta-toggle)))
    (setq nanishiteta--expanded
          (if (memq section nanishiteta--expanded)
              (remq section nanishiteta--expanded)
            (cons section nanishiteta--expanded)))
    (nanishiteta--render)
    (let ((pos (text-property-any (point-min) (point-max)
                                  'nanishiteta-toggle section)))
      (when pos
        (goto-char pos)))))

(defun nanishiteta-open ()
  "Open the file or directory on this line, or fold or unfold the list."
  (interactive)
  (let ((button (nanishiteta--line-button))
        (path (nanishiteta--line-path)))
    (cond (button (button-activate button))
          (path (nanishiteta--visit path))
          (t (user-error "Nothing to open on this line")))))

(defun nanishiteta-refresh ()
  "Read the log again and redraw."
  (interactive)
  (nanishiteta--load-exclude-file)
  (setq nanishiteta--data (nanishiteta--collect)
        nanishiteta--expanded nil
        nanishiteta--annotations nil)
  (nanishiteta--render))

(defun nanishiteta-cycle-sort ()
  "Sort by the next order: recent, oldest, most, least, gap."
  (interactive)
  (let ((names (mapcar #'car nanishiteta--sort-orders)))
    (setq nanishiteta--sort (or (cadr (memq nanishiteta--sort names))
                                (car names))
          nanishiteta--expanded nil))
  (nanishiteta--render))

(defconst nanishiteta--keys
  '(("n/p" "move" ("n" . next-line) ("p" . previous-line))
    ("RET" "open" ("RET" . nanishiteta-open))
    ("s" "sort" ("s" . nanishiteta-cycle-sort))
    ("g" "refresh" ("g" . nanishiteta-refresh))
    ("q" "quit" ("q" . quit-window))
    ("?" "help" ("?" . describe-mode)))
  "Keys of the nanishiteta buffer, as (LABEL DESCRIPTION (KEY . COMMAND)...).
Both the keymap and the key line at the bottom are made from this.")

(defvar nanishiteta-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-buffer-map)
    (dolist (group nanishiteta--keys)
      (dolist (binding (nthcdr 2 group))
        (define-key map (kbd (car binding)) (cdr binding))))
    map)
  "Keymap of `nanishiteta-list-mode'.")

(define-derived-mode nanishiteta-list-mode nil "Nanishiteta"
  "Major mode of the buffer showing what you were doing.

The upper list holds directories where terminals were started or
files changed from outside; the lower list holds files you visited
or saved.  The right columns are how many days ago each was last
touched, and how many events it had.

\\{nanishiteta-list-mode-map}"
  (setq buffer-read-only t
        truncate-lines t)
  (add-hook 'window-size-change-functions #'nanishiteta--on-resize nil t))

;;;###autoload
(defun nanishiteta ()
  "Show what you were doing over the last `nanishiteta-span-days' days."
  (interactive)
  (let ((buffer (get-buffer-create nanishiteta-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'nanishiteta-list-mode)
        (nanishiteta-list-mode))
      (nanishiteta--load-exclude-file)
      (setq nanishiteta--data (nanishiteta--collect)
            nanishiteta--expanded nil
            nanishiteta--annotations nil))
    (pop-to-buffer-same-window buffer)
    (nanishiteta--render)
    (goto-char (point-min))))

(provide 'nanishiteta)

;;; nanishiteta.el ends here
