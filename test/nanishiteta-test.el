;;; nanishiteta-test.el --- Tests for nanishiteta -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/nanishiteta-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nanishiteta)

(defconst nanishiteta-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this file.")

(defconst nanishiteta-test-tmp-dir
  (expand-file-name "tmp/" nanishiteta-test-dir)
  "Scratch directory for files written by the tests.")

;; Every fixture uses +0900, so read them in the same zone.
(set-time-zone-rule "JST-9")

;; Fixture paths do not exist; looking for their project roots only
;; costs time.  `nanishiteta-test-normalize' covers the real lookup.
(advice-add 'nanishiteta--project-root :around
            (lambda (orig dir)
              (unless (string-prefix-p "/home/user/" dir) (funcall orig dir))))
(advice-add 'nanishiteta--vc-root :around
            (lambda (orig dir)
              (unless (string-prefix-p "/home/user/" dir) (funcall orig dir))))

(defmacro nanishiteta-test-with-files (&rest body)
  "Run BODY with the log and exclude file pointed at fresh temp files."
  (declare (indent 0) (debug t))
  `(progn
     (make-directory nanishiteta-test-tmp-dir t)
     (let* ((temporary-file-directory nanishiteta-test-tmp-dir)
            (nanishiteta-log-file (make-temp-file "log"))
            (nanishiteta-exclude-file (make-temp-file "exclude"))
            (nanishiteta--exclude-file-regexps nil))
       (unwind-protect
           (progn ,@body)
         (delete-file nanishiteta-log-file)
         (delete-file nanishiteta-exclude-file)))))

(defun nanishiteta-test-log-lines ()
  "Return the lines of the log file."
  (with-temp-buffer
    (insert-file-contents nanishiteta-log-file)
    (split-string (buffer-string) "\n" t)))

;;;; Recording

(ert-deftest nanishiteta-test-record-line-format ()
  (nanishiteta-test-with-files
    (nanishiteta--record "visit" "/home/user/src/notebook-api/extract.py")
    (let ((fields (split-string (car (nanishiteta-test-log-lines)) "\t")))
      (should (= (length fields) 3))
      (should (string-match-p
               "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]T[0-9:]\\{8\\}[+-][0-9]\\{4\\}\\'"
               (nth 0 fields)))
      (should (equal (nth 1 fields) "visit"))
      (should (equal (nth 2 fields) "/home/user/src/notebook-api/extract.py")))))

(ert-deftest nanishiteta-test-record-appends ()
  (nanishiteta-test-with-files
    (nanishiteta--record "visit" "/home/user/org/inbox.org")
    (nanishiteta--record "save" "/home/user/org/inbox.org")
    (should (equal (mapcar (lambda (l) (nth 1 (split-string l "\t")))
                           (nanishiteta-test-log-lines))
                   '("visit" "save")))))

(ert-deftest nanishiteta-test-exclude-union ()
  (nanishiteta-test-with-files
    (let ((nanishiteta-exclude-regexps '("secret")))
      (with-temp-file nanishiteta-exclude-file
        (insert "/home/user/private/\n"))
      (nanishiteta--load-exclude-file)
      (nanishiteta--record "visit" "/home/user/secret.txt")
      (nanishiteta--record "visit" "/home/user/private/diary.org")
      (nanishiteta--record "visit" "/home/user/org/inbox.org")
      (should (equal (mapcar (lambda (l) (nth 2 (split-string l "\t")))
                             (nanishiteta-test-log-lines))
                     '("/home/user/org/inbox.org"))))))

(ert-deftest nanishiteta-test-missing-exclude-file ()
  (let ((nanishiteta-exclude-file
         (expand-file-name "no-such-file" nanishiteta-test-tmp-dir)))
    (should (null (nanishiteta--load-exclude-file)))))

(ert-deftest nanishiteta-test-default-excludes ()
  (dolist (path '("/home/user/.authinfo"
                  "/home/user/notes.gpg"
                  "/home/user/src/notebook-api/.git/config"
                  "/home/user/src/notebook-api/.git/COMMIT_EDITMSG"
                  "/tmp/scratch.txt"
                  "/home/user/.emacs.d/recentf"
                  "/home/user/.emacs.d/savehist"
                  "/home/user/.emacs.d/nanishiteta.log"
                  "/home/user/.emacs.d/nanishiteta-exclude"))
    (should (nanishiteta--excluded-p path)))
  (should-not (nanishiteta--excluded-p "/home/user/org/inbox.org")))

(ert-deftest nanishiteta-test-remote-not-recorded ()
  (nanishiteta-test-with-files
    (nanishiteta--record "visit" "/ssh:host:/home/user/remote.txt")
    (should (null (nanishiteta-test-log-lines)))))

(ert-deftest nanishiteta-test-hooks-record-kinds ()
  (nanishiteta-test-with-files
    (let ((buffer-file-name "/home/user/src/notebook-api/extract.py")
          (default-directory "/home/user/src/notebook-api/"))
      (nanishiteta--record-visit)
      (nanishiteta--record-save)
      (nanishiteta--record-revert)
      (nanishiteta--record-term))
    (should (equal (mapcar (lambda (l) (cdr (split-string l "\t")))
                           (nanishiteta-test-log-lines))
                   '(("visit" "/home/user/src/notebook-api/extract.py")
                     ("save" "/home/user/src/notebook-api/extract.py")
                     ("revert" "/home/user/src/notebook-api/extract.py")
                     ("term" "/home/user/src/notebook-api/"))))))

(ert-deftest nanishiteta-test-mode-toggles-hooks ()
  (let ((nanishiteta-exclude-file
         (expand-file-name "no-such-file" nanishiteta-test-tmp-dir)))
    (unwind-protect
        (progn
          (nanishiteta-mode 1)
          (should (memq #'nanishiteta--record-visit find-file-hook))
          (should (memq #'nanishiteta--record-term shell-mode-hook))
          (nanishiteta-mode -1)
          (should-not (memq #'nanishiteta--record-visit find-file-hook))
          (should-not (memq #'nanishiteta--record-term shell-mode-hook)))
      (nanishiteta-mode -1))))

;;;; Reading

(defconst nanishiteta-test-fixture
  (expand-file-name "fixture.log" nanishiteta-test-dir)
  "Fixed log used by most reading tests.")

(defconst nanishiteta-test-now
  (nanishiteta--parse-time "2026-10-26T18:00:00+0900")
  "The moment the fixture is read at.")

(defun nanishiteta-test-collect (&optional span)
  "Collect the fixture with a span of SPAN days, 7 by default."
  (let ((nanishiteta-log-file nanishiteta-test-fixture)
        (nanishiteta-span-days (or span 7))
        (nanishiteta--exclude-file-regexps nil))
    (nanishiteta--collect nanishiteta-test-now)))

(defun nanishiteta-test-entry (data system path)
  "Return the entry for PATH in SYSTEM of DATA."
  (cl-find path (if (eq system 'files)
                    (nanishiteta-data-files data)
                  (nanishiteta-data-directories data))
           :key #'nanishiteta-entry-path :test #'equal))

(defun nanishiteta-test-paths (data system)
  "Return the sorted paths in SYSTEM of DATA."
  (sort (mapcar #'nanishiteta-entry-path
                (if (eq system 'files)
                    (nanishiteta-data-files data)
                  (nanishiteta-data-directories data)))
        #'string<))

(defun nanishiteta-test-write-log (lines)
  "Write LINES, each (DATE-STRING KIND PATH), to the log file."
  (with-temp-file nanishiteta-log-file
    (dolist (line lines)
      (insert (mapconcat #'identity line "\t") "\n"))))

(ert-deftest nanishiteta-test-skip-unknown-kind ()
  (should (null (nanishiteta--parse-line
                 "2026-10-24T12:00:00+0900\tfocus\t/home/user/org/inbox.org")))
  (should (null (nanishiteta--parse-line "garbage line without tabs")))
  (should (null (nanishiteta--parse-line "2026-10-24T12:30:00+0900\tvisit")))
  (let ((data (nanishiteta-test-collect)))
    (should (= 1 (nanishiteta-entry-count
                  (nanishiteta-test-entry data 'files
                                          "/home/user/org/inbox.org"))))))

(ert-deftest nanishiteta-test-extra-fields ()
  (should (equal (cdr (nanishiteta--parse-line
                       (concat "2026-10-24T11:00:00+0900\tsave"
                               "\t/home/user/org/inbox.org\textra\tfields")))
                 '("save" "/home/user/org/inbox.org"))))

(ert-deftest nanishiteta-test-day-boundary ()
  (let ((data (nanishiteta-test-collect)))
    (should (= 1 (nanishiteta-entry-age
                  (nanishiteta-test-entry data 'files "/home/user/org/late.org"))))
    (should (= 0 (nanishiteta-entry-age
                  (nanishiteta-test-entry data 'files "/home/user/org/early.org"))))))

(ert-deftest nanishiteta-test-systems ()
  (let ((data (nanishiteta-test-collect)))
    (should (equal (nanishiteta-test-paths data 'directories)
                   '("/home/user/src/notebook-api/"
                     "/home/user/src/old-crawler/")))
    (should (equal (nanishiteta-test-paths data 'files)
                   '("/home/user/org/early.org"
                     "/home/user/org/inbox.org"
                     "/home/user/org/late.org"
                     "/home/user/src/notebook-api/extract.py")))
    (let ((dir (nanishiteta-test-entry data 'directories
                                       "/home/user/src/notebook-api/")))
      (should (= 4 (nanishiteta-entry-count dir)))
      (should (= 1 (nanishiteta-entry-by-hand dir))))
    (should (= 0 (nanishiteta-entry-by-hand
                  (nanishiteta-test-entry data 'directories
                                          "/home/user/src/old-crawler/"))))))

(ert-deftest nanishiteta-test-no-dedup-across-systems ()
  ;; extract.py was both reverted and visited: it counts in both lists.
  (let ((data (nanishiteta-test-collect)))
    (should (nanishiteta-test-entry data 'directories
                                    "/home/user/src/notebook-api/"))
    (should (= 2 (nanishiteta-entry-count
                  (nanishiteta-test-entry
                   data 'files "/home/user/src/notebook-api/extract.py"))))))

(ert-deftest nanishiteta-test-spans ()
  (dolist (case '((1 ("/home/user/src/notebook-api/")
                     ("/home/user/org/early.org"
                      "/home/user/src/notebook-api/extract.py"))
                  (7 ("/home/user/src/notebook-api/"
                      "/home/user/src/old-crawler/")
                     ("/home/user/org/early.org"
                      "/home/user/org/inbox.org"
                      "/home/user/org/late.org"
                      "/home/user/src/notebook-api/extract.py"))
                  (30 ("/home/user/src/notebook-api/"
                       "/home/user/src/old-crawler/")
                      ("/home/user/org/early.org"
                       "/home/user/org/inbox.org"
                       "/home/user/org/late.org"
                       "/home/user/src/notebook-api/extract.py"))))
    (let ((data (nanishiteta-test-collect (car case))))
      (should (equal (nanishiteta-test-paths data 'directories) (nth 1 case)))
      (should (equal (nanishiteta-test-paths data 'files) (nth 2 case)))
      (should (= (length (nanishiteta-data-days data)) (car case)))
      (should (= (apply #'+ (append (nanishiteta-data-hours data) nil))
                 (apply #'+ (append (nanishiteta-data-days data) nil)))))))

(ert-deftest nanishiteta-test-gap ()
  (let ((data (nanishiteta-test-collect)))
    (should (= 23 (nanishiteta-entry-gap
                   (nanishiteta-test-entry data 'directories
                                           "/home/user/src/old-crawler/"))))
    (should (= 6 (nanishiteta-entry-gap
                  (nanishiteta-test-entry data 'files
                                          "/home/user/org/inbox.org"))))
    (should (null (nanishiteta-entry-gap
                   (nanishiteta-test-entry
                    data 'files "/home/user/src/notebook-api/extract.py")))))
  (let ((data (nanishiteta-test-collect 30)))
    (should (= 3 (nanishiteta-entry-count
                  (nanishiteta-test-entry data 'directories
                                          "/home/user/src/old-crawler/"))))
    (should (null (nanishiteta-entry-gap
                   (nanishiteta-test-entry data 'directories
                                           "/home/user/src/old-crawler/"))))))

(ert-deftest nanishiteta-test-gap-beyond-lookback ()
  (nanishiteta-test-with-files
    (nanishiteta-test-write-log
     '(("2026-06-01T10:00:00+0900" "visit" "/home/user/src/csv-tools/old.py")
       ("2026-07-01T10:00:00+0900" "visit" "/home/user/src/csv-tools/read.py")
       ("2026-09-01T10:00:00+0900" "visit" "/home/user/org/inbox.org")
       ("2026-10-26T10:00:00+0900" "visit" "/home/user/src/csv-tools/read.py")
       ("2026-10-26T11:00:00+0900" "visit" "/home/user/org/inbox.org")))
    (let* ((nanishiteta-span-days 7)
           (nanishiteta-gap-lookback-days 90)
           (data (nanishiteta--collect nanishiteta-test-now)))
      ;; 2026-07-01 is 111 days before the span starts.
      (should (null (nanishiteta-entry-gap
                     (nanishiteta-test-entry
                      data 'files "/home/user/src/csv-tools/read.py"))))
      (should (= 55 (nanishiteta-entry-gap
                     (nanishiteta-test-entry
                      data 'files "/home/user/org/inbox.org"))))
      ;; Reading stopped at the first line past the lookback limit.
      (should (= 4 nanishiteta--lines-read)))))

(ert-deftest nanishiteta-test-lookback-stops-early ()
  (nanishiteta-test-with-files
    (nanishiteta-test-write-log
     (append
      (cl-loop for i below 500
               collect (list "2026-10-10T10:00:00+0900" "visit"
                             (format "/home/user/filler/%d.txt" i)))
      '(("2026-10-19T10:00:00+0900" "visit" "/home/user/org/inbox.org")
        ("2026-10-25T10:00:00+0900" "visit" "/home/user/org/inbox.org"))))
    (let* ((nanishiteta-span-days 7)
           (data (nanishiteta--collect nanishiteta-test-now)))
      (should (= 6 (nanishiteta-entry-gap
                    (nanishiteta-test-entry
                     data 'files "/home/user/org/inbox.org"))))
      (should (= 2 nanishiteta--lines-read)))))

(ert-deftest nanishiteta-test-read-backward-chunks ()
  ;; Lines longer than one read chunk, and non-ASCII paths, survive.
  (nanishiteta-test-with-files
    (let ((long (concat "/home/user/" (make-string 70000 ?a) ".txt")))
      (nanishiteta-test-write-log
       `(("2026-10-25T10:00:00+0900" "visit" ,long)
         ("2026-10-26T10:00:00+0900" "visit" "/home/user/org/日記.org")))
      (let ((data (let ((nanishiteta-span-days 7))
                    (nanishiteta--collect nanishiteta-test-now))))
        (should (nanishiteta-test-entry data 'files long))
        (should (nanishiteta-test-entry data 'files
                                        "/home/user/org/日記.org"))))))

(ert-deftest nanishiteta-test-normalize ()
  (let ((repo (file-name-directory (directory-file-name nanishiteta-test-dir))))
    (when (file-directory-p (expand-file-name ".git" repo))
      (should (equal (nanishiteta--normalize-directory nanishiteta-test-dir)
                     repo))))
  (should (nanishiteta--top-directory-p "/"))
  (should (nanishiteta--top-directory-p
           (file-name-as-directory (expand-file-name "~"))))
  (should-not (nanishiteta--top-directory-p "/home/user/src/"))
  (cl-letf (((symbol-function 'nanishiteta--project-root)
             (lambda (_) "~/"))
            ((symbol-function 'nanishiteta--vc-root)
             (lambda (_) "/")))
    (should (equal (nanishiteta--normalize-directory "/home/user/src/x/")
                   "/home/user/src/x/"))))

(ert-deftest nanishiteta-test-exclusion-applies-when-reading ()
  (let ((data (let ((nanishiteta-exclude-regexps '("/org/")))
                (nanishiteta-test-collect))))
    (should (equal (nanishiteta-test-paths data 'files)
                   '("/home/user/src/notebook-api/extract.py")))))

;;;; Drawing

(defmacro nanishiteta-test-with-buffer (span &rest body)
  "Draw the fixture with a span of SPAN days, then run BODY there."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (nanishiteta-list-mode)
     (let ((nanishiteta-span-days ,span))
       (setq nanishiteta--data (nanishiteta-test-collect ,span))
       (nanishiteta--render)
       ,@body)))

(defun nanishiteta-test-goto (regexp)
  "Move to the start of the first line matching REGEXP."
  (goto-char (point-min))
  (re-search-forward regexp)
  (beginning-of-line))

(defun nanishiteta-test-section-lines (heading)
  "Return the visible lines of the section under HEADING."
  (let* ((lines (split-string (nanishiteta--visible-text) "\n"))
         (rest (cdr (member (concat " " heading) lines))))
    (cl-loop for line in rest
             until (not (string-prefix-p " " line))
             collect line)))

(defun nanishiteta-test-refresh ()
  "Run `nanishiteta-refresh' on the fixture as of `nanishiteta-test-now'."
  (let ((collect (symbol-function 'nanishiteta--collect))
        (nanishiteta-log-file nanishiteta-test-fixture))
    (cl-letf (((symbol-function 'nanishiteta--collect)
               (lambda (&rest _) (funcall collect nanishiteta-test-now))))
      (nanishiteta-refresh))))

(ert-deftest nanishiteta-test-layout ()
  (nanishiteta-test-with-buffer 7
    (let ((text (nanishiteta--visible-text)))
      (should (string-prefix-p "┌─ nanishiteta" text))
      (should (string-match-p "last 7 days · recent$" text))
      (should (< (string-match-p " worked in" text)
                 (string-match-p " edited by hand" text))))
    (let ((dirs (nanishiteta-test-section-lines "worked in")))
      (should (equal (length dirs) 2))
      (should (string-match-p "\\` ├─ \\+ /home/user/src/notebook-api/ +today +4  1 by hand\\'"
                              (nth 0 dirs)))
      (should (string-match-p "\\` └─ \\+23d /home/user/src/old-crawler/ +3d +2\\'"
                              (nth 1 dirs))))
    ;; The right columns line up whatever the path length.
    (let ((files (nanishiteta-test-section-lines "edited by hand")))
      (should (= (length (delete-dups
                          (mapcar (lambda (l) (length l)) files)))
                 1))
      (should (string-match-p "\\` └─ /home/user/org/inbox.org +2d +1\\'"
                              (car (last files)))))))

(ert-deftest nanishiteta-test-span-one-shows-time ()
  (nanishiteta-test-with-buffer 1
    (should (string-match-p "last 1 day · recent" (nanishiteta--visible-text)))
    (should (string-match-p "notebook-api/ +15:31 +2"
                            (nanishiteta--visible-text)))))

(ert-deftest nanishiteta-test-buttons ()
  (nanishiteta-test-with-buffer 7
    (nanishiteta-test-goto "old-crawler")
    (let ((button (nanishiteta--line-button)))
      (should button)
      (should (equal (button-get button 'nanishiteta-path)
                     "/home/user/src/old-crawler/")))
    (goto-char (point-min))
    (let ((paths nil) (button nil))
      (while (setq button (next-button (point)))
        (goto-char button)
        (push (button-get button 'nanishiteta-path) paths))
      (should (= (length paths) 6)))))

(ert-deftest nanishiteta-test-limit-folds ()
  (let ((nanishiteta-limit 2))
    (nanishiteta-test-with-buffer 7
      (let ((files (nanishiteta-test-section-lines "edited by hand")))
        (should (= (length files) 3))
        (should (equal (car (last files)) " └─ … 2 more")))
      ;; Directories fit, so they are not folded.
      (should (= 2 (length (nanishiteta-test-section-lines "worked in"))))
      (nanishiteta-test-goto "… 2 more")
      (nanishiteta-open)
      (let ((files (nanishiteta-test-section-lines "edited by hand")))
        (should (= (length files) 5))
        (should (equal (car (last files)) " └─ … less")))
      (should (looking-at-p ".*… less"))
      (nanishiteta-open)
      (should (= 3 (length (nanishiteta-test-section-lines "edited by hand"))))
      ;; Unfolding does not survive a redraw from the log.
      (nanishiteta-test-goto "… 2 more")
      (nanishiteta-open)
      (nanishiteta-test-refresh)
      (should (= 3 (length (nanishiteta-test-section-lines "edited by hand")))))))

(ert-deftest nanishiteta-test-sections-list ()
  (let ((nanishiteta-sections (remq 'nanishiteta-section-files
                                    nanishiteta-sections)))
    (nanishiteta-test-with-buffer 7
      (should (string-match-p "worked in" (nanishiteta--visible-text)))
      (should-not (string-match-p "edited by hand"
                                  (nanishiteta--visible-text)))
      (should-not (string-match-p "inbox.org" (nanishiteta--visible-text)))))
  (let ((nanishiteta-sections '(nanishiteta-section-files
                                nanishiteta-section-directories)))
    (nanishiteta-test-with-buffer 7
      (let ((text (nanishiteta--visible-text)))
        (should (< (string-match-p "edited by hand" text)
                   (string-match-p "worked in" text)))))))

;;;; Sorting

(defconst nanishiteta-test-sort-entries
  (list (nanishiteta-entry-create :path "a" :age 0 :count 5 :gap 3)
        (nanishiteta-entry-create :path "b" :age 0 :count 9 :gap nil)
        (nanishiteta-entry-create :path "c" :age 2 :count 9 :gap 30)
        (nanishiteta-entry-create :path "d" :age 5 :count 1 :gap 30)
        (nanishiteta-entry-create :path "e" :age 2 :count 1 :gap 3))
  "Entries whose order differs in every sort, with ties on both keys.")

(ert-deftest nanishiteta-test-sort-orders ()
  (dolist (case '((recent "b" "a" "c" "e" "d")
                  (oldest "d" "c" "e" "b" "a")
                  (most "b" "c" "a" "e" "d")
                  (least "e" "d" "a" "b" "c")
                  (gap "b" "c" "d" "a" "e")))
    (let ((nanishiteta--sort (car case)))
      (should (equal (mapcar #'nanishiteta-entry-path
                             (nanishiteta--sort-entries
                              nanishiteta-test-sort-entries))
                     (cdr case))))))

(ert-deftest nanishiteta-test-sort-gap-nil-first ()
  (nanishiteta-test-with-buffer 7
    (setq nanishiteta--sort 'gap)
    (nanishiteta--render)
    (let ((dirs (nanishiteta-test-section-lines "worked in"))
          (files (nanishiteta-test-section-lines "edited by hand")))
      (should (string-match-p "notebook-api/" (nth 0 dirs)))
      (should (string-match-p "old-crawler/" (nth 1 dirs)))
      ;; Unknown gaps first, then the known gap of inbox.org.
      (should (string-match-p "inbox.org" (car (last files))))
      (should-not (cl-some (lambda (l) (string-match-p "inbox.org" l))
                           (butlast files))))))

(ert-deftest nanishiteta-test-cycle-sort ()
  (nanishiteta-test-with-buffer 7
    (let ((seen nil))
      (dotimes (_ 6)
        (let ((header (car (split-string (nanishiteta--visible-text) "\n"))))
          (string-match "· \\([a-z]+\\)\\'" header)
          (push (match-string 1 header) seen))
        (nanishiteta-cycle-sort))
      (should (equal (nreverse seen)
                     '("recent" "oldest" "most" "least" "gap" "recent"))))))

;;;; Annotations

(defun nanishiteta-test-git (dir date &rest args)
  "Run git with ARGS in DIR, dating any commit at DATE."
  (let ((default-directory dir)
        (process-environment
         (append (list (concat "GIT_AUTHOR_DATE=" date)
                       (concat "GIT_COMMITTER_DATE=" date)
                       "GIT_CONFIG_NOSYSTEM=1"
                       "HOME=/nonexistent")
                 process-environment)))
    (should (eq 0 (apply #'call-process "git" nil nil nil
                         "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                         "-c" "commit.gpgsign=false"
                         args)))))

(ert-deftest nanishiteta-test-git-annotation ()
  (skip-unless (executable-find "git"))
  (make-directory nanishiteta-test-tmp-dir t)
  (let ((repo (file-name-as-directory
               (make-temp-file (expand-file-name "repo" nanishiteta-test-tmp-dir)
                               t))))
    (unwind-protect
        (progn
          (nanishiteta-test-git repo "2026-10-01T10:00:00+0900" "init" "-q")
          (dolist (commit '(("2026-09-01T10:00:00+0900" "start the crawler")
                            ("2026-10-21T10:00:00+0900" "add the sample dataset")
                            ("2026-10-22T10:00:00+0900" "batch the import endpoint")
                            ("2026-10-23T10:00:00+0900" "fix the conversion table")
                            ("2026-10-24T10:00:00+0900" "rename the export flag")))
            (nanishiteta-test-git repo (car commit) "commit" "-q"
                                  "--allow-empty" "-m" (cadr commit)))
          (let ((start (nanishiteta--parse-time "2026-10-20T00:00:00+0900")))
            (should (equal (nanishiteta-git-annotation repo start
                                                       nanishiteta-test-now)
                           '("rename the export flag"
                             "fix the conversion table"
                             "batch the import endpoint")))
            (let ((nanishiteta-annotation-limit 10))
              (should (= 4 (length (nanishiteta-git-annotation
                                    repo start nanishiteta-test-now)))))))
      (delete-directory repo t))))

(ert-deftest nanishiteta-test-git-annotation-outside-repo ()
  (should (null (nanishiteta-git-annotation "/home/user/no-such-dir/"
                                            0 nanishiteta-test-now)))
  (let ((dir (make-temp-file "nanishiteta-plain" t)))
    (unwind-protect
        (unless (locate-dominating-file dir ".git")
          (should (null (nanishiteta-git-annotation
                         dir 0 nanishiteta-test-now))))
      (delete-directory dir t))))

(ert-deftest nanishiteta-test-annotation-rows ()
  (let* ((calls nil)
         (nanishiteta-annotation-functions
          (list (lambda (dir _start _end)
                  (push dir calls)
                  (and (string-match-p "notebook-api" dir)
                       '("batch the import endpoint" "add the sample dataset")))
                (lambda (&rest _) (error "Broken provider"))
                (lambda (dir &rest _)
                  (and (string-match-p "old-crawler" dir) '("fix the parser"))))))
    (nanishiteta-test-with-buffer 7
      (should (equal (nanishiteta-test-section-lines "worked in")
                     (list (nth 0 (nanishiteta-test-section-lines "worked in"))
                           " │  ● batch the import endpoint"
                           " │  ● add the sample dataset"
                           (nth 3 (nanishiteta-test-section-lines "worked in"))
                           "    ● fix the parser")))
      (should (= 2 (length calls)))
      ;; Redrawing reuses what the providers said.
      (nanishiteta-cycle-sort)
      (should (= 2 (length calls)))
      (nanishiteta-test-goto "● fix the parser")
      (should (equal (nanishiteta--line-path) "/home/user/src/old-crawler/")))))

(ert-deftest nanishiteta-test-annotations-only-for-shown-rows ()
  (let* ((calls nil)
         (nanishiteta-limit 1)
         (nanishiteta-annotation-functions
          (list (lambda (dir &rest _) (push dir calls) nil))))
    (nanishiteta-test-with-buffer 7
      (should (equal calls '("/home/user/src/notebook-api/"))))))

;;;; Footer

(defun nanishiteta-test-bar-start (line)
  "Return the column the bar in LINE starts at."
  (string-match "\\` \\S-+ +" line)
  (match-end 0))

(ert-deftest nanishiteta-test-bar-cells ()
  (dolist (span '(1 2 5 7 10 24 25 30))
    (let* ((days (make-vector span 0))
           (hours (make-vector 24 1)))
      ;; Alternate empty and full days so every cell boundary shows.
      (dotimes (i span) (aset days i (if (cl-oddp i) 0 10)))
      (pcase-let ((`(,hour-line ,day-line)
                   (nanishiteta--footer-bars hours days)))
        (if (= span 1)
            (should (null day-line))
          (let* ((start (nanishiteta-test-bar-start hour-line))
                 (cell (max 1 (/ 24 span)))
                 (bar (substring day-line start (+ start (* cell span)))))
            ;; Both bars start at the same column.
            (should (= start (nanishiteta-test-bar-start day-line)))
            ;; Every day takes the same whole number of cells.
            (dotimes (i span)
              (should (= 1 (length (delete-dups
                                    (string-to-list
                                     (substring bar (* i cell)
                                                (* (1+ i) cell)))))))
              (unless (= i 0)
                (should-not (eq (aref bar (* i cell))
                                (aref bar (1- (* i cell)))))))
            ;; The remainder is left blank, so the end labels line up.
            (when (<= span 24)
              (should (= (string-match " 23\\'" hour-line)
                         (string-match " today\\'" day-line))))))))))

(ert-deftest nanishiteta-test-bar-levels ()
  (should (equal (nanishiteta--bar-cell 0 10) " "))
  (should (equal (nanishiteta--bar-cell 10 10) "█"))
  (should (equal (nanishiteta--bar-cell 1 10) "▁"))
  (should (equal (nanishiteta--bar-cell 0 0) " ")))

(ert-deftest nanishiteta-test-days-recorded ()
  (should (= 117 (nanishiteta-data-days-recorded (nanishiteta-test-collect))))
  ;; Only the first line counts, even if a later line is older.
  (nanishiteta-test-with-files
    (nanishiteta-test-write-log
     '(("2026-01-01T10:00:00+0900" "visit" "/home/user/org/inbox.org")
       ("2025-01-01T10:00:00+0900" "visit" "/home/user/org/inbox.org")
       ("2026-10-26T10:00:00+0900" "visit" "/home/user/org/inbox.org")))
    (should (= 298 (nanishiteta-data-days-recorded
                    (nanishiteta--collect nanishiteta-test-now))))
    ;; The scan stopped long before reaching the first line.
    (should (= 2 nanishiteta--lines-read)))
  (nanishiteta-test-with-files
    (should (null (nanishiteta-data-days-recorded
                   (nanishiteta--collect nanishiteta-test-now))))))

(ert-deftest nanishiteta-test-footer ()
  (nanishiteta-test-with-buffer 7
    (let* ((lines (split-string (nanishiteta--visible-text) "\n"))
           (tail (last lines 5)))
      (should (string-match-p "\\` 00 .* 23\\'" (nth 0 tail)))
      (should (string-match-p "\\` 7d .* today\\'" (nth 1 tail)))
      (should (string-match-p "\\` uptime .* · day 117\\'" (nth 2 tail)))
      (should (equal (nth 3 tail) (concat " " (nanishiteta--key-line))))
      (should (equal (nth 4 tail) "└─"))))
  (nanishiteta-test-with-buffer 1
    (should-not (string-match-p "^ 1d " (nanishiteta--visible-text)))))

(ert-deftest nanishiteta-test-key-line-from-table ()
  (should (string-prefix-p "n/p move  RET open  s sort" (nanishiteta--key-line)))
  (should (string-suffix-p "q quit  ? help" (nanishiteta--key-line)))
  (should-not (string-match-p "TAB" (nanishiteta--key-line))))

(ert-deftest nanishiteta-test-keymap ()
  (should (eq (lookup-key nanishiteta-list-mode-map (kbd "RET"))
              #'nanishiteta-open))
  (should (eq (lookup-key nanishiteta-list-mode-map (kbd "g"))
              #'nanishiteta-refresh))
  (should (eq (lookup-key nanishiteta-list-mode-map (kbd "TAB"))
              #'forward-button)))

(provide 'nanishiteta-test)

;;; nanishiteta-test.el ends here
