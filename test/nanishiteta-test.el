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

(provide 'nanishiteta-test)

;;; nanishiteta-test.el ends here
