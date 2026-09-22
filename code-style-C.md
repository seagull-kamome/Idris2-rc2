# Cコード規約

## シンボル命名規則
Cの関数名、グローバル変数、マクロ等には 'idris2rc2_' のプリフィックスをつける。
マクロの場合は 'IDRIS2RC2_'を使う。

グローバルスコープの関数と変数は必要の無いかぎり原則としてつくらない。

## ファイル命名規則
idris2ではCヘッダファイルは-Iオプションを通じてフラットになってしまうので対策が必要。以下のルールを厳守。

| ディレクトリ | ファイル名パターン | 備考 |
|---|---|
| rc2/support/rc2/ | idris2rc2_xxxxx.[ch] |
| libs/yyyy/support/c/ | idris2rc2_yyyy_xxxx.[ch] |
| libs/yyyy/support/rc2/ | idris2rc2_yyyy_xxxx.[ch] |


