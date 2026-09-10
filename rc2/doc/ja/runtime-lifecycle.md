# ランタイムライフサイクルフック(`idris2rc2_rtInit` / `idris2rc2_rtFinish`)

(原文: `doc/runtime-lifecycle.md`。内容が乖離した場合は原文を正とする。)

## これは何か

`support/rc2/runtime.c` は引数なしの関数を 2 つ定義する:

```c
void idris2rc2_rtInit(void);    // called first thing in main()
void idris2rc2_rtFinish(void);  // called after the entry point returns
```

`Compiler.RC2.Emit` が生成する `main()`(その `footer`、
`generateCSourceFile` 内)は、実行全体をこの 2 つで挟むようになった:

```c
int main(int argc, char *argv[])
{
    idris2rc2_rtInit();
    idris2_setArgs(argc, argv);           // as before, when linked
    IDRIS2RC2_Value *mainExprVal = __mainExpression_0();
    idris2rc2_trampoline(mainExprVal);
    idris2rc2_rtFinish();
    return 0;
}
```

上流 RefC が生成する `main()`(`idris2-src/src/Compiler/RefC/
RefC.idr`)には相当物がない -- これは rc2 独自の追加であり、
トップレベルの `README.md` の "Deliberate differences from upstream
RefC" に記載されている。

## `rtInit` が存在する理由: `setlocale`

C プログラムは、環境変数の `LC_ALL` / `LANG` / `LC_CTYPE` が何を
言っていようと `"C"` ロケールで開始する -- 環境が参照されるのは
プログラムが `setlocale(LC_*, "")` を呼んだときだけである。rc2 は
一度もそれを呼んでいなかったので、すべての rc2 コンパイル済み
プログラムは `"C"` ロケールで動作し、libc のロケール依存機構も
それに従って振る舞っていた。実際上問題になるのは `<regex.h>`
(`libs/rc2base` の `Text.Regex.POSIX`)である: `"C"` ロケールでは
`regcomp`/`regexec` は**バイト単位**で動作する -- `.` は 1 バイトに
マッチし、`[[:alpha:]]` や大文字小文字を無視したマッチは ASCII の
みが対象になる -- ため、マルチバイトの UTF-8 対象文字列は誤って
解析される。UTF-8 の `LC_CTYPE` があれば、glibc の正規表現エンジン
はマルチバイト経路に切り替わる: `.` はコードポイント全体にマッチ
し、文字クラスはワイド文字述語を使う。(マッチのオフセットは
ロケールによらず**バイト**オフセットのままなので、
`Data.String.RC2.unsafeStringByteSlice` -- `Text.Regex.POSIX` が
スパンを切り出すのに使うもの -- は影響を受けず、今も正しい。)

したがって `idris2rc2_rtInit` は以下だけを実行する:

```c
setlocale(LC_ALL, "");        // adopt the environment's locale, all categories
```

`LC_NUMERIC` を含む全カテゴリである。ここで数値の*フォーマット*が
偶然ロケール任せになっているわけではない: `support/rc2/numeric.c` の
`Double <-> String` キャストは独自の `.` ベースの十進変換
(GMP で厳密なパーサと最短往復フォーマッタ)を持つので、`show` /
`cast` はどの環境でも同じテキストを生成する -- 一方、FFI 経由で
libc 自身の `printf` / `strfmon` を呼ぶプログラムは、要求した
ローカライズ形式を今も得られる。変換そのものについては
`doc/cast-fold-scope.md` と `numeric.c` 自身のコメントを参照。

## UTF-8 互換ロケール要件(重要)

rc2 の `String` 層は、入力される**すべての** C バイト列を UTF-8 と
してデコードする(`support/rc2/idris2rc2_strings.c` + `utf8.c`;
不正なバイトは U+FFFD になる)。この変更前は、ロケール由来の文字列
についてこれは机上の話だった。`"C"` ロケールは ASCII(UTF-8 の
部分集合)しか生成しなかったからである。`rtInit` が*環境の*ロケール
を採用するようになった今、ロケール依存の libc 出力はすべて環境の
文字セットを通って流れる:

- `regexec` は対象文字列を `LC_CTYPE` の文字セットで解釈する;
- `strftime` / `nl_langinfo` は `LC_CTYPE` の文字セットで
  ローカライズされたテキスト(月名/曜日名)を生成する;
- `strerror` / `gai_strerror` / `strsignal` は `LC_MESSAGES` 経由で
  ローカライズされる。

環境ロケールの文字セットが UTF-8 互換で**ない**場合、それらの
バイトは不正な UTF-8 として Idris `String` に到達し、U+FFFD に
デコードされる。非 UTF-8 のマルチバイトロケール(`ja_JP.eucJP`、
`zh_CN.gb18030`、`zh_CN.gbk`)や 8 ビットロケール
(`de_DE.iso88591`、`ru_RU.koi8r`)はすべてこの形で壊れる。素の
`C` / `POSIX` は問題ない(ASCII)。**rc2 コンパイル済みプログラムは
`*.UTF-8` ロケール(あるいは `C` / `C.UTF-8`)で実行すること。**
これは rc2 が強制できないランタイム制約であり -- トップレベルの
`README.md` と `libs/rc2base/doc/regex-posix.md` に記載されている。

## `rtFinish` が存在する理由

`fflush(NULL)` -- 開いているすべての stdio ストリームをフラッシュ
する。`main()` からの通常の `return` は終了時に既にフラッシュする
ので、今のところこれは念のための保険である; もっと穏やかでない
終了をする将来のティアダウン経路や、後でここに追加されるフックの
ために意味を持つ。

## `--directive nomain`

`nomain` ビルド(`doc/export-support.md` の "Linking as a library")
は `main()` を**一切**出力しない -- `%export` されたプログラムを
リンクする手書きの C ドライバが自前の `main()` を用意する。その
ドライバは、最初のエクスポート呼び出しの前に `idris2rc2_rtInit()`
を、終了前に `idris2rc2_rtFinish()` を呼ぶ責任を負う; 代わりに
呼んでくれるものは何もない。

## ファイル

- `rc2/support/rc2/runtime.c` -- `idris2rc2_rtInit` /
  `idris2rc2_rtFinish` の定義。
- `rc2/support/rc2/runtime.h` -- それらの宣言(生成 C からは
  `idris2rc2_runtime.h` アンブレラ経由で既に到達可能)。
- `rc2/src/Compiler/RC2/Emit.idr` -- 2 つの呼び出しを出力する
  `generateCSourceFile` の `footer`。
- `rc2/tests/Test82RuntimeLocale/` -- `LC_CTYPE` を読み返して
  `setlocale(LC_ALL, "")` が実行されたことを証明し、`Double` の
  `show` がロケール安定であることを検査する(`verify.sh` はスイート
  を `LC_ALL=C.UTF-8` で実行する)。
- `rc2/tests/Test83DoubleString/` -- `Double <-> String` 変換自体:
  最短形式の `show`、`cast` パース、往復。
