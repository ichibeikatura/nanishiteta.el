# nanishiteta

> nanishiteta (何してた) — what was I doing?

[English](README.md) | **日本語**

ここ数日のあいだに作業したディレクトリと、自分の手で編集したファイルを
一つのバッファに並べる Emacs パッケージです。

コーディングエージェントを一日中走らせていると、作業が広がりすぎて、
自分の手でやったことから先に忘れていきます。`M-x nanishiteta` はそれを
思い出すためのものです。

## インストール

`nanishiteta.el` を `load-path` に置いて:

```elisp
(require 'nanishiteta)
(nanishiteta-mode 1)
```

`nanishiteta-mode` は、イベントごとに1行を `nanishiteta-log-file`
（`~/.emacs.d/nanishiteta.log`）に追記します。オフにすると記録は
一切止まります。

## 使い方

`M-x nanishiteta` で `*nanishiteta*` が開きます:

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

- **worked in** は、端末を起動したディレクトリと、Emacs の外でファイルが
  書き換わったディレクトリを、プロジェクトのルート単位で並べます。
  `2 by hand` は、その配下で自分が開いたり保存したりしたファイルの数です。
- **edited by hand** は、自分が開いたり保存したりしたファイルを並べます。
- 右の列は、最後に触ったのが何日前かと、イベントの回数です。期間が1日の
  ときは、日数の代わりに時刻を出します。
- `+23d` は、23日ぶりに戻ってきたという印です。裸の `+` は、
  `nanishiteta-gap-lookback-days` 日さかのぼっても見つからなかった
  という印です。
- 下のバーは、イベントを時間帯ごと・日ごとに数えたものです。

| キー            | 動作                                                  |
|-----------------|-------------------------------------------------------|
| `?`             | `describe-mode`                                       |
| `RET`           | その行を開く（ディレクトリなら Dired）／畳みを展開    |
| `TAB` / `S-TAB` | 次／前の行へ                                          |
| `n` / `p`       | 次／前の行へ                                          |
| `s`             | 並べ替え: recent, oldest, most, least, gap            |
| `c`             | リストをプレーンテキストとしてコピー                  |
| `x`             | カーソル行のパスを以後隠す                            |
| `g`             | 再描画                                                |
| `q`             | 閉じる                                                |

まだ何も記録されていないうちは、`recentf-list` と `file-name-history`
からリストを組みます。

## 設定

すべて `nanishiteta` カスタマイズグループにあります。

| 変数                               | 既定値                         |
|------------------------------------|--------------------------------|
| `nanishiteta-log-file`             | `~/.emacs.d/nanishiteta.log`   |
| `nanishiteta-exclude-file`         | `~/.emacs.d/nanishiteta-exclude` |
| `nanishiteta-exclude-regexps`      | authinfo, `.gpg`, `.git/`, `/tmp/`, `/private/tmp/`, ... |
| `nanishiteta-span-days`            | 7                              |
| `nanishiteta-gap-lookback-days`    | 90                             |
| `nanishiteta-limit`                | 7                              |
| `nanishiteta-annotation-limit`     | 3                              |
| `nanishiteta-ascii`                | nil                            |
| `nanishiteta-annotation-functions` | `(nanishiteta-git-annotation)` |
| `nanishiteta-sections`             | directories, files, footer     |

`nanishiteta-exclude-regexps` か `nanishiteta-exclude-file` のどれかの
行にマッチするパスは、記録も表示もされません。`x` はファイルのほうに
追記するので、init ファイルで変数を `setq` していても消えません。
リモートのパスは記録しません。

罫線やブロック文字がフォントでずれて見えるときは、`nanishiteta-ascii`
を設定してください。

ログは追記専用で、ローテーションはしません。大きくなりすぎたら各自で
切り詰めてください。読むのは末尾だけです。

## アノテーション

各ディレクトリの下に、そこで何があったかを短い行で数本出します。
これは `nanishiteta-annotation-functions` の関数から来ます。各関数は
表示されるディレクトリについてだけ `(DIRECTORY START-TIME END-TIME)`
で呼ばれ、短い文字列のリストか nil を返します。エラーを投げてはいけません。

同梱しているのは `nanishiteta-git-annotation` だけで、期間内のコミットの
件名を author を問わず返します。

コーディングエージェントのセッションも並べたいなら、使っているツールの
ログを読むプロバイダを書いてください。たとえば、あるツールが
`TIME<TAB>DIRECTORY<TAB>TITLE` という行を `~/sessions.tsv` に書いて
いるなら:

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

## ライセンス

GPL-3.0-or-later。`COPYING` を参照してください。
