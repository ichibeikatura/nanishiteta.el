# nanishiteta

> nanishiteta (何してた) — what was I doing?

An Emacs package that shows one buffer listing the directories you
worked in and the files you edited by hand over the last few days.

When coding agents keep running all day, the work spreads wide and the
things you did with your own hands are the first to be forgotten.
`M-x nanishiteta` brings them back.

## Install

Put `nanishiteta.el` on your `load-path`, then:

```elisp
(require 'nanishiteta)
(nanishiteta-mode 1)
```

`nanishiteta-mode` appends one line per event to
`nanishiteta-log-file` (`~/.emacs.d/nanishiteta.log`).  Turning it off
stops all recording.

## Usage

`M-x nanishiteta` opens `*nanishiteta*`:

```
┌─ nanishiteta                                 last 7 days · recent

 worked in
 ├─ ~/src/notebook-api/                     today   38  2 by hand
 │  ● batch the import endpoint
 ├─ +23d ~/src/old-crawler/                    3d    4
 └─ … 5 more

 edited by hand
 ├─ ~/org/book/chapter-3.org                 today   22
 ├─ + ~/src/notebook-api/extract.py             4d   12
 └─ ~/org/notes/research.org                    5d    8

 00 ▁▁▁▁▁▁▁▁▂▅▇▆▂▁▃▆█▇▄▁▁▂▅▃ 23
 7d ▃▃▃▇▇▇▂▂▂▁▁▁▅▅▅███▆▆▆    today
 uptime 9h14m · day 213
 n/p move  RET open  s sort  c copy  x hide  g refresh  q quit  ? help
└─
```

- **worked in** lists directories where a terminal was started or a
  file changed from outside Emacs, grouped by project root.
  `2 by hand` counts the files below it that you visited or saved.
- **edited by hand** lists files you visited or saved.
- The right columns are how many days ago the row was last touched,
  and how many events it had.  With a span of one day, the time is
  shown instead.
- `+23d` means the row came back after 23 days away; a bare `+` means
  it was not seen in the `nanishiteta-gap-lookback-days` before.
- The bars at the bottom count events by hour of day and by day.

| Key             | Action                                              |
|-----------------|-----------------------------------------------------|
| `?`             | `describe-mode`                                     |
| `RET`           | open the row (Dired for a directory), or unfold     |
| `TAB` / `S-TAB` | next / previous row                                 |
| `n` / `p`       | next / previous line                                |
| `s`             | sort: recent, oldest, most, least, gap              |
| `c`             | copy the lists as plain text                        |
| `x`             | hide the path on this line from now on              |
| `g`             | refresh                                             |
| `q`             | quit                                                |

Until anything is recorded, the lists are made from `recentf-list`
and `file-name-history`.

## Settings

All in the `nanishiteta` customization group.

| Variable                           | Default                        |
|------------------------------------|--------------------------------|
| `nanishiteta-log-file`             | `~/.emacs.d/nanishiteta.log`   |
| `nanishiteta-exclude-file`         | `~/.emacs.d/nanishiteta-exclude` |
| `nanishiteta-exclude-regexps`      | authinfo, `.gpg`, `.git/`, `/tmp/`, ... |
| `nanishiteta-span-days`            | 7                              |
| `nanishiteta-gap-lookback-days`    | 90                             |
| `nanishiteta-limit`                | 7                              |
| `nanishiteta-annotation-limit`     | 3                              |
| `nanishiteta-ascii`                | nil                            |
| `nanishiteta-annotation-functions` | `(nanishiteta-git-annotation)` |
| `nanishiteta-sections`             | directories, files, footer     |

Paths matching `nanishiteta-exclude-regexps` or a line of
`nanishiteta-exclude-file` are neither recorded nor shown.  `x`
appends to the file, so it survives an init file that sets the
variable with `setq`.  Remote paths are never recorded.

Set `nanishiteta-ascii` if box-drawing or block characters look
misaligned in your font.

The log is append-only and is never rotated; trim it yourself if it
grows too large.  Only its tail is read.

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
