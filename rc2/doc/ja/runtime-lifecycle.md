# ランタイムのライフサイクルフック(`idris2rc2_rtInit` / `idris2rc2_rtFinish`)

(原文: `doc/runtime-lifecycle.md`。内容が乖離した場合は原文を正とする。)

## 概要

`support/rc2/runtime.c` は、引数を取らない関数を2つ定義している。

```c
void idris2rc2_rtInit(void);    // called first thing in main()
void idris2rc2_rtFinish(void);  // called after the entry point returns
```

`Compiler.RC2.Emit` が生成する `main()`(`generateCSourceFile` 内の `footer`)は、
プログラムの実行全体をこの2つの呼び出しで挟む。

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

上流RefCが生成する `main()`(`idris2-src/src/Compiler/RefC/
RefC.idr`)には、これに相当するものがない。rc2 独自の追加であり、
トップレベルの `README.md` の "Deliberate differences from upstream
RefC" にも載せている。

## `rtInit` が必要な理由: `setlocale`

C プログラムは、環境変数 `LC_ALL` / `LANG` / `LC_CTYPE` に何が設定されていても、
起動直後は `"C"` ロケールで動く。環境変数が参照されるのは、プログラムが
`setlocale(LC_*, "")` を呼んだときだけである。rc2 はこれまで一度も呼んでいなかった。
そのため、rc2 でコンパイルしたプログラムはすべて `"C"` ロケールで動作し、
libc のロケール依存の処理もそれに従っていた。

実際に問題になるのは `<regex.h>`(`libs/rc2base` の `Text.Regex.POSIX`)である。
`"C"` ロケールでは `regcomp` / `regexec` が**バイト単位**で動く。`.` は1バイトに
マッチし、`[[:alpha:]]` や大文字小文字を区別しないマッチはASCIIだけが対象になる。
このため、マルチバイトの UTF-8 文字列を対象にすると正しく解析できない。
一方、`LC_CTYPE` がUTF-8ならば、glibc の正規表現エンジンはマルチバイト用の
処理に切り替わる。`.` はコードポイント1つにマッチし、文字クラスはワイド文字の
判定関数を使う。マッチ位置のオフセットはロケールによらず**バイト**単位のままである。
`Text.Regex.POSIX` が部分文字列を切り出すのに使う
`Data.String.RC2.unsafeStringByteSlice` はこの影響を受けず、従来どおり正しく動く。

そこで `idris2rc2_rtInit` は、次の1行だけを実行する。

```c
setlocale(LC_ALL, "");        // adopt the environment's locale, all categories
```

対象は `LC_NUMERIC` を含むすべてのカテゴリである。数値の*書式化*が、これによって
ロケール任せになるわけではない。`support/rc2/numeric.c` の `Double <-> String`
キャストは、`.` を小数点とする独自の十進変換(GMP による厳密なパーサと、最短で
往復可能な書式化)を持っている。このため `show` / `cast` は、どの環境でも同じ
文字列を返す。一方、FFI 経由でlibcの `printf` / `strfmon` を直接呼ぶプログラムは、
要求どおりロケールに従った書式を得られる。変換そのものについては、
`doc/cast-fold-scope.md` と `numeric.c` 内のコメントを参照。

## UTF-8 互換ロケールの要件(重要)

rc2 の `String` 層は、外部から入ってくる C のバイト列を**すべて** UTF-8 として
デコードする(`support/rc2/idris2rc2_strings.c` と `utf8.c`。不正なバイトは
U+FFFD になる)。`rtInit` を導入する前は、ロケール由来の文字列でこの前提が
問題になることはなかった。`"C"` ロケールが生成するのは ASCII(UTF-8 の
部分集合)だけだったからである。`rtInit` が*環境の*ロケールを採用する今は、
ロケール依存のlibcの出力がすべて環境の文字コードで返ってくる。

- `regexec` は、対象文字列を `LC_CTYPE` の文字コードとして解釈する。
- `strftime` / `nl_langinfo` は、ロケールに従った文字列(月名・曜日名)を
  `LC_CTYPE` の文字コードで生成する。
- `strerror` / `gai_strerror` / `strsignal` は、`LC_MESSAGES` に従って
  ローカライズされる。

環境ロケールの文字コードが UTF-8 互換でない場合、これらのバイト列は不正な
UTF-8 としてIdrisの `String` に渡り、U+FFFD にデコードされる。非UTF-8の
マルチバイトロケール(`ja_JP.eucJP`、`zh_CN.gb18030`、`zh_CN.gbk`)と、
8ビットのロケール(`de_DE.iso88591`、`ru_RU.koi8r`)は、いずれもこの形で
文字化けする。素の `C` / `POSIX` はASCIIなので問題ない。**rc2 でコンパイルした
プログラムは、`*.UTF-8` ロケール(または `C` / `C.UTF-8`)で実行すること。**
これは rc2 側では強制できないランタイムの制約であり、トップレベルの
`README.md` と `libs/rc2base/doc/regex-posix.md` にも記載している。

## `rtFinish` が必要な理由

`rtFinish` は `fflush(NULL)` を呼び、開いているすべての stdio ストリームを
フラッシュする。`main()` から通常どおり `return` すれば、終了時に自動でフラッシュ
されるので、現状では念のための二重化にすぎない。意味を持つのは、より乱暴に
終了する終了処理を将来追加する場合や、このフックに別の処理を足す場合である。

## `--directive nomain`

`nomain` ビルド(`doc/export-support.md` の "Linking as a library")では、
`main()` を**まったく**出力しない。`%export` したプログラムをリンクする手書きの
C ドライバが、自前の `main()` を用意するためである。このドライバは、最初の
エクスポート関数を呼ぶ前に `idris2rc2_rtInit()` を、終了する前に
`idris2rc2_rtFinish()` を呼ばなければならない。ドライバに代わってこれらを
呼ぶ処理は、どこにもない。

## ファイル

- `rc2/support/rc2/runtime.c` -- `idris2rc2_rtInit` / `idris2rc2_rtFinish` の定義。
- `rc2/support/rc2/runtime.h` -- 上記2関数の宣言。生成された C コードからは、
  `idris2rc2_runtime.h` の包括ヘッダ経由で参照できる。
- `rc2/src/Compiler/RC2/Emit.idr` -- 2つの呼び出しを出力する、
  `generateCSourceFile` 内の `footer`。
- `rc2/tests/Test82RuntimeLocale/` -- `LC_CTYPE` を読み戻して
  `setlocale(LC_ALL, "")` が実行されたことを確認し、`Double` の `show` が
  ロケールに依存しないことも検査する(`verify.sh` はこのスイートを
  `LC_ALL=C.UTF-8` で実行する)。
- `rc2/tests/Test83DoubleString/` -- `Double <-> String` 変換そのものを検査する。
  最短形式の `show`、`cast` によるパース、往復変換を扱う。
