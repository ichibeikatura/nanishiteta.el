# nanishiteta

> nanishiteta (何してた) — what was I doing?

An Emacs package that shows one buffer listing the directories you
worked in and the files you edited by hand over the last few days.

## Install

Put `nanishiteta.el` on your `load-path`, then:

```elisp
(require 'nanishiteta)
(nanishiteta-mode 1)
```

`nanishiteta-mode` appends one line per event to
`nanishiteta-log-file` (`~/.emacs.d/nanishiteta.log`).  Turning it off
stops all recording.

## Annotations

Under each directory, `nanishiteta` shows a few short lines saying
what happened there.  They come from the functions in
`nanishiteta-annotation-functions`.  Each is called with
`(DIRECTORY START-TIME END-TIME)`, only for the directories shown, and
returns a list of short strings or nil.  It must not signal.

The only one included is `nanishiteta-git-annotation`, which returns
the subjects of the commits made in the span, whoever the author.

If you run coding agents and want their sessions listed too, write a
provider for the logs your tool keeps.  For example, if a tool wrote
`TIME<TAB>DIRECTORY<TAB>TITLE` lines to `~/sessions.tsv`:

```elisp
(defun my-session-annotation (directory start-time end-time)
  "Return the titles of the sessions run in DIRECTORY."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents "~/sessions.tsv")
      (let (titles)
        (dolist (line (split-string (buffer-string) "\n" t))
          (pcase-let ((`(,time ,dir ,title) (split-string line "\t")))
            (let ((time (date-to-time time)))
              (when (and (string-prefix-p directory dir)
                         (time-less-p start-time time)
                         (time-less-p time end-time))
                (push title titles)))))
        (seq-take titles 3)))))

(add-to-list 'nanishiteta-annotation-functions #'my-session-annotation t)
```

## License

GPL-3.0-or-later.  See `COPYING`.
