# `fastPack`/`fastConcat`/`fastUnpack`/`Data.String.Iterator`のEmit時インターセプト

(原文: `doc/fastpack-fix.md`。内容が乖離した場合は原文を正とする。)

`fastPack`/`fastConcat`が抱えていたリークの修正記録である。最初の修正案(`Prelude.Fix.RC2`と`%transform`)が不十分だった理由、それに代わったEmit時のリダイレクトの実際、そして、この修正をプロジェクト全体で無条件に有効にする過程で見つかった別のバグ(空文字列でのSIGSEGV)を記す。のちに、同じEmit時の仕組みを`fastUnpack`と、`Data.String.Iterator`の`uncons`/`withIteratorString`にも広げた。こちらはリークではないが、根本原因は同じである。上流のFFIシグネチャが`char *`型であるため、`String`が埋め込みNULバイトを持てるようになると、情報が失われる。詳細は後述の「`fastUnpack`と`Data.String.Iterator`への拡張」を参照する。この記録に未実施のコードはない。ここに書いた内容はすべて実装して検証済みである(`rc2/tests/verify.sh`全体で82件成功・既知の失敗0件・失敗0件、`libs/rc2base/tests/verify.sh`はすべてPASS)。

## 元のリーク

`fastPack : List Char -> String`と`fastConcat : List String -> String`は、`%foreign "RefC:fastPack"`/`"RefC:fastConcat"`として宣言されており、戻り値の型は`CFString`である。このため`Compiler.RC2.Emit`の汎用FFIラッパのコード生成(ほかのすべての`%foreign`宣言が通る経路)は、C実装が返した`char *`を`idris2rc2_mkString`(`rc2/support/rc2/memory.c`)で新しい`IDRIS2RC2_String`にコピーして包む。しかし元のポインタは解放しない。

通常のケースでは、このプロトコルが正しい。本物の外部ライブラリが返す`char *`(たとえば`curl_easy_strerror`)は、ライブラリ側が所有しているので、呼び出し側が解放してはならない。しかし`fastPack`/`fastConcat`に限っては誤りである。どちらも、このプロジェクト自身が所有するバッファを`malloc`する(`rc2/support/rc2/idris2rc2_strings.c`の`fastPack`/`fastConcat`)。このバッファは一度コピーされたら捨てられるだけのものである。ところが`CFString`を返すforeign関数は、返すバッファが借り物でも自前の所有物でも、見た目が同じである。汎用ラッパは、FFIシグネチャだけからはこの違いを区別できない。

## 最初の修正案: `Prelude.Fix.RC2`と`%transform`(不十分)

最初の修正では、リークしない置き換え関数`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`を追加した(どちらも今も`idris2rc2_strings.c`にある)。これらは、新しい`IDRIS2RC2_String`に直接構築し、すでに完成した`IDRIS2RC2_Value *`を返す。途中に`char *`が現れないので、コピーしてリークするものがない。これらを組み込むために、`libs/rc2base/src/Prelude/Fix/RC2.idr`というモジュールを用意した。上流Idris2の`%transform`の仕組みを使って、`fastPack`/`fastConcat`の呼び出しを修正版の呼び出しに書き換える。

この方法は動いたが、そのモジュールを明示的に`import`したプログラムでしか効かなかった。原因は、モジュールの書き方のバグではなく、仕組み上避けられない制約にある。`%transform`が書き換えるのは、書き換えを定義する側のエラボレーション/importのスコープ内にある呼び出し箇所だけであり、書き換えが行われるのはエラボレーション時である。別パッケージが個別にコンパイルして`.ttc`に焼き込んだ呼び出し箇所には届かない。書き換えは、呼び出しをエラボレートする時点でスコープ内になければならない。ところが`network`/`base`がエラボレートされて`.ttc`として配布されたのは、このプロジェクトの`%transform`ルールがそれらのスコープに入りうるよりずっと前だった。

その結果、`verify.sh`に`KNOWN_LEAK_BYTES`のエントリを持つテストが2つ残った。どちらも、呼び出し側が何を`import`しても、フロントエンド側からは直せない。

- `Test35NetworkLoopback`: `network`自身の`Network.Socket.Data.parseIPv4`が内部で`fastPack`を呼ぶためにリークする。
- `Test37SystemMisc`(旧`Test40SystemProcess`): `base`自身の`System.File.ReadWrite`の`fRead'`が内部で`fastConcat`を呼ぶためにリークする。

## 実際の修正: Emit時のインターセプト

フロントエンドからはこれらの呼び出し箇所に届かないので、インターセプトの場所をrc2自身のC出力時、つまり`Compiler.RC2.Emit`に移した。rc2のバックエンドは、コンパイルするプログラムの`RCDef`全体を、どのパッケージ由来の定義かを問わず処理する。したがって、この段階での検査は、プリコンパイル済みの`network`/`base`のコードに焼き込まれた呼び出し箇所を含めて、すべての呼び出し箇所に作用する。それらのパッケージを再コンパイルする必要はない。

`fastPackFixedReplacement : Name -> Maybe String`(`Emit/Foreign.idr`)は、定義の**名前空間まで含めた完全修飾名**で照合する。

```idris
fastPackFixedReplacement : Name -> Maybe String
fastPackFixedReplacement (NS ns (UN (Basic "fastPack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastPackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastConcat"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastConcatFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastUnpack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastUnpackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "uncons"))) =
    if ns == mkNamespace "Data.String.Iterator" then Just "idris2rc2_stringIteratorNextFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "withIteratorString"))) =
    if ns == mkNamespace "Data.String.Iterator" then Just "idris2rc2_stringIteratorToStringFixed" else Nothing
fastPackFixedReplacement _ = Nothing
```

基本名だけでなく名前空間まで検査するのは、防御的な選択である。基本名だけの照合では、将来、別の名前空間にたまたまこれらと同じ基本名を持つ無関係な関数が現れたときに、誤ってリダイレクトしてしまう。`fastPack`/`fastConcat`をリダイレクトする理由は、前述のとおり本物の`fastPack`/`fastConcat`がリークするからである。`fastUnpack`/`uncons`/`withIteratorString`は別の理由でリダイレクトする。後述の「`fastUnpack`と`Data.String.Iterator`への拡張」を参照する。

`emitForeignDef`の分岐(`Emit/Foreign.idr`。`createCFunctions`の`MkRCForeign`ケースから呼ばれる)には、通常のコード生成経路から外す前に、シグネチャの形に対する**もう一つの独立した**検査がある。

```idris
fastPackFixedShape : CFType -> List CFType -> Bool
fastPackFixedShape ret fargs = boxedRet ret && all boxedArg fargs
  where
    boxedRet : CFType -> Bool
    boxedRet CFString = True
    boxedRet (CFUser _ _) = True
    boxedRet _ = False

    boxedArg : CFType -> Bool
    boxedArg CFString = True
    boxedArg (CFUser _ _) = True
    boxedArg (CFFun _ _) = True
    boxedArg _ = False

case (fastPackFixedReplacement n, fastPackFixedShape ret fargs) of
     (Just fixedFnName, True) => emitFastPackFixedWrapper fixedFnName
     _ => emitGenericForeignWrapper
```

`fastPackFixedShape`が受け付けるのは、戻り値が`CFString`/`CFUser`のいずれか、各引数が`CFString`/`CFUser`/`CFFun`のいずれかという組み合わせである。アリティと型の組み合わせを1通りに限っていない。上の5つの対象は、最初の`List Char -> String`/`List String -> String`の組のように、同じシグネチャを共有してはいないからである。たとえば`withIteratorString`のシグネチャには、`CFFun`型の引数(文字列の残りを渡して呼び出す継続)もある。最初の「`CFUser`の引数が1つ」という検査では、これを門前払いにしてしまう。5つの対象すべてに必要なのは、`emitFastPackFixedWrapper`がそのまま出力できるシグネチャである。すべての引数を、すでにボックス化された値としてそのまま通せればよい(後述の「`emitFastPackFixedWrapper`」を参照)。`fastPackFixedShape`はまさにその述語であり、特定のアリティに一致するかを見る代用品ではない。

この検査は、名前の検査とは別の、本物の検査である。仮に名前が衝突し、しかも右の名前空間にまで存在する関数があったとしても、`fastPackFixedShape`が受け付ける形をしていなければ、リダイレクトされない。`emitFastPackFixedWrapper`が走るには、名前と形の両方の検査を通る必要がある。それ以外はすべて、手を加えていない`emitGenericForeignWrapper`に落ちる。`hasUsableForeignImpl`(これも`Emit/Foreign.idr`)は、`MkRCForeign`宣言がそもそも使えるかを判定するために、まったく同じ2つの検査を行う。リダイレクトの対象になる宣言について、2つの呼び出し箇所の判断が食い違ってはならない。

`emitFastPackFixedWrapper`(`Emit/Foreign.idr`)が出力する**外部C名は、`emitGenericForeignWrapper`が生成する名前と同一**である。したがって、既存のあらゆる呼び出し箇所は、何も変更せずに同じシンボルへリンクし続ける。Cのパラメータは、`fargs`の各要素に1つずつ、その引数自身の`CFType`にかかわらず、常に`IDRIS2RC2_Value *`として宣言する。どのラッパの外側のシグネチャも同じ理由でこの型に揃えた、型に依存しない共通の宣言形式である(rc2の内部呼び出し規約は、すべての引数を一様にボックス化する。`%foreign`の引数に固有のC型が意味を持つのは、ラッパ自身の本体がそれを取り出すときだけであり、このラッパは取り出さない)。

ラッパの**本体**は汎用の経路と異なる。ボックス化済みの各引数を`(IDRIS2RC2_Value*)`に直接キャストし、照合した`fixedFnName`(`idris2rc2_fastPackFixed`、`idris2rc2_fastUnpackFixed`など)を直接呼ぶ。`packCFType`/`extractValue`は完全に省略する。裸の`CFUser`を返す場合もすでにこれらを省略しているのと同じである。これらのC関数はどれも、完全に形成され、所有権も正しい`IDRIS2RC2_Value *`を、自分で受け取り、返すからである。呼び出しのあと各引数をdropする点は、汎用ラッパと同じである(`removeVars`)。ただし、Cレベルでは常にアンボックスである`CFType`の引数(`alwaysUnboxedDropVar`、`Types.alwaysUnboxed`)は、先にそのdropリストから除く。タグ付きポインタの値に対する`idris2rc2_drop`は確実に何もしないので、出力する理由がないからである。

`Test35NetworkLoopback`の実際の生成Cを調べて確認した。`network`自身のプリコンパイル済み`parseIPv4`の呼び出し箇所(このパッケージは再コンパイルしていない)に対して出力された`Prelude_Types_fastPack`ラッパは、`idris2rc2_fastPackFixed`を呼ぶようになり、リークは消えた。

## `fastUnpack`と`Data.String.Iterator`への拡張: リークではなく、埋め込みNULへの対策

`fastUnpack`、`Data.String.Iterator.uncons`、`Data.String.Iterator.withIteratorString`も、同じEmit時の仕組みでリダイレクトしている。ただし理由は上記のリークとは無関係である。この3つはどれもリークしない。上流の`%foreign`宣言は、文字列を素の`char *`として受け取る(`fastUnpack(char *str)`、`stringIteratorNext(char *s, ...)`、`stringIteratorToString(void *a, char *str, ...)`。これらは今も`idris2rc2_strings.h`/`.c`にある)。rc2の`String`は埋め込みNULバイトを持てるようになった(`rc2/doc/constructor-layout.md`の "Strings")。そのため、これらの関数に`->str`だけを通して読ませると、最初の埋め込みNUL以降がすべて、気づかないうちに失われる。`fastUnpack "ab\NUL1cd"`は`"ab"`だけに展開されてしまう。`Data.String.Iterator`自身のfoldも同じ位置で止まる。

`idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/`idris2rc2_stringIteratorToStringFixed`(`idris2rc2_strings.c`)は、この問題を、`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`が上記のコピーとリークを避けたのと同じ方法で解決する。`IDRIS2RC2_Value *`自体を受け取って`IDRIS2RC2_String *`にキャストし直し、NULに出会うまで`->str`を読む代わりに、`->len`バイトだけを読む。回帰テストは`rc2/tests/Test124StringNul`である。リダイレクトした5つの関数すべてと、`Data.TextBuffer.fromString`(別の仕組みでCに到達する。`libs/rc2base/README.md`の`Data.String.RC2`/`Data.TextBuffer`の説明を参照)を、埋め込みNULバイトを含む`String`に対して検査する。

上記の`fastPack`/`fastConcat`と違って、`fastUnpack`/`stringIteratorNext`/`stringIteratorToString`には`idris2rc2_strings.h`の`deprecated`属性を付けていない。これらに到達してもリークにはならず、最初の埋め込みNULで黙って切り捨てられるだけである。「ここには到達しないはずだ」というビルド時の合図を付ける対象になる状況が、そもそもない。リダイレクトされた呼び出し箇所をこの切り捨てから守っているのは、ここでのリダイレクトだけである。

## `Prelude.Fix.RC2`の廃止

`libs/rc2base/src/Prelude/Fix/RC2.idr`は削除した(`rc2base.ipkg`の`modules`から除き、不要になった`rc2/tests/Test28Utf8Strings.idr`の`import`も除いた)。Emit時の修正は、`%transform`モジュールが扱えた呼び出し箇所をすべて扱え、そのモジュールが届かなかった箇所も扱えるので、厳密により汎用的である。オプトイン式のモジュールを残しても冗長なだけである。

## `deprecated`属性を残した理由

`idris2rc2_strings.h`は今も`fastPack`/`fastConcat`を`__attribute__((deprecated(...)))`付きで宣言しており、`rc2/src/Compiler/RC2/CC.idr`は、生成したCをコンパイルするときに今も`-Wno-error=deprecated-declarations`を渡している。リダイレクトによって、実際にはこれらに到達しないはずになったが、整理せずに、安全網としてあえて**残した**。

理由は次のとおり。リダイレクトが保証するのはコード生成のレベルであり、型レベルの保証ではない。将来`Emit/Foreign.idr`を変更して`fastPackFixedReplacement`の照合が狭まったり、リダイレクトが壊れたりしても、すぐに気づける仕組みはない。そうなると、生成コードは`emitGenericForeignWrapper`に落ち、本物のリークする`fastPack`/`fastConcat`をまた呼び始める。見た目は正しく動いているのに、リークしている状態である。`deprecated`属性を残しておけば、この退行は**ビルド時の警告**として再び現れる。`-Wno-error=deprecated-declarations`フラグが明示されているので警告がエラーになってビルドが止まることはないが、ビルドの出力を読む人には見える。何も残さなければ、`valgrind`でたまたま再発見するまで、黙ったリークになる。両方の属性メッセージは(実装したセッションが)更新済みで、これらに到達するのは、呼び出し側が回避すべきものではなく、リダイレクトに関するrc2のバグだと示すようになっている。

## 途中で見つかった2つ目のバグ: 空文字列でのSIGSEGV

当初の計画にはなかった。Emit時のリダイレクトによって`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`がプロジェクト全体で無条件になったあと、検証中に見つかった。

**根本原因**: この2つの関数は、`idris2rc2_mkEmptyString(byteLen + 1)`のあとで、明示的に`r->str[byteLen] = '\0'`を実行していた(`byteLen`/`total`は計算した出力長)。入力が空の場合(`byteLen == 0`。たとえば`pack []`/`concat []`)、`idris2rc2_mkEmptyString(1)`は新しいバッファを割り当てない。共有の不死(immortal)な`const`の静的値`idris2rc2_emptyStringValue`を返す。この場合の`r->str[0]`への書き込みは、読み取り専用メモリへの書き込みになる。

`Prelude.Fix.RC2`経由のオプトインにとどまっていたあいだは、この問題は表に出なかった。既存のimport側のコードは、修正済みの経路で`pack []`/`concat []`を呼んでいなかったからである。Emit時のリダイレクトによって、これらがすべてのプロジェクトで無条件になると、まさにこの呼び出しをする`refc-suite`の`strings`テストがSIGSEGVでクラッシュした。

**修正**: 末尾のNULの書き込みを2か所とも削除した。`idris2rc2_mkEmptyString`がmallocする経路は、バッファ全体をすでに`memset()`でゼロにしている。したがって、終端バイト(コピーのループが最後に書くバイトの直後)は、明示的に書かなくても、もともと正しい値になっている。この形は、`idris2rc2_strings.c`のほかの`idris2rc2_mkEmptyString`の呼び出し側(`idris2rc2_strTail`/`strReverse`/`strCons`/`strAppend`/`strSubstr`)がすでに従っているパターンと同じである。これらのいずれも、`memcpy`した自身のペイロードを越えた添字書き込みをしていない。

## 検証手順

1. `rc2/tests/verify.sh`全体: 82件成功、既知の失敗0件、失敗0件。
2. `libs/rc2base/tests/verify.sh`全体: すべてPASS。
3. `Test35NetworkLoopback`(`parseIPv4`を呼ぶ、手を加えていないプリコンパイル済みの`network`パッケージの呼び出し箇所)の実際の生成Cを調べ、`Prelude_Types_fastPack`ラッパが`idris2rc2_fastPackFixed`を呼んでいることを確認した。`network`/`base`の再コンパイルはどこにも必要なかった。
4. `verify.sh`の`KNOWN_LEAK_BYTES`マップは、今は本当に空である。`Test35NetworkLoopback`/`Test37SystemMisc`(当時は`Test40SystemProcess`)のエントリを削除し、どちらもリークが0バイトであることを確認した。(`Test35NetworkLoopback`が`NO_REFC_DIFF_TESTS`に残っているのは、この修正とはまったく無関係で、まだ解決していない別の理由による。本物のRefCだけで起きるコンパイルバグで、`parseIPv4`自身が生成するcast関数名の大文字小文字の不一致である。)
5. 新しい回帰テスト`rc2/tests/Test46FastPackUnconditional.idr`(と`.expected`)は、importを一切オプトインせずに`pack`/`concat`を呼ぶ。`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録済みで、リークがないことを確認した。このテスト自身のモジュールコメントは、空文字列のケースにも暗黙に触れているが、`pack`/`concat`を空でないリストに対して呼ぶだけである。空入力でのSIGSEGVを捕らえたのは、新しい専用テストではなく、すでにあった`refc-suite`の`strings`テストだった。このテストがたまたま`pack []`/`concat []`を実行していたからである。

## ファイル

- `rc2/src/Compiler/RC2/Emit/Foreign.idr`: `fastPackFixedReplacement`、`fastPackFixedShape`、`emitForeignDef`の分岐、`emitFastPackFixedWrapper`、`hasUsableForeignImpl`。
- `rc2/support/rc2/idris2rc2_strings.c`: `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`(空文字列の末尾NUL書き込みの削除)、`idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/`idris2rc2_stringIteratorToStringFixed`(`fastUnpack`/`Data.String.Iterator.uncons`/`withIteratorString`を埋め込みNULに対して安全にした置き換え)。
- `rc2/support/rc2/idris2rc2_strings.h`: `fastPack`/`fastConcat`に残した`deprecated`属性(メッセージは、これらに到達することを、呼び出し側の回避策ではなくrc2のバグとして説明するように更新した)と、上記5つの`*Fixed`置き換え関数の宣言。
- `rc2/support/rc2/idris2rc2_datatypes.h`: `IDRIS2RC2_String`自身の`len`フィールド。`fastUnpack`/`uncons`/`withIteratorString`をリダイレクトする必要が生じた、そもそもの原因である(`rc2/doc/constructor-layout.md`の "Strings")。
- `rc2/src/Compiler/RC2/CC.idr`: 残した`-Wno-error=deprecated-declarations`フラグ。
- `rc2/tests/Test46FastPackUnconditional.idr`: 元のリーク修正の回帰テスト。
- `rc2/tests/Test124StringNul/`: リダイレクトした5つの関数すべてを、埋め込みNULバイトを含む`String`に対して検査する回帰テスト。
- `libs/rc2base/src/Prelude/Fix/RC2.idr`: **もう存在しない**(廃止。`rc2base.ipkg`の`modules`から除き、`rc2/tests/Test28Utf8Strings.idr`のimportも除いた)。
