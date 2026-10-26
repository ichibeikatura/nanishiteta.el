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

## License

GPL-3.0-or-later.  See `COPYING`.
