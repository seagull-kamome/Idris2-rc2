# rc2のディレクティブ機構(`--directive VALUE` / `%cg rc2 <directive>`)

(原文: `doc/directives.md`。内容が乖離した場合は原文を正とする。)

rc2が認識するすべてのディレクティブのリファレンスである。各ディレクティブの働きと存在理由、実際の渡し方を説明する。`doc/reading-the-ir.md`の姉妹編にあたる。そちらは`dumprcexpr`の*出力*形式を詳しく扱う。本書が扱うのは、ディレクティブの仕組みそのものと、その上に作られたすべてのディレクティブである。

## 1. 仕組み

Idris2には、バックエンドに依存しない汎用のソースプラグマ`%cg <codegen> <directive>`がある。このプラグマは、パースされ、推移的なimportをまたいで集約され、TTCに永続化される。同じく汎用の、繰り返し指定できるCLIフラグ`--directive VALUE`もある。どちらも上流の汎用の仕組み(`Core.Context.addDirective`/`cgdirectives`と`Idris.Session`のCLIパース)であり、本書で扱うどのディレクティブ(rc2専用のものを含む)も、idris2-srcに変更を加えずに実現できた。`Compiler.RC2.RC2.compileExpr`は、rc2自身が登録したコードジェネレータ名`Other "rc2"`を使って、`getDirectives (Other "rc2")`で両方の入力元の和集合を冒頭で一度だけ読み込む。結果は1つの`directiveList : List String`に入り、以下のディレクティブはすべて、この`directiveList`に対して検査される。

```idris2
%cg rc2 noloop
%cg rc2 dumprcexpr
%cg rc2 extraRuntime=path/to/helpers.c
```

```sh
idris2-rc2 --cg rc2 --directive noloop --directive dumprcexpr Program.idr -o program
```

本物の上流RefCは、`--directive`/`%cg`をまったく読まない(`idris2-src/src/Compiler/RefC/RefC.idr`に`getDirectives`/`getSession`を呼ぶ箇所はない)。したがって、本書のすべてのディレクティブは、挙動がrc2専用であるか、(`extraRuntime`のように)RefCがたまたま使っていない汎用の仕組みをrc2が利用しているものである。

## 2. パイプライン段階の無効化(`no<stagename>`)

A/Bの回帰切り分けのための機能である。たとえば「この差異やリークは、特定の1つのパスに起因するか」を調べたいとき、`Compiler.RC2.RC2.toRCDefs`を編集して`idris2-rc2`を手作業で再ビルドする必要がなくなる。各段階は純粋に追加的でオプションである。段階を飛ばしても、*正しい* Cは生成されるはずである(最適化は弱くなり、本物の`idris2 --cg refc`の出力の形と、バイト単位では一致しなくなる場合もある)。下流のどの段階も、正しさのためにその段階を必要とはしておらず、必要とするのは、その段階が提供する最適化だけである。粒度は意図的に粗い。段階全体のオン/オフの切り替えであり、関数やノード単位の細かい制御ではない。

| ディレクティブ | 無効にするもの |
|---|---|
| `noinline` | `Compiler.RC2.InlineCExp`のプログラム全体のインライン化(ラムダリフティングの前に走る)。2つの基準が両方とも無効になる。1つは、呼び出しを含まない小さな呼び出し先を、すべての呼び出し箇所でインライン化するもの。もう1つは、ループを含まない呼び出し先を、唯一の呼び出し箇所でインライン化するもの。その後のcase-of-caseの畳み込みも無効になる(`doc/inlining.md`)。 |
| `noconstfold` | `Compiler.RC2.ConstFold`のプログラム全体の不動点畳み込み。算術、比較、コンストラクタ、クロージャ、CAFの畳み込みと、定数`ExtPrim`の畳み込み(`prim__codegen`)が含まれる。定数`ExtPrim`の畳み込みは、`Compiler.RC2.ConstExtPrim`パスを統合して以降、このディレクティブでも無効になる。 |
| `noknowncon` | `Compiler.RC2.ConstFold`の既知コンストラクタの畳み込みだけを無効にする。これは、同じ関数内で構築された、エスケープしないコンストラクタに対する`case`を解決し、構築そのものを消すものである(`doc/constructor-escape-analysis.md`の "Rewrite A")。そのクロージャ版(エスケープしない部分適用に対する、飽和した`apply`を、直接呼び出しに変える)も無効になる。`ConstFold`のそれ以外の部分は、引き続き走る。`noconstfold`が暗黙に含む。`Compiler.RC2.SpecClosure`が自分で畳み込むクローンは、この畳み込みを保つ。 |
| `nopushcon` | `Compiler.RC2.PushCon`。これは、`case`を、スクルティニーとなる値の各末尾へ押し込み、コンストラクタを構築する各末尾がそれ自身のaltだけに出会って畳み込まれるようにする(`doc/constructor-escape-analysis.md`の "Rewrite B")。押し込みはConstFoldが仕上げることを前提にしているので、`noconstfold`が暗黙に含む。 |
| `nospecclosure` | `Compiler.RC2.SpecClosure`の、投機的な、採算が見込める場合に限って行うクロージャ引数の特殊化。呼び出し箇所で観測した、クロージャのターゲットごとに関数を複製し、`apply`を直接の`call`に解決する(`doc/speculative-closure-specialization.md`)。 |
| `nospecconstcon` | `Compiler.RC2.SpecClosure`の、定数コンストラクタ引数の特殊化。呼び出し箇所で観測した、定数ディクショナリごとに呼び出し先を複製し、分解する`case`を畳み込んで消し、各メソッドの`apply`を直接の`call`に解決する(`doc/constant-constructor-specialization.md`)。同じモジュールにあるが、`nospecclosure`とは別のスイッチである。特殊化の対象とする引数の形が異なるからである。 |
| `noconaltnative` | `Compiler.RC2.ConAltNative`のネイティブシャドウによるフィールドキャッシュ(`doc/con-alt-native.md`)。 |
| `nomutualloop` | `Compiler.RC2.MutualLoop`の相互末尾再帰のマージ。 |
| `noloop` | `Compiler.RC2.Loop`の、自己末尾呼び出しから`goto`への変換と、ネイティブシャドウ/ループ不変式の昇格(`doc/loop-conversion.md`)。 |
| `noearlyinline` | `Compiler.RC2.LateInline`の、呼び出し元が1つだけの関数のスプライシングのうち、早期に走る実行。SpecConstConの直後、RCアノテーションの前に走り、その後、結果に対してConstFold/PushConで畳み込み直す(`doc/constructor-escape-analysis.md`の "The shapes `LateInline` creates")。CAFは決してスプライスしない。`nolateinline`と`noconstfold`が暗黙に含む。 |
| `nolateinline` | `Compiler.RC2.LateInline`の、プログラム全体で呼び出し元が1つだけの関数のインライン化。Loop/MutualLoopの変換の後に走る(`doc/inlining.md`の "Criterion B, revisited")。 |
| `nosink` | `Compiler.RC2.Sink`の枝ローカルなsinking(`doc/branch-sinking.md`)。 |
| `nodualabi` | `Compiler.RC2.DualABI`のワーカー/ラッパの合成と、呼び出し箇所の書き換えの*両方*をまとめて無効にする。書き換えは、合成の段階が作るワーカーの表を必要とするので、両者を分けても意味がない(`doc/dual-abi.md`)。 |
| `noapplyfold` | `LateInline`の直後に走る`Compiler.RC2.ArityRaise.applyFoldApplied`。構築と同時に適用されるクロージャ(それ以外ではdropされるだけのもの)を、呼び出しに変える(`doc/world-arity-raising.md`の "Post-RC fold")。 |
| `nodeadargs` | `Compiler.RC2.DeadArgs`。唯一の使用が別の死んだパラメータへ渡すことだけであるパラメータと、すべての呼び出しでのその引数を取り除く(`doc/dead-args.md`)。インクリメンタルコンパイルでは常に無効である。 |
| `noarityraise` | `Compiler.RC2.ArityRaise`。もう1つの引数(world)を待つクロージャを返す関数に、その引数を取るバージョンを作り、クロージャをすぐに適用する呼び出しが、そのバージョンを呼ぶようにする(`doc/world-arity-raising.md`)。 |
| `notrmc` | `Compiler.RC2.Trmc`。再帰呼び出しがコンストラクタの下にある関数(`x :: f xs`)に、前のセルの穴を埋めてループする、アキュムレータ付きの双子の関数を作る(`doc/trmc.md`)。 |
| `noctx` | `Compiler.RC2.ClosureCtx`。自己呼び出しのたびに`c . (y ::)`で拡張され、最後に一度だけ適用されるパラメータを、開いた穴を持つセルの連鎖に変える(`doc/closure-accumulator.md`)。 |
| `nostructreturn` | `Compiler.RC2.DualABI`の構造体返却(`applyStructReturn`)。すべての末尾が最大4フィールドのコンストラクタで、呼び出し元のどれかが恩恵を受ける関数に、`IDRIS2RC2_Ret1`〜`IDRIS2RC2_Ret4`の構造体を返すワーカーを作る。結果をすぐにswitchする呼び出しは、そのワーカーに到達する(`doc/struct-return.md`)。`nodualabi`が暗黙に含む。 |
| `nodeadcode` | `Compiler.RC2.DeadCode`による、呼び出し元が1つも残っていない定義の削除(`doc/dead-code-elim.md`)。 |
| `nodupmerge` | `Compiler.RC2.DupMerge`による、複数の個別の`RDup`ノードを、`extra`の大きい1つの`RDup`にまとめる処理と、`cancelDupDrop`のピープホール最適化(ある`RDup`のローカル変数を、参照カウントだけの同じ連なりの中の`RDrop`が再び解放する場合に、両者を打ち消す)。 |

この一覧に入りそうで、入らないディレクティブがある。

- **`noreuse`は廃止されており、単に記載が漏れているわけではない。** かつては`Compiler.RC2.Reuse`を無効にするものだった。しかし無効にすると、ほとんどのスモークテストで確実にヒープが壊れ、根本原因は診断されないままだった。現在`applyReuse`は常に無条件で走る。今日`--directive noreuse`を渡しても、ほかの認識されないディレクティブ文字列と同じく、害のないno-opになる。2026-09-25に、有力な根本原因が見つかった。`Reuse`の`resolveReuse`は、`annotate`が`Reuse`に任せているフィールドの`dup`(`dupOnSurvive`)も挿入する。そのため`Reuse`がないと、スクルティニーをdropしたあとで読まれるフィールドは、自分自身の参照を持たない。これは、`refc-suite/clock`で、同じ関数の`RMemoize`ケースが欠けていたために生じた解放後使用と同じ現象である(`doc/caf-memoization.md`)。
- **`latepushcon`は、唯一のオプトインの段階である。** `Compiler.RC2.PushCon`のRC後の押し込み(`applyPushConRC`)を、あとの`LateInline`の実行の直後に*有効にする*。同じ、caseを末尾へ押し込む処理だが、既知の各末尾を、明示的な所有権の移転によって、そのaltに対して畳み込む(`doc/constructor-escape-analysis.md`の "What is left after Early inline, and the RC-aware fold")。デフォルトで無効なのは、idris2-lspでは243個の末尾を畳み込むものの、静的なコンストラクタの数が変わらないからである。実際のワークロードで測定できるように残してある。デフォルトのスイートはこれを実行しないので、この部分に手を入れたあとは`verify.sh --directive latepushcon`を実行すること。無効化のディレクティブと同じリストで渡される(`RC2.idr`の`optInStageNames`)。
- **`nomain`は、現在も使える本物のディレクティブだが、パイプライン段階の無効化ではない。** `compileExpr`で、独立した素の`Bool`として直接読まれ、`toRCDefs`/`disabled`を通らない。制御するのは、`Compiler.RC2.Emit`の`footer`がCの`main()`を出力するかどうかだけである。このディレクティブが想定する、端から端までのシナリオ(`%export`したプログラムを、独自の`main`を提供する手書きのCドライバにリンクする)は、後述の第5節と`doc/export-support.md`の "Linking as a library" を参照する。生成される`main()`は、ランタイムのライフサイクルフックを呼ぶ場所でもある。したがって、`nomain`のドライバは、`idris2rc2_rtInit()` / `idris2rc2_rtFinish()`を自分で呼ばなければならない(`doc/runtime-lifecycle.md`を参照)。
- **`multithreaded`** は、生成される`main()`が、`idris2rc2_rtInit()`の直後に参照カウントをアトミック操作へ切り替えるようにする。ランタイムから見えない場所でスレッドが始まるプログラム向けである(`doc/hybrid-refcount.md`)。`nomain`のドライバは、代わりに`idris2rc2_enableMultiThreading()`を自分で呼ぶ。

## 3. デバッグダンプのディレクティブ

4つとも`directiveList`を共有する。検査は、`toRCDefs`がすでに結果を生成した*あと*に行われる(第2節の段階の無効化は、`toRCDefs`自身が走る*前*に参照する必要があり、この点が異なる)。

- **`dumprcexpr`**: 無効にされなかったすべてのパイプライン段階を経た最終的な`RCExp`を、`.c`の出力の隣の`.rcexpr`ファイルにダンプする。形式のリファレンスと読み方は`doc/reading-the-ir.md`を参照する。
- **`dumpdualabi`**: `Compiler.RC2.DualABI`のStage 2の適格性解析を、`.dualabi`ファイルにダンプする。仕組みは`dumprcexpr`と同じである。`doc/dual-abi.md`を参照する。1行目には、値で返す資格のある関数の数が出力され、そのような関数の行は、末尾が` ret1`で終わる(`doc/struct-return.md`)。
- **`dumpcc`**: これから実行するCのコンパイル/リンクコマンドを、そのまま標準出力に出力する。
- **`dumplifts`**: リフトされた定義を、その元となったトップレベル定義、ラムダだったか`Delay`(`LazyReason`つき)だったか、自身のパラメータ数とともに列挙する`.lifts`ファイルを書き出す。`doc/lambda-lifting.md`を参照する。

## 4. コード注入のディレクティブ

2つのディレクティブが、任意のCを、生成される`.c`に直接スプライスする。位置は、`#include`の直後で、生成された定義より前である(`Compiler.RC2.Emit`の`header`)。そのため、注入したコードはrc2自身のランタイム型(`IDRIS2RC2_Value`など)を使え、その後ろの生成された関数本体から呼び出せる。

```idris2
%cg rc2 extraRuntime=path/to/helpers.c
%cg rc2 inlineRuntime=int64_t helper(int64_t x) { return x * 2; };
```

- **`extraRuntime=<path>`** は、ファイル全体を読み込み、その内容をそのまま挿入する。Chezバックエンドが`%cg chez extraRuntime=file.ss`で使っているのと同じ汎用のディレクティブ(および同じ`Compiler.Common.getExtraRuntime`)である。
- **`inlineRuntime=<code>`** は、ファイルの代わりにテキストを直接渡せる、rc2独自の相方である(上流に対応するものはない)。

### `inlineRuntime`の2つの落とし穴

どちらもIdris2自身の汎用の`%cg`レキサ/パーサに内在する問題であり、idris2-srcに手を入れなければ直せない。特定のディレクティブの値に固有の問題ではない。複数行にわたる、あるいは波括弧で終わる`%cg`ディレクティブのテキストなら、rc2が定義したものかどうかにかかわらず、同じ目に遭う。

1. **1行に収めなければならない。** 波括弧つきの形式`%cg name { ... }`は、*最初の*リテラルの`}`で止まり、ネストをサポートしない。本物のCの関数本体は`}`を含むので、気付かないうちに途中で切り捨てられる。`inlineRuntime=`の直後に(`{`ではなく)コードを書くと、レキサの、波括弧なしのもう一方のフォールバックに当たる。これは行の残りを、波括弧の対応を見ずにそのまま取り込む。ただし、すべてが1行にある場合に限る。
2. **リテラルの`}`で終わってはならない。** `Idris.Parser`の`stripBraces`は、どの形式のレキサが作ったかにかかわらず、*あらゆる* `%cg`ディレクティブの取り込んだテキストから、末尾の`}`を1つ(と先頭の`{`を1つ)、無条件に取り除く。本物の関数本体の閉じ括弧と、波括弧つきの形式の区切りを、区別できない。Cの関数定義は必ず`}`で終わるので、これが気付かないうちに削られ、壊れたCが、ずっと後のgccの段階で、本当の原因から遠いところで初めて失敗する。関数自身の`}`の後ろに`;`(害のない、空のトップレベルC宣言)を置くと回避できる。その`;`が新しい最後の文字になるからである。1行のスニペットより長いものや、込み入ったものには、`extraRuntime=`と本物のファイルを使う。

### 自然な組み合わせ: 素の`%foreign "C:funcName"`

どちらのディレクティブにも、自然な組み合わせは、*素の* `%foreign "C:funcName"`宣言である。lib/headerフィールドはまったく付けない。生成された1つの翻訳単位の中で、単純にテキストの順序によって、注入したコードを直接呼び出す。別の静的ライブラリをビルドしたり、`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`を配線したりする必要は、まったくなくなる。`libs/rc2base`自身のREADMEは、これと対照的である。そのCヘルパーは本物の別個の`.a`にあるので、そのすべてが必要になる。

## 5. 構造体typedefの抑制(`externStruct=<name>`)

`Compiler.RC2.Emit`の構造体収集パス(Part C。`doc/c-struct-support.md`の "Design" 節)は、`%foreign`定義の`Struct "name" [...]`型の引数/戻り値から到達できる、構造体名ごとに1つ、`typedef struct { ... } name;`を出力する。この出力は無条件であり、`name`がインクルードされたシステム/ライブラリのヘッダですでに`typedef`されているかは調べない。プログラム自身のprivateな構造体(`Test24CStructSupport`の`test_point`のようなもの)ではなく、実際のコードが結び付けたい構造体名は、すでにそのように定義されていることが多い。姉妹リポジトリ`idris2-curl`の`doc/version-info-struct.md`に実例がある。libcurlの`curl/curl.h`は、`curl_version_info_data`をすでに`typedef`している。両方のtypedefを同じ翻訳単位にコンパイルすると、`error: conflicting types for 'name'`で失敗する。このエラーを出すのはgccであり、rc2自身ではない。

```idris2
%cg rc2 externStruct=curl_version_info_data
%cg rc2 externStruct=some_other_struct_name
```

繰り返し指定でき、1回の指定につき1つの名前を渡す。名前を指定した構造体は、`header`のtypedef出力の段階でだけ、スキップされる。`StructDefs`(`RStructGet`/`RStructSet`がフィールドを解決する、フィールド名/型の表)は、まったくフィルタされない。したがって、その名前の`Struct`に対する`getField`/`setField`は、まったく通常どおりに動き、ほかの構造体と同じ`((name*)ptr)->field`というC式にコンパイルされる。

**この集合に含まれる名前については、Idris側のフィールドのリストは、純粋に名目上のものになる。** 通常(`externStruct`なし)は、このフィールドのリストが正式なものであり、rc2が生成する構造体の本当のフィールド順とレイアウトを、バイト単位で決める。名前を`externStruct`に指定すると、rc2はその名前のtypedefをまったく出力しなくなる。したがって`((name*)ptr)->field`は、インクルードされたヘッダが実際に提供する定義に対してコンパイルされる。Cコンパイラは、フィールドのオフセットを、*その*定義から解決する。Idrisの宣言の順序からは決して解決しない。そのため、`Struct`宣言のフィールド名と型は、結果のキャストが正しくなるように、本物の外部構造体のフィールドと合っている必要がある(名前が同じで、型が`cTypeOfCFType`の意味でCの型として互換であること)。しかし、宣言のフィールドの*順序*は、正しさには無関係である。本物の構造体のすべてのフィールドを列挙する必要もない。`getField`/`setField`の呼び出し箇所が実際に触る部分集合だけを、都合のよい順に並べればよい。

**フィールドの型が間違っていても検出されない。** `RStructGet`は、読み取った生のフィールドを、ボックス化する前に`cTypeOfCFType ty`にキャストする。本物のヘッダの余分な修飾子(`const char *ssl_version`を、Idris側では`AnyPtr`と宣言した場合など)で、ビルドが失敗しないようにするためである。同じキャストは、本物の不一致(幅の違い、符号の違い、形そのものの違い)も黙らせる。その結果、バインディングは、実行時に警告なしでゴミを読む。宣言した各型をヘッダと一致させるのは、バインディングを書く人の責任であり、`externStruct`を使うすべてのバインディングについて、レビュー時に確認すること。`Test120CStruct/CgExternStructPtrField.idr`は`const`のケースを検査する。

## 6. ディレクティブの実際の使い方

- `idris2-rc2`のコマンドラインに直接渡す: `--directive VALUE`。繰り返し指定できる(第1節の例を参照)。
- `rc2/tests/verify.sh`の`--directive VALUE`フラグ経由で渡す。繰り返し指定でき、`idris2-rc2`にそのまま転送される。テスト中に回帰を特定の1つのパスに切り分ける標準的な方法である。たとえば`--directive noloop`や`--directive noconstfold`を渡せば、実行のあいだに`toRCDefs`を手で編集して再ビルドする必要がない。

## 7. 動機となったスモークテスト

`rc2/tests/Test121CgRuntime/CgExtraRuntime.idr`(`extraRuntime=`)と`rc2/tests/Test121CgRuntime/CgInlineRuntime.idr`(`inlineRuntime=`)は、第4節のディレクティブの専用の回帰テストである。`rc2/tests/Test120CStruct/CgExternStruct.idr`は、第5節の専用テストである。付属するヘッダのコメントに、このディレクティブが避けるために存在する`conflicting types`の失敗が示されている。3つとも、`verify.sh`の`NO_REFC_DIFF_TESTS`に入っている。本物のRefCは`--directive`/`%cg`をまったく読まないので、食い違う共通のベースライン挙動がなく、`verify.sh`が行える意味のあるRefCとの比較もないからである。

## 8. 時間計測の診断(`timing`)

ほとんどのパスは、すでに自分の実時間を無条件に出力している。`logTime`/`logTimeOver`を、0でない閾値で呼ぶ方式であり、出力するかどうかは、上流の通常の`log`/ログレベルの仕組みで決まる。ここで述べるディレクティブは関係しない。たとえば`Compiler.RC2.RC2.toRCDefs`が、各段階の前後で呼ぶ`logTime 2 "rc2: ..."`を参照する。`Compiler.RC2.SpecClosure`自身の、パス全体レベルの4行(収集とグループ化、機会/キー/定義の件数、`rebuildCafTable`、`redirectAll`)だけが例外である。この4行は、もともと`O(distinct keys x program size)`の遅さを診断する際に、永続的に無条件で出力されるように残してあった(`log`/ログレベルも、ディレクティブも迂回する)。この遅さを直した経緯は`doc/speculative-closure-specialization.md`に書いてある。その調査はとうに終わっているので、今は`--directive timing`を指定したときだけ出力される(`applySpecClosure`の`maybeLogTimeOver`)。本書のほかのオプトインの診断と同じ扱いである。

```sh
idris2-rc2 --cg rc2 --directive timing Program.idr -o program
```

## ファイル

- `rc2/src/Compiler/RC2/RC2.idr`: `toRCDefs`の段階の無効化の配線、`compileExpr`の`directiveList`の取得とそこから読まれるすべてのディレクティブ、`getInlineRuntime`、`getExternStructs`。
- `rc2/src/Compiler/RC2/Emit/Util.idr`: `InjectedRuntime`(2つのコード注入のディレクティブが書き込む、`header`スコープの状態)。`ExternStructs`(第5節のもの)。
- `rc2/src/Compiler/RC2/SpecClosure.idr`: `maybeLogTimeOver`(第8節の`timing`のゲート)。
- `rc2/tests/Test121CgRuntime/`、`rc2/tests/Test120CStruct/`: 動機となったスモークテスト(第7節)。
