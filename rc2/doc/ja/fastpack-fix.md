# `char *`を使う文字列のforeign関数の置き換え: `fastPack`、`fastConcat`、`fastUnpack`、`Data.String.Iterator`、`Data.Buffer`の文字列プリミティブ

(原文: `doc/fastpack-fix.md`。内容が乖離した場合は原文を正とする。)

`fastPack`/`fastConcat`が抱えていたリークの修正記録である。次の3点を記す。
- 最初の修正案(`Prelude.Fix.RC2`と`%transform`)が不十分だった理由。
- それに代わったリダイレクトの実際(最初はC出力時に行い、今は宣言の書き換えである)。
- この修正をプロジェクト全体で無条件に有効にする過程で見つかった、別のバグ(空文字列でのSIGSEGV)。

のちに、同じ仕組みを`fastUnpack`と、`Data.String.Iterator`の`uncons`/`withIteratorString`にも広げた。こちらはリークではないが、根本原因は同じである。上流のFFIシグネチャが`char *`型であるため、`String`が埋め込みNULバイトを持てるようになると、情報が失われる。詳細は後述の「`fastUnpack`と`Data.String.Iterator`への拡張」を参照する。

この記録に未実施のコードはない。ここに書いた内容はすべて実装して検証済みである(`rc2/tests/verify.sh`全体で82件成功・既知の失敗0件・失敗0件、`libs/rc2base/tests/verify.sh`はすべてPASS)。

## 何を置き換えるのか、なぜ置き換えるのか

rc2は、上流の一部の`%foreign`宣言を、**プログラムを`RCDef`に変換する時点で**(`normalizeTop`。Cを生成するより前)書き換える。宣言が指定するC関数の代わりに、`String`の値そのものを受け取るrc2独自の関数をプログラムに呼ばせる。理由は次の2つで、対象はこれらの関数だけである(`Compiler/RC2/ForeignDivert.idr`の`diverted`がその一覧である)。

- **リーク。** `char *`を返す`%foreign`の汎用ラッパは、結果を新しい`String`にコピーし、元のポインタを解放しない。ポインタをライブラリが所有している場合はこれが正しいが、rc2のためだけにバッファを`malloc`する関数(`fastPack`、`fastConcat`)では誤りである。
- **埋め込みNUL。** rc2の`String`は長さ(`IDRIS2RC2_String.len`)を持ち、NULバイトを保持できる。`String`を`char *`として受け取る`%foreign`や、`char *`を返す`%foreign`は、最初のNUL以降をすべて失う(`strlen`、`strncpy`、C文字列を読むコンストラクタ)。置き換え先の関数は、代わりに`len`を使う。

| 上流の関数 | モジュール | 置き換え先(rc2) | 理由 |
|---|---|---|---|
| `fastPack` | `Prelude.Types` | `idris2rc2_fastPackFixed` | リーク、および結果のNUL |
| `fastConcat` | `Prelude.Types` | `idris2rc2_fastConcatFixed` | リーク、および結果のNUL |
| `fastUnpack` | `Prelude.Types` | `idris2rc2_fastUnpackFixed` | NUL(`char *`を読む) |
| `uncons`、`withIteratorString` | `Data.String.Iterator` | `idris2rc2_stringIteratorNextFixed`、`idris2rc2_stringIteratorToStringFixed` | NUL(`char *`を読む) |
| `uncons`、`withIteratorString` | `Libraries.Data.String.Iterator`(コンパイラ自身のコピー。`Core.Hash`が使う) | 上と同じ2つ | NUL |
| `stringByteLength` | `Data.Buffer` | `idris2rc2_stringByteLengthFixed` | NUL(`strlen`) |
| `prim__setString` | `Data.Buffer` | `idris2rc2_setBufferStringFixed` | NUL(引数の`strlen`) |
| `prim__getString` | `Data.Buffer` | `idris2rc2_getBufferStringFixed` | NUL(`strncpy`のあと、C文字列が`String`になる) |

これが、たまたま書かれた1つのプログラムにとどまらない問題である理由: コンパイラは、`.ttc`ファイルのStringの定数を、まさにこの3つの`Data.Buffer`の関数で書き込み、読み出す(`Core.Binary.Prims`、`TTC String`)。この置き換えなしに**rc2でビルドした**コンパイラは、すべてのStringの定数を最初のNULで切り詰めていた(`rc2/doc/self-hosting.md`の発見9)。

仕組みは次のとおりである。

1. **宣言の書き換えを1回だけ行う。** プログラムを`RCDef`に変換するとき(`RC.idr`の`normalizeTop`。ここで`MkNmForeign`が`MkRCForeign`になる)、`divertForeign`(`Compiler/RC2/ForeignDivert.idr`)が、宣言を表から探す。照合には、完全な名前空間と基本名、および引数の個数を使う。一致したものは、普通の宣言に置き換える。

   ```
   MkRCForeign <upstream conventions> <argument types> <result type>
     ->
   MkRCForeign ["RC2:idris2rc2_...Fixed"] [CFUser, ...] CFUser      (CFIORes CFUser for a PrimIO)
   ```

   `CFUser`は、ラッパが、すでにボックス化された値をそのまま受け渡す唯一の`CFType`である。`char *`も、コピーも、結果の変換もない。これが、リークとNULでの喪失の両方を取り除く。
2. **ほかの部分は何も知らない。** コンパイラの残りの部分から見えるのは、`RC2:`の呼び出し規約と不透明な引数を持つ`%foreign`であり、ほかの宣言と同じように扱われる。Cの出力器は通常のラッパを書く(C名は以前と同じなので、プリコンパイル済みの`.ttc`の中の呼び出し箇所も変更なしにリンクする)。ネイティブ型のパス(`DualABI`、`CalleeTable`)は、これに手を付けない。`CFUser`は決してアンボックスされないので、その生のC呼び出しが呼び出し箇所に置かれることはないからである。`PrimIO`の宣言は`PrimIO`の結果型を保つので、どの`PrimIO`の宣言とも同じく、`%World`のトークンはCの呼び出しから除かれる。`prim__setString`と`prim__getString`の置き換え先は、引数を4つではなく3つ取り、unitとして`NULL`を返す。
3. **引数の個数が違う宣言には手を付けない。** そのため、同じ名前と名前空間でも形の違う関数が壊されることはない。

別の関数をリダイレクトするには、次のようにする。`ForeignDivert.idr`の表に行を追加する(名前空間、基本名、引数の個数)。ボックス化された値を受け取る置き換え先を`idris2rc2_strings.c`か`idris2rc2_buffer.c`に書き、`idris2rc2_strings.h`で宣言する。`rc2/tests/Test169Strings/StringNul`(NULのケース)かリークのテストにケースを追加する。最後に、上の表に行を追加する。

## 元のリーク

`fastPack : List Char -> String`と`fastConcat : List String -> String`は、`%foreign "RefC:fastPack"`/`"RefC:fastConcat"`として宣言されており、戻り値の型は`CFString`である。このため`Compiler.RC2.Emit`の汎用FFIラッパのコード生成(ほかのすべての`%foreign`宣言が通る経路)は、C実装が返した`char *`を`idris2rc2_mkString`(`rc2/support/rc2/memory.c`)で新しい`IDRIS2RC2_String`にコピーして包む。しかし元のポインタは解放しない。

通常のケースでは、このプロトコルが正しい。本物の外部ライブラリが返す`char *`(たとえば`curl_easy_strerror`)は、ライブラリ側が所有しているので、呼び出し側が解放してはならない。しかし`fastPack`/`fastConcat`に限っては誤りである。どちらも、このプロジェクト自身が所有するバッファを`malloc`する(`rc2/support/rc2/idris2rc2_strings.c`の`fastPack`/`fastConcat`)。このバッファは一度コピーされたら捨てられるだけのものである。ところが`CFString`を返すforeign関数は、返すバッファが借り物でも自前の所有物でも、見た目が同じである。汎用ラッパは、FFIシグネチャだけからはこの違いを区別できない。

## 最初の修正案: `Prelude.Fix.RC2`と`%transform`(不十分)

最初の修正では、リークしない置き換え関数`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`を追加した(どちらも今も`idris2rc2_strings.c`にある)。これらは、新しい`IDRIS2RC2_String`に直接構築し、すでに完成した`IDRIS2RC2_Value *`を返す。途中に`char *`が現れないので、コピーしてリークするものがない。これらを組み込むために、`libs/rc2base/src/Prelude/Fix/RC2.idr`というモジュールを用意した。上流Idris2の`%transform`の仕組みを使って、`fastPack`/`fastConcat`の呼び出しを修正版の呼び出しに書き換える。

この方法は動いたが、そのモジュールを明示的に`import`したプログラムでしか効かなかった。原因は、モジュールの書き方のバグではなく、仕組み上避けられない制約にある。`%transform`が書き換えるのは、書き換えを定義する側のエラボレーション/importのスコープ内にある呼び出し箇所だけであり、書き換えが行われるのはエラボレーション時である。別パッケージが個別にコンパイルして`.ttc`に焼き込んだ呼び出し箇所には届かない。書き換えは、呼び出しをエラボレートする時点でスコープ内になければならない。ところが`network`/`base`がエラボレートされて`.ttc`として配布されたのは、このプロジェクトの`%transform`ルールがそれらのスコープに入りうるよりずっと前だった。

その結果、`verify.sh`に`KNOWN_LEAK_BYTES`のエントリを持つテストが2つ残った。どちらも、呼び出し側が何を`import`しても、フロントエンド側からは直せない。

- `Test35NetworkLoopback`: `network`自身の`Network.Socket.Data.parseIPv4`が内部で`fastPack`を呼ぶためにリークする。
- `Test37SystemMisc`(旧`Test40SystemProcess`): `base`自身の`System.File.ReadWrite`の`fRead'`が内部で`fastConcat`を呼ぶためにリークする。

## 修正: 宣言を書き換える

フロントエンドからはこれらの呼び出し箇所に届かないので、修正はrc2自身のバックエンドに置く。rc2のバックエンドは、コンパイルするプログラムの`RCDef`全体を、どのパッケージ由来の定義かを問わず処理する。そこで行う変更は、プリコンパイル済みの`network`/`base`のコードに焼き込まれた呼び出し箇所を含めて、すべての呼び出し箇所に作用する。それらのパッケージを再コンパイルする必要はない。

最初はC出力時に行っていた。`Emit/Foreign.idr`の表、シグネチャの形の検査、専用のラッパ(`emitFastPackFixedWrapper`)である。これはStringだけを扱う関数については動いた。しかし、`Int`や`Buffer`を受け取る`Data.Buffer`の関数が一覧に加わると、スカラの`%foreign`の生のC呼び出しが、デュアルABIのパスによって依然として呼び出し箇所に置かれた(`strlen(...)`は`strlen(...)`のまま残った)。リダイレクトする関数をそこから外すには、`DualABI`と`CalleeTable`に一覧を教える必要があった。代わりに、一覧を1か所に移した。`divertForeign`が早い段階で宣言そのものを書き換えるので、出力と最適化の3つのパスには特別なケースが要らない(専用のラッパ、形の検査、`DualABI`/`CalleeTable`の2つの例外はなくなった)。「何を置き換えるのか、なぜ置き換えるのか」を参照する。

基本名だけでなく名前空間まで検査するのは、防御的な選択である。基本名だけの照合では、将来、別の名前空間にたまたまこれらと同じ基本名を持つ無関係な関数が現れたときに、誤ってリダイレクトしてしまう。

`Test35NetworkLoopback`の実際の生成Cを調べて確認した。`network`自身のプリコンパイル済み`parseIPv4`の呼び出し箇所(このパッケージは再コンパイルしていない)に対して出力された`Prelude_Types_fastPack`ラッパは、`idris2rc2_fastPackFixed`を呼び、リークは消えた。

## `fastUnpack`と`Data.String.Iterator`への拡張: リークではなく、埋め込みNULへの対策

`fastUnpack`、`Data.String.Iterator.uncons`、`Data.String.Iterator.withIteratorString`も、同じ仕組みでリダイレクトしている。ただし理由は上記のリークとは無関係である。この3つはどれもリークしない。上流の`%foreign`宣言は、文字列を素の`char *`として受け取る(`fastUnpack(char *str)`、`stringIteratorNext(char *s, ...)`、`stringIteratorToString(void *a, char *str, ...)`。これらは今も`idris2rc2_strings.h`/`.c`にある)。rc2の`String`は埋め込みNULバイトを持てるようになった(`rc2/doc/constructor-layout.md`の "Strings")。そのため、これらの関数に`->str`だけを通して読ませると、最初の埋め込みNUL以降がすべて、気づかないうちに失われる。`fastUnpack "ab\NUL1cd"`は`"ab"`だけに展開されてしまう。`Data.String.Iterator`自身のfoldも同じ位置で止まる。

`idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/`idris2rc2_stringIteratorToStringFixed`(`idris2rc2_strings.c`)は、この問題を、`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`が上記のコピーとリークを避けたのと同じ方法で解決する。`IDRIS2RC2_Value *`自体を受け取って`IDRIS2RC2_String *`にキャストし直し、NULに出会うまで`->str`を読む代わりに、`->len`バイトだけを読む。回帰テストは`rc2/tests/Test169Strings/StringNul`である。リダイレクトしたすべての関数と、`Data.TextBuffer.fromString`(別の仕組みでCに到達する。`libs/rc2base/README.md`の`Data.String.RC2`/`Data.TextBuffer`の説明を参照)を、埋め込みNULバイトを含む`String`に対して検査する。

上記の`fastPack`/`fastConcat`と違って、`fastUnpack`/`stringIteratorNext`/`stringIteratorToString`には`idris2rc2_strings.h`の`deprecated`属性を付けていない。これらに到達してもリークにはならず、最初の埋め込みNULで黙って切り捨てられるだけである。「ここには到達しないはずだ」というビルド時の合図を付ける対象になる状況が、そもそもない。リダイレクトされた呼び出し箇所をこの切り捨てから守っているのは、ここでのリダイレクトだけである。

## `Data.Buffer`の文字列プリミティブと`Libraries.Data.String.Iterator`への拡張

コンパイラをrc2でビルドしたことで見つかった(`rc2/doc/self-hosting.md`)。StringリテラルにNULを含むプログラム(`rc2/tests/Test169Strings/StringNul`)に対して、rc2でビルドしたコンパイラは、Chezでビルドしたコンパイラと異なるCを出力した(差分は1190行)。Stringの定数が`.ttc`のコードの中で切り詰められていた。このコードは、`Data.Buffer.stringByteLength`、`prim__setString`、`prim__getString`でStringを書き込み、読み出す。これらの`RefC:`の実装は`char *`を扱う(`setBufferString`は長さを`strlen`で求める。`getBufferString`は`strncpy`でコピーしてC文字列を返し、ラッパがそれを`strlen`で`String`にする)。そして`stringByteLength`は、libcの`strlen`そのものである。

この3つも、ほかと同じようにリダイレクトする。置き換え先は`idris2rc2_stringByteLengthFixed`、`idris2rc2_setBufferStringFixed`、`idris2rc2_getBufferStringFixed`である(`idris2rc2_buffer.c`。このファイル自身の`assert_valid_range`で範囲を検査できる)。これらはボックス化された`String`、`Int`、`Buffer`を受け取り、`->len`を使い、`Int`、`NULL`(unit)、`String`をボックス化して返す。

これにともなって、仕組みを1つ変えた。最初は置き換え先に到達しなかった。`DualABI`と`CalleeTable`が、スカラの引数か結果を持つforeign関数の生のC呼び出しを、呼び出し箇所に置いていた(`RAppFFIInline`)。そのため`strlen(...)`がそのまま残り、置き換えたラッパは一度も呼ばれなかった。これらのパスに特別なケースを入れると、一覧がそれらのパスにまで広がってしまう。そこで置き換えを、宣言の書き換え(`ForeignDivert`)に変えた。これらのパスはその中を見通さない。不透明な(`CFUser`の)宣言がインライン化されることはないからである。代償として、これらの関数は生のC呼び出しとしてインライン化されなくなり、呼び出しはラッパを経由する。

`Libraries.Data.String.Iterator`は、コンパイラ自身が持つ`Data.String.Iterator`のコピーである(使うのは`Core.Hash`だけである)。その`uncons`と`withIteratorString`は同じ形をしており、同じ2つの置き換え先に向かう。

変わる動作: `getString`は、最初のNULまでのバイトではなく、要求したバイト数をちょうど返す(Chezバックエンドでの意味)。`setString`は、`String`のすべてのバイトを書き込む。

`rc2/tests/Test169Strings/StringNul`には、NULとその後ろの数字を含む往復のテストがある。`rc2/tests/selfhost.sh diff`は、`rc2/tests`全体について、Chezでビルドしたコンパイラとrc2でビルドしたコンパイラが出力するCを比較する。

## `Prelude.Fix.RC2`の廃止

`libs/rc2base/src/Prelude/Fix/RC2.idr`は削除した(`rc2base.ipkg`の`modules`から除き、不要になった`rc2/tests/Test28Utf8Strings.idr`の`import`も除いた)。リダイレクトは、`%transform`モジュールが扱えた呼び出し箇所をすべて扱え、そのモジュールが届かなかった箇所も扱えるので、厳密により汎用的である。オプトイン式のモジュールを残しても冗長なだけである。

## `deprecated`属性を残した理由

`idris2rc2_strings.h`は今も`fastPack`/`fastConcat`を`__attribute__((deprecated(...)))`付きで宣言しており、`rc2/src/Compiler/RC2/CC.idr`は、生成したCをコンパイルするときに今も`-Wno-error=deprecated-declarations`を渡している。リダイレクトによって、実際にはこれらに到達しないはずになったが、整理せずに、安全網としてあえて**残した**。

理由は次のとおり。リダイレクトが保証するのはコード生成のレベルであり、型レベルの保証ではない。将来`ForeignDivert.idr`を変更して`divertedFunction`の照合が狭まったり、リダイレクトが壊れたりしても、すぐに気づける仕組みはない。そうなると、生成コードは上流の宣言のまま残り、本物のリークする`fastPack`/`fastConcat`をまた呼び始める。見た目は正しく動いているのに、リークしている状態である。`deprecated`属性を残しておけば、この退行は**ビルド時の警告**として再び現れる。`-Wno-error=deprecated-declarations`フラグが明示されているので警告がエラーになってビルドが止まることはないが、ビルドの出力を読む人には見える。何も残さなければ、`valgrind`でたまたま再発見するまで、黙ったリークになる。両方の属性メッセージは(実装したセッションが)更新済みで、これらに到達するのは、呼び出し側が回避すべきものではなく、リダイレクトに関するrc2のバグだと示すようになっている。

## 途中で見つかった2つ目のバグ: 空文字列でのSIGSEGV

当初の計画にはなかった。リダイレクトによって`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`がプロジェクト全体で無条件になったあと、検証中に見つかった。

**根本原因**: この2つの関数は、`idris2rc2_mkEmptyString(byteLen + 1)`のあとで、明示的に`r->str[byteLen] = '\0'`を実行していた(`byteLen`/`total`は計算した出力長)。入力が空の場合(`byteLen == 0`。たとえば`pack []`/`concat []`)、`idris2rc2_mkEmptyString(1)`は新しいバッファを割り当てない。共有の不死(immortal)な`const`の静的値`idris2rc2_emptyStringValue`を返す。この場合の`r->str[0]`への書き込みは、読み取り専用メモリへの書き込みになる。

`Prelude.Fix.RC2`経由のオプトインにとどまっていたあいだは、この問題は表に出なかった。既存のimport側のコードは、修正済みの経路で`pack []`/`concat []`を呼んでいなかったからである。リダイレクトによって、これらがすべてのプロジェクトで無条件になると、まさにこの呼び出しをする`refc-suite`の`strings`テストがSIGSEGVでクラッシュした。

**修正**: 末尾のNULの書き込みを2か所とも削除した。`idris2rc2_mkEmptyString`がmallocする経路は、バッファ全体をすでに`memset()`でゼロにしている。したがって、終端バイト(コピーのループが最後に書くバイトの直後)は、明示的に書かなくても、もともと正しい値になっている。この形は、`idris2rc2_strings.c`のほかの`idris2rc2_mkEmptyString`の呼び出し側(`idris2rc2_strTail`/`strReverse`/`strCons`/`strAppend`/`strSubstr`)がすでに従っているパターンと同じである。これらのいずれも、`memcpy`した自身のペイロードを越えた添字書き込みをしていない。

## 検証手順

1. `rc2/tests/verify.sh`全体: 82件成功、既知の失敗0件、失敗0件。
2. `libs/rc2base/tests/verify.sh`全体: すべてPASS。
3. `Test35NetworkLoopback`(`parseIPv4`を呼ぶ、手を加えていないプリコンパイル済みの`network`パッケージの呼び出し箇所)の実際の生成Cを調べ、`Prelude_Types_fastPack`ラッパが`idris2rc2_fastPackFixed`を呼んでいることを確認した。`network`/`base`の再コンパイルはどこにも必要なかった。
4. `verify.sh`の`KNOWN_LEAK_BYTES`マップは、今は本当に空である。`Test35NetworkLoopback`/`Test37SystemMisc`(当時は`Test40SystemProcess`)のエントリを削除し、どちらもリークが0バイトであることを確認した。(`Test35NetworkLoopback`が`NO_REFC_DIFF_TESTS`に残っているのは、この修正とはまったく無関係で、まだ解決していない別の理由による。本物のRefCだけで起きるコンパイルバグで、`parseIPv4`自身が生成するcast関数名の大文字小文字の不一致である。)
5. 新しい回帰テスト`rc2/tests/Test46FastPackUnconditional.idr`(と`.expected`)は、importを一切オプトインせずに`pack`/`concat`を呼ぶ。`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録済みで、リークがないことを確認した。このテスト自身のモジュールコメントは、空文字列のケースにも暗黙に触れているが、`pack`/`concat`を空でないリストに対して呼ぶだけである。空入力でのSIGSEGVを捕らえたのは、新しい専用テストではなく、すでにあった`refc-suite`の`strings`テストだった。このテストがたまたま`pack []`/`concat []`を実行していたからである。

## ファイル

- `rc2/src/Compiler/RC2/ForeignDivert.idr`: 表(`diverted`)と書き換え(`divertForeign`、`divertedFunction`)。`rc2/src/Compiler/RC2/RC.idr`の`normalizeTop`から呼ばれる。どの関数を置き換えるかを知っている唯一の場所である。
- `rc2/support/rc2/idris2rc2_buffer.c`: `idris2rc2_stringByteLengthFixed`、`idris2rc2_setBufferStringFixed`、`idris2rc2_getBufferStringFixed`。
- `rc2/support/rc2/idris2rc2_strings.c`: `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`(空文字列の末尾NUL書き込みの削除)、`idris2rc2_fastUnpackFixed`/`idris2rc2_stringIteratorNextFixed`/`idris2rc2_stringIteratorToStringFixed`(`fastUnpack`/`Data.String.Iterator.uncons`/`withIteratorString`を埋め込みNULに対して安全にした置き換え)。
- `rc2/support/rc2/idris2rc2_strings.h`: `fastPack`/`fastConcat`に残した`deprecated`属性(メッセージは、これらに到達することを、呼び出し側の回避策ではなくrc2のバグとして説明するように更新した)と、上記の`*Fixed`置き換え関数の宣言。
- `rc2/support/rc2/idris2rc2_datatypes.h`: `IDRIS2RC2_String`自身の`len`フィールド。`fastUnpack`/`uncons`/`withIteratorString`をリダイレクトする必要が生じた、そもそもの原因である(`rc2/doc/constructor-layout.md`の "Strings")。
- `rc2/src/Compiler/RC2/CC.idr`: 残した`-Wno-error=deprecated-declarations`フラグ。
- `rc2/tests/Test46FastPackUnconditional.idr`: 元のリーク修正の回帰テスト。
- `rc2/tests/Test169Strings/StringNul.idr`: リダイレクトした関数(`fastPack`/`fastUnpack`、イテレータ、`Data.Buffer`の3つ)を、埋め込みNULバイトを含む`String`に対して検査する回帰テスト。
- `rc2/tests/selfhost.sh diff`: Chezでビルドしたコンパイラとrc2でビルドしたコンパイラが出力する、`rc2/tests`のCを比較する。
- `libs/rc2base/src/Prelude/Fix/RC2.idr`: **もう存在しない**(廃止。`rc2base.ipkg`の`modules`から除き、`rc2/tests/Test28Utf8Strings.idr`のimportも除いた)。
