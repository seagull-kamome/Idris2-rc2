# C構造体FFIのサポート (`System.FFI.Struct`/`getField`/`setField`): 実装済み、回帰テスト付き

(原文: `doc/c-struct-support.md`。内容が乖離した場合は原文を正とする。)

上流のIdris2は、`System.FFI`モジュール (`idris2-src/libs/base/System/FFI.idr`) に`Struct`/`getField`/`setField`を用意している。これらは`prim__getField`/`prim__setField`というExtPrimで実装されており、Cの構造体への直接アクセスを提供する。加えて、`%foreign`の引数と戻り値に構造体を値渡しで使うこともできる (`Core.CompileExpr`の`CFStruct`)。Chezバックエンドは、この2つを完全にサポートしている。RefCはサポートしておらず、RefCのExtPrimのホワイトリストと`extractValue`/`packCFType`をそのまま写したrc2も、同じ欠落を引き継いでいた。

この文書は、次のことを記録する。

- 調査で確認できたこと。
- この欠落について、上流のissueトラッカーがすでに述べていること。
- 設計。下の「設計: 専用の`RStructGet`/`RStructSet`ノードを`Emit.idr`で解決する」の節にある。コードを書く前に、実際の`RCExp`と生成されたCの出力で検証した。
- 実装そのもの (`c-struct-support`ブランチ)。実際に何が完了したか、途中で見つけて直した問題は、下の「実装状況」を参照。

回帰テストは`rc2/tests/Test24CStructSupport.idr`である。このテストのために、`rc2/tests/verify.sh`を拡張して、テストごとに補助のCファイルを使えるようにした。補助のCが必要なのは、rc2でもChezでも、実際の`%foreign`シグネチャを通して構造体名を確立する必要があるためである。

## 確認できたこと

**`getField`/`setField`は、理論上だけでなく実際に、コンパイルは通るがCのコンパイル段階で失敗する。** RefCもrc2も、`prim__getField`/`prim__setField`を「既知の」ExtPrimとして受け入れる。RefCでは`cStatementsFromANF`の`AExtPrim`のケースにある`RefC.idr`の`prims`ホワイトリスト、rc2では`emitRC`の`RExtPrim`のケースにある`Emit.idr`の同じホワイトリストである。そして、呼び出しをそのまま (`idris2_prim__getField(...)`/`idris2rc2_prim__getField(...)`として) 出力する。ところが、`support/refc/`にも`rc2/support/rc2/`にも、この関数の定義はどこにもない。手で再現した結果は次のとおりである。

```idris2
module Main
import System.FFI

main : IO ()
main = do
  ptr <- malloc 16
  let s : Struct "my_struct" [("x", Int), ("y", Double)] = believe_me ptr
  let v = the Int (getField s "x")
  printLn v
```

このプログラムは`idris2 --cg refc`ではエラーなくコンパイルできるが、生成されたCはCのコンパイル段階で失敗する。

```
build/exec/t.c: In function ‘Main_main’:
build/exec/t.c:310:22: error: implicit declaration of function
  ‘idris2_System_FFI_prim__getField’ [-Wimplicit-function-declaration]
  310 |     Value * var_13 = idris2_System_FFI_prim__getField(var_14, NULL, NULL, var_1, var_15, var_16);
```

rc2の`Emit.idr`も、これに対応する`idris2rc2_System_FFI_prim__getField(...)`の呼び出しを出力し、やはり未定義になる。

**構造体の値渡しFFI (`%foreign`の引数や戻り値としての`CFStruct`) は、RefCでもrc2でも明示的に未実装である。** `Emit.idr`の`extractValue (CFStruct x xs) varName = idris_crash "INTERNAL ERROR: Struct access not implemented: ..."` (`Emit.idr:2295`) は、上流`RefC.idr:763`の同じクラッシュをそのまま写したものである。`packCFType`の`CFStruct`のケース (`Emit.idr:2319`) は、`makeStruct(...)`というヘルパーの呼び出しを出力する。このヘルパーは`rc2/support/rc2/`にも存在しない。上流のRefC.idr:788に由来し、そちらでも状況は同じである。

**`getField`/`setField`がANF/RCExpに届く時点で、フィールドの型情報は消去されている。** `prim__getField : {s : _} -> forall fs, ty . Struct s fs -> (n : String) -> FieldType n ty fs -> ty`は、構造体名`s`とフィールド名`n`に加えて、型レベルの引数を2つ (フィールドのリスト`fs`と結果の型`ty`) 持つ。先ほどの生成されたCの呼び出しでは、この2つがリテラルの`NULL`として現れている (`idris2_..._prim__getField(var_14, NULL, NULL, var_1, var_15, var_16)`)。これは推測ではなく、実際に生成コードを読んで確認した。残っているのは構造体名とフィールド名だけで、どちらも文字列リテラル (例の`var_15`/`var_16`、実体は`Str`定数) として残る。したがって、どんな実装も、**フィールドのCの型を、この2つの文字列だけからコンパイル時に解決しなければならない。** 実行時の呼び出し自体には、使える情報がない。

**Chezも、呼び出し箇所ではこの解決問題を解いていない。解決はChez Scheme自身のFFI型システムに委ねている。** `Compiler/Scheme/Chez.idr`の`mkStruct`は、すべての`%foreign`シグネチャの引数と戻り値の`CFType`を走査する。ある構造体名 (`CFStruct n flds`) を初めて見たときに、`(define-ftype n (struct [fld1 ty1] [fld2 ty2] ...))`を出力し、`Structs` refに`n`を記録して、1度しか定義されないようにする。続いて`chezExtPrim`の`GetField`/`SetField`のケースは、`(ftype-ref n (fld) structPtr)`と`(ftype-set! n (fld) structPtr val)`を出力するだけである。フィールドの型とオフセットは、その名前で登録済みの`define-ftype`から、Chez Scheme自身の`ftype-ref`/`ftype-set!`がマクロ展開時に解決する。**構造体のフィールドの型情報は、`Struct`/`CFStruct`に言及する`%foreign`シグネチャを通してのみ、バックエンドに届く。** `getField`/`setField`の呼び出し箇所だけを見ても、そのような情報はない。

## 構造体のフィールドの型は`Lifted`にどう現れるか

上の「`%foreign`を通してのみ」という主張を、Chezの挙動からの推測にとどめず正確に確認するために、コンパイラのソースで両側をたどった。

- **`%foreign`の定義は、完全な`CFType`情報を、`Lifted`に至るまで無傷で保つ。** `LiftedDef`のforeign定義のコンストラクタ (`idris2-src/src/Compiler/LambdaLift.idr:249`) は`MkLForeign : (ccs : List String) -> (fargs : List CFType) -> (ret : CFType) -> LiftedDef`である。`%foreign`シグネチャにある`CFType`そのもの (`flds`のフィールド名と型が完全に残った`CFStruct n flds`を含む) が、このコンストラクタのデータとして運ばれ、消去されることはない。rc2はこれをそのまま写している。`RCExp.idr`の`MkRCForeign : (ccs : List String) -> (fargs : List CFType) -> CFType -> RCDef`がそれであり、`RC.idr:244`の`normalizeDef (MkLForeign ccs fargs ret) = pure $ MkRCForeign ccs fargs ret`は、変更なしの単純なコピーである。`Lifted`から`RCExp`への変換で、情報は失われない。
- **通常の呼び出し箇所 (`getField`/`setField`、またはほかの`ExtPrim`) は、構造上、型情報をまったく持たない。** `Lifted`の`LExtPrim`コンストラクタ (`idris2-src/src/Compiler/LambdaLift.idr:128`) は`LExtPrim : FC -> (lazy : Maybe LazyReason) -> (p : Name) -> (args : List (Lifted vars)) -> Lifted vars`である。持っているのはプリミティブの名前と値の式のリストだけで、`CFType`の入る場所はコンストラクタのどこにもない。これが、`prim__getField`の2つの型レベルの引数 (`fs`、`ty`) が、生成されたCに実行時の`NULL`として現れる理由である (上記を参照)。消去が走った時点で、その情報が`LExtPrim`の形の中に居場所を持つことはなかった。それは、rc2自身の`RC.idr`がこの式を見るずっと前、`Lifted`の段階でのことである。`RC.idr`の`normalizeDef (LExtPrim fc lazy p args) = ...`は、`MkLForeign`の扱いをそのまま構造的に写したもので、特定の`p`に対する特別扱いはない。
- **rc2自身のパイプラインにとっての帰結。** `Compiler.RC2.RC2`の`toRCDefs` (`RC2.idr`) は、各`RCDef`を独立に処理する。コンパイル単位のすべての`MkRCForeign`を横断して、Chezの`Structs` refのように名前で引ける表を作るパスは、パイプラインのどこにも存在しない。`getField`/`setField`の実装には、まさにそのようなパスが必要である。

  1. **1回目のパス**で、プログラム全体のすべての`MkRCForeign`を走査し、現れたすべての`CFStruct n flds`を構造体名`n`をキーとする表に集める。
  2. 続く**2回目のパス**で、`getField`/`setField`の呼び出し箇所にある構造体名とフィールド名の文字列リテラルを、その表に対して解決する。

  これは、rc2が現在持っている最適化パスの大半とは形が異なる。それらは`RCDef`を1つずつ独立に変換する。しかし、`Compiler.RC2.InlineCExp`がすでに確立している形とは同じである。`buildEligible lds : SortedMap Name Eligible`が全定義を1回走査して検索表を作り、`applyInlineLifted lds = traverse (inlineDef (buildEligible lds)) lds`が、その表を使ってプログラム全体を再度走査する。構造体フィールドの表も、まったく同じ2段階の形になる。ただし、キーは`Name`ではなく、`CFStruct`に由来する構造体名 (`String`) になる。

## `--dumplifted`による具体例

上流のIdris2には、`--dumplifted <file>`というデバッグ用フラグがある (`idris2-src/src/Idris/CommandLine.idr:140`、`Compiler/Common.idr`経由で配線されている)。これは、上で説明した`LiftedDef`を、どのバックエンドにも渡す前の状態でテキストにダンプする。次のプログラムに、手作業で実行した。

```idris2
module Main
import System.FFI

%foreign "C:make_point,point"
prim__makePoint : Int -> Double -> PrimIO (Struct "point" [("x", Int), ("y", Double)])

%foreign "C:point_free,point"
prim__pointFree : Struct "point" [("x", Int), ("y", Double)] -> PrimIO ()

makePoint : HasIO io => Int -> Double -> io (Struct "point" [("x", Int), ("y", Double)])
makePoint x y = primIO (prim__makePoint x y)

getX : Struct "point" [("x", Int), ("y", Double)] -> Int
getX s = getField s "x"

setY : HasIO io => Struct "point" [("x", Int), ("y", Double)] -> Double -> io ()
setY s v = liftIO (setField s "y" v)
```

実行したコマンドは`idris2 --dumplifted lifted.txt --cg chez -o t T.idr`である。関係する行は次のとおりである。

```
Main.prim__makePoint = Foreign call ["C:make_point,point"]
    [Int, Double, %World] -> IORes struct "point" ("x", Int) ("y", Double)

Main.prim__pointFree = Foreign call ["C:point_free,point"]
    [struct "point" ("x", Int) ("y", Double), %World] -> IORes Unit

Main.getX = [{arg:0}][]:
    %extprim System.FFI.prim__getField("point", ___, ___, !{arg:0}, "x", 0)

Main.{setY:0} = [{arg:2}, {arg:3}][{eta:0}]:
    %extprim System.FFI.prim__setField("point", ___, ___, !{arg:2}, "y", 1, !{arg:3}, !{eta:0})
```

この出力は、上の2つの主張とちょうど一致する。

- 2つの`MkLForeign`のエントリは、`struct "point" ("x", Int) ("y", Double)`という完全な形を持っている。これは`CFStruct`の`Show`の出力であり、フィールド名と型の両方が残っている。
- 2つの`LExtPrim`の呼び出し箇所が持つのは、構造体名とフィールド名の文字列リテラル (`"point"`、`"x"`/`"y"`) だけである。`fs`/`ty`があった場所には、プレースホルダの`___`が2つ入っている。

**ここで見つけた副次的な事実を記録しておく。将来のセッションが導き直さずに済むようにするためである。** 各`LExtPrim`の呼び出しの末尾にある`0`/`1`は、消去されたプレースホルダの1つではない。これは`FieldType`の証明 (`fieldok`) が、単なる整数に潰れたものである。`FieldType n t fs` (`System/FFI.idr:19`) は、Idris2のフロントエンドが「Natに似た型」として認識する形をしている (`TTImp/ProcessData.idr`の`calcNaty`。これは`Core/CompileExpr.idr`の`ConInfo`の`ZERO`/`SUCC`タグで駆動される)。この判定は`Nat`専用の特別扱いではなく、一般的な構造の検査である。コンストラクタが2つあり、一方は引数を持たず、他方の唯一の引数が同じ型コンストラクタに再帰する、という形をしていれば成り立つ。`First : FieldType n t ((n, t) :: ts)` (引数なし) が`ZERO`に、`Later : FieldType n t ts -> FieldType n t (f :: ts)` (再帰する引数が1つ) が`SUCC`に当たる。したがって`FieldType`の証明は、`Nat`のリテラルと同じように、単なる整数に下げられる。具体的には、構造体のフィールドリストの中でのフィールドの0始まりの位置になる。`"x"`は0番目なので`First`で`0`、`"y"`は1番目なので`Later First`で`1`である。

この位置を表す整数に、`getField`/`setField`の実装が頼る必要はない。Chezの`chezExtPrim`も、これを完全に無視している (`GetField`のパターンマッチは、末尾が単なる`_`で終わる)。構造体名とフィールド名の文字列リテラルだけから解決しており、rc2の設計も同じようにすべきである。フィールドの*位置*だけでは、フィールドの*型*は分からない。型は、前述の`CFStruct`の表からしか復元できない。ここに記録したのは、ダンプにあった説明のない`0`/`1`が、恣意的な値ではなく、たどれる説明を持つものだと分かったからである。

## 上流Idris2のissueトラッカーが述べていること

設計に入る前に、`idris-lang/Idris2`のissueから先行事例を探した。すでにこの壁にぶつかった人がいるかもしれないと考えたためである。実際にいた。そのうちの1人は、この文書の「構造体のフィールドの型は`Lifted`にどう現れるか」の節が独自に導いたのと、まったく同じ問題にぶつかり、そこで諦めていた。

- **[#3830](https://github.com/idris-lang/Idris2/issues/3830)** (2026-08-09起票、未解決、コメントなし): 上で再現したのとまったく同じクラッシュの報告である。上流の`samples/ffi/Struct.idr`を`idris2 --cg refc`でコンパイルすると`ERROR: INTERNAL ERROR: Struct access not implemented: var_1`が出る。原因は、この文書がすでに引用している`RefC.idr:763`の`extractValue`の`idris_crash`と同じ箇所だと突き止められている。この欠落は実在し、上流では現在も修正されていないこと、今回の調査で書いた再現コードの書き方に固有の問題ではないことが、これで確認できる。
- **[#2062 "Align FFI with C FFI"](https://github.com/idris-lang/Idris2/issues/2062)** (2021-11-22起票、2022-07-21クローズ、議論は2026-08-31まで続いた): 最も直接に関係する発見である。ユーザーの`xavierzwirtz`は、RefCバックエンドで`getField`をサポートしようと試みた。5か月後に、彼は次のように書いている。
  > The compiler currently computes a `CFType` only for `MkForeign`,
  > the `CFType` does not get attached to the return type of
  > `MkForeign` in a usable fashion. I believe that for
  > `prim__getField` to work `CFType` needs to be attached to the
  > expression so that when compiling an application of
  > `prim__getField` the accessed field's `CFType` can be used to
  > call `packCFType` and pack it for the RefC runtime. Tldr, how do
  > I get `CFType` for an arbitrary expression from within the refc
  > backend?

  (大意: コンパイラが`CFType`を計算するのは`MkForeign`に対してだけで、その`CFType`は、使える形では`MkForeign`の戻り値の型に付かない。`prim__getField`を動かすには、`CFType`を式に付ける必要があると考える。そうすれば、`prim__getField`の適用をコンパイルするときに、アクセスするフィールドの`CFType`を`packCFType`に渡して、RefCランタイム向けにパックできる。要するに、refcバックエンドの中から、任意の式の`CFType`をどうやって得ればよいのか。)

  この問いに答えた人はいなかった。その6か月後に、「どう解決したのか」と直接尋ねられた彼は、こう答えている。**「諦めて先に進んだ。現状のIdrisのメモリモデルは、構造体の値渡しとはあまり相性がよくない」** (原文: "I cut bait and moved on. The memory model of Idris as it stands does not align well with passing by struct.")。これは、実際に試した人による独立した裏付けである。この文書が`Lifted`をたどって見つけた欠落、つまり`CFType`の情報が`LExtPrim`の呼び出し箇所で消えるという事実と、同じものを指している。

  **この文書の計画が、彼の探していたものとどう違うか。** そして、なぜ彼が成功しなかったところで成功できるのか。xavierzwirtzが探していたのは、*任意の式*の`CFType`を復元する方法、つまり完全に一般的な仕組みだった。彼のコメントからは、この文書が提案する、より狭い方法を検討した形跡は読み取れない。その方法では、式から型を復元することはそもそも試みない。呼び出し箇所まで残る構造体名とフィールド名の*文字列リテラル* (上で確認済み) を、すべての`%foreign`シグネチャの`CFStruct`から一度だけ作った表に対して解決する。これは、Chezの`Structs`/`mkStruct`がすでにやっていることである。彼が一般的な問題をゼロから解こうとしていたのに対し、この方法はChezの手法から導き直せる。彼がこの狭い道筋を見つけられなかったのは、実際に必要な問題より難しい問題を解こうとしていたからかもしれない。この可能性には注意を払っておく価値がある。
- **[#1916 "Add support for value structs"](https://github.com/idris-lang/Idris2/issues/1916)** (2021年、#2062に統合してクローズ): *構造体の値渡し*のFFI (Chezの`(& ftype)`と`(* ftype)`の違い) の話である。ポインタ渡しの`getField`/`setField`とは別の、より難しい問題であり、この文書の対象外である。ただし、上の #2062につながった議論である。
- **[#36 "Nested Structs in FFI not read correctly"](https://github.com/idris-lang/Idris2/issues/36)** (2020年、未解決): *Chez固有*のバグである。構造体の値そのものを持つフィールド (`Ptr`ではないもの) が、誤った値で読まれる。`Struct`が、`define-ftype`のフィールドリストの中も含めて、あらゆる場所で暗黙にポインタだと仮定されているためである。メンテナの`edwinb`自身のコメントによれば、この区別をChez Schemeに伝える方法はない。スカラのフィールドだけを扱うrc2の最初の実装では対象外だが、将来ネストした構造体のフィールドをサポートするなら、先行する実際のバグとして知っておく価値がある。またrc2は、このバグを自然に回避できる可能性がある。ChezのようにSchemeの`ftype`を出力するのではなく、実際のCの`typedef struct`を出力するので、C自体にはこのポインタか値かの曖昧さがない。
- **[#3809 "FFI improvements (explicit Ptr) and additions (Union type and nested data fields)"](https://github.com/idris-lang/Idris2/issues/3809)** (2026-07-08起票、未解決、コメントはまだない): 最近の、より野心的な提案である。ポインタの`Struct`に明示的な`Ptr`を付けること、ネストしたフィールドへのアクセスパス、ポインタでない構造体のフィールド、`union`のサポートが含まれる。ChezバックエンドのPRが添付されているという話もある。この文書の対象 (基本的なスカラのフィールドの`getField`/`setField`) をはるかに超えるが、上流の`System.FFI`モジュールが向かうかもしれない方向として知っておく価値がある。

## 設計: 専用の`RStructGet`/`RStructSet`ノードを`Emit.idr`で解決する

**Phase 1で解決済みである。** ノードは`StructField` (`RCExp.idr`) を持つ。これには、`%foreign`シグネチャから得た構造体のフィールドリスト、フィールドの名前と`CFType`、そのフィールドがリストに含まれることの、消去される`Elem`の証明が入る。`toRCDefs`が、すべての`%foreign`定義から表 (`StructTable`) を作る。`normalize`が、各`getField`/`setField`をこの表に対して解決し、未知の構造体やフィールドをそこで報告する。`Emit.idr`は、表を引かずにノードを出力する。以降のこの節の残りは当初の設計であり、そこでは名前が`Emit.idr`まで文字列のままだった。

以前の設計案では、`getField`/`setField`を`Emit.idr`まで素の`RExtPrim`の呼び出しとして残し、そこでだけ特別扱いする形だった。以下で述べる所有権の欠落を見つけたあとで、現在の方針に決めた。`prim__getField`/`prim__setField`を、早い段階で2つの新しい専用の`RCExp`ノードに変換する (`Compiler.RC2.RC`の`normalize`、Phase 1)。そして、それらのノードを`Emit.idr`で構造体フィールドの表に対して解決する。出力の時点で`RExtPrim`の汎用的な`args : List RCLocal`の形をパターンマッチする方法は採らない。構造体名とフィールド名は、新しいノードの上でも素の`String`のままである。プログラム全体の表に対する解決は、以前の案と同じ場所 (`Emit.idr`の`generateCSourceFile`) で行う。変わるのは、それらを表まで運ぶノードだけである。

### `RExtPrim`を直接下げず、専用ノードにする理由

次の2つの事実がある。どちらも、コンストラクタの形だけから想定したものではない。構造体を使うプログラムを実際にrc2でコンパイルし、`RCExp`のダンプと`RC.idr`のソースの両方を読んで確認した。

1. `getField`/`setField`の呼び出し箇所にある構造体名とフィールド名の引数は、`RCExp`の中で`RCConst (Str ...)`になっている。実行時の検索の背後に隠れてはおらず、コンパイル時に直接パターンマッチできる。回復のために追加の仕組みは要らない (以前の案から変わらず、今も成り立つ)。
2. **`RExtPrim`は、実は、オペランドを消費するほかのすべてのノードと同じ所有権の扱いを受けていない。** `RAppName`/`RUnderApp`/`RApp`/`RCon`/`ROp`の`annotate` (Phase 2、`RC.idr`) のケースは、どれも同じ`wrapDups fc (splitBorrows natives owned args) (...)`というパターンを通る。`splitBorrows`は`args`を現在の`owned`の集合と突き合わせて走査する。まだ生きているオペランドは`dup`の対象として残し (`wrapDups`)、最後の使用になるオペランドは所有権をそのまま移す。ところが、`RExtPrim`の`annotate`のケース (`annotate natives owned (RExtPrim fc lazy p args) = pure $ RExtPrim fc lazy p args`、`RC.idr:504`) は、単なる素通しである。`splitBorrows`も`wrapDups`も使わず、`owned`を参照すらしない。

   これを、上の実例をrc2自身でコンパイルして (`--directive dumprcexpr`、`idris2-rc2 --cg rc2`)、`annotate`が実際に何を決めたかを読んで確認した。

   ```
   def Main.getX  (fun args=["v0:Boxed"] ret=Boxed)
     extprim System.FFI.prim__getField [#"point", [__], [__], v0, #"x", #0]
   ```

   `getX`の本体のどこにも、`v0`を包む`RDrop`/`RDup`はない。`v0`は、何の包みもなく`extprim`の呼び出しに届く。構造体のポインタが1回だけ使われる場合は、これがたまたま*正しい*。唯一の使用なので、所有権ごとそのまま渡すのが正しいためである。しかし、同じ構造体のポインタを同じ関数内で2つの`getField`が読む場合、`RExtPrim`の`annotate`のケースが正しい答えを出し続ける保証はない。`owned`が一度も参照されないため、2回目の呼び出しは、すでに消費済みの参照を受け取ることになる。この文書が、一般にこれを直す必要があるわけではない。現在の`RExtPrim`の利用者 (`prim__newIORef`、配列のプリミティブなど) は、実際にはどれも末尾位置か単一使用の位置にしか現れないためである。それでも、`RExtPrim`の既存の所有権の扱いは、複数回使われうる新しい構造体アクセサが、そのまま引き継いでよいものではない。

専用のノードにすれば、この問題は避けられる。ただし、*どこまで*の所有権の仕組みがそのノードに必要かを突き止めるのに、1回ではなく3回の試行がかかった。それぞれ、設計の最中に受けた直接のフィードバックで修正された。将来のセッションが同じ誤った道筋を歩き直さずに済むよう、ここに記録する。

**試行1 (誤り): `ROp`の`postDrop`/`splitBorrows`/`wrapDups`のパターンをそのまま再利用する。** `structVar`を、`ROp`自身のオペランドと同じように、消費されるオペランドとして扱う案である。これは却下した。`getField`/`setField`は、素のCのポインタの参照外しや代入 (`s->x`、`s->y = v`) に下げられる。ポインタを通した読み書きは、ポインタ自身の参照カウントには一切触れない。したがって、以前の`RExtPrim`ベースの設計の`postDrop`がやっていたように、「引数を消費する」ものとしてモデル化する*関数呼び出し*が、もう残っていない。

**試行2 (これも誤り): 両方のオペランドから、所有権の仕組みをすべて取り除く。** どちらのノードにも`postDrop`フィールドを持たせない案である。`structVar`/`value`は決して消費されないので、追跡するものがない、という推論に基づく。これは*半分は*正しい (下の「実際に成り立つこと」を参照)。しかし、実際にあるケースを見落としている。`RStructGet`/`RStructSet`を通してしか読まれず、その後は二度と使われない変数 (例: `f s = getField s "x"`で、`s`はその後使われない) は、*最終的には*dropが必要で、さもなければリークする。この試行が拠り所にした「束縛されたスコープが、通常の`dropDeadLet`の仕組みでdropしてくれる」という推論は、実際には成り立たない。`dropDeadLet`/`dropUnusedOwnedVars` (`RC.idr`、`branchBody`) は、`freeLocalsR`がその変数をそのあとの本体で*まだ*使われているものとして報告するかどうかを調べて、dropするかを決める。`RStructGet`が`structVar`を自身の自由ローカルの1つとして正しく報告すると (生存を追跡するにはそうしなければならない)、この検査は`getField`の呼び出し箇所で`s`を「まだ使われている」と判断する。その結果、そこでもdropされない。呼び出し箇所も外側のスコープもdropしないので、`s`はリークする。まさにこの再現コードに対して、`annotateDef`/`branchBody`/`dropUnusedOwnedVars`を手でたどって確認した。

**実際に成り立つことと、そこから決まる設計。** `structVar`/`value`は、決して*複製*されない。ポインタを1回使うだけでも100回使うだけでも、コピーするC上の理由はなく、すでにBoxedなオペランドのフィールドを読み直す理由もない。この点で、試行2の中心的な洞察は生き残る。ただし、現在の使用がそのオペランドの最後の使用であるときには、ほかのBoxedのローカルと同じように*drop* が必要である。これは、狭くはあるが、本物の3つ目の形である。「まだ生きていれば常にdupし、使用後は常にdropする」という`ROp`の形でも、「dupもdropもしない」という試行2の形でもない。

```idris2
||| [v] if this use is v's own last use in the enclosing scope (v is
||| still in `owned` -- nothing upstream has already claimed or
||| dropped it) and it isn't Native; [] otherwise (still alive
||| afterward -- borrowed, no dup needed either way, since reading
||| through a pointer never requires a copy -- or a Native local,
||| which is never Boxed-refcounted in the first place). Never dup's,
||| unlike splitBorrows: an operand that's still alive afterward needs
||| no action here at all.
dropIfLastUse : SortedSet RCLocal -> Owned -> RCLocal -> List RCLocal
dropIfLastUse natives owned v =
    if contains v owned && not (contains v natives) then [v] else []
```

### 新しいノード

```idris2
||| A read of one field out of a C struct pointer -- pure, and never
||| duplicates structVar (a C pointer dereference, not a call that
||| consumes anything -- see "Why a dedicated node" above). structVar
||| still needs dropping if this is its own last use, though --
||| postDrop captures that (0 or 1 elements, computed by
||| Compiler.RC2.RC's annotate via dropIfLastUse, mirroring ROp's own
||| field but never triggering a dup the way ROp's can).
||| structName/fieldName stay plain strings -- resolved against a
||| whole-program struct-field table built once in Emit.idr's own
||| generateCSourceFile (see "Part B/C/D" below), the same way
||| RPrimVal's own dyngen/orStagen resolve a literal's concrete C
||| rendering late, rather than being pre-resolved to a CFType here.
RStructGet : FC -> (structVar : RCLocal) -> (structName : String) ->
             (fieldName : String) -> (postDrop : List RCLocal) -> RCExp

||| A write of one field into a C struct pointer, evaluating to Unit.
||| Same reasoning as RStructGet for both structVar and value -- either
||| may end up in postDrop (0, 1, or 2 elements) if this use is its
||| own last one; neither is ever duplicated.
RStructSet : FC -> (structVar : RCLocal) -> (structName : String) ->
             (fieldName : String) -> (value : RCLocal) ->
             (postDrop : List RCLocal) -> RCExp
```

どちらのノードも、`ROp`の`postDrop`フィールドは持つが、`splitBorrows`/`wrapDups`によるdupの挿入という半分は持たない。これは`ROp`の形でも単純な`RV`の形でもない、本物の混合形である。`ROp`の`postDrop`の扱いをすでに知っている箇所には、構造的な前例が近くにあり、新しいパターンを作らずに写せる。該当するのは、`RCExp.idr`の`freeLocalsR`/`countUsesR`/`usedConstructorsR`、`Compiler.RC2.Reuse`、`Compiler.RC2.Sink`の`consumedOperands`、`Compiler.RC2.Loop`の`stripOwnership`である。この文書では、それらの箇所がそれぞれ必要とする変更を、まだ列挙しようとはしていない。それは設計ではなく、実装作業である。

### Phase 1 (`normalize`): `LExtPrim`/`RExtPrim`を新しいノードに変換する

`Compiler.RC2.RC`の`normalize`で、汎用の`LExtPrim fc lazy p args => bindMany env args (\locs => pure $ RExtPrim fc lazy p locs)` (`RC.idr:163-164`) の前に、新しいケースを追加する。このケースは、`p`の名前を`prim__getField`/`prim__setField`に限って照合する。`args`の形は、すでに確認してある (上の「`--dumplifted`による具体例」を参照)。

- 構造体名とフィールド名の`String`は、`RCConst (Str ...)`の位置から直接取り出す。
- 構造体ポインタと値の`RCLocal`は、そのまま残す。
- 消去された`fs`/`ty`のプレースホルダは捨てる。
- `FieldType`の位置を表す整数も捨てる。この文書のほかの箇所で確認したとおり、フィールド名の文字列と重複しており、どの実装も頼るべきものではない。

`RStructGet`/`RStructSet`は、これらから直接作る。ここでは`postDrop`を空にしておく。`ROp`のPhase 1の形でも、常に`postDrop = []`で構築し、埋める作業をPhase 2に任せている (`RCExp.idr`の`ROp`コンストラクタのドキュメントコメントを参照)。

### Phase 2 (`annotate`): 所有権

```idris2
annotate natives owned (RStructGet fc structVar sn fn _) =
    pure $ RStructGet fc structVar sn fn (dropIfLastUse natives owned structVar)
annotate natives owned (RStructSet fc structVar sn fn value _) =
    pure $ RStructSet fc structVar sn fn value
             (dropIfLastUse natives owned structVar ++ dropIfLastUse natives owned value)
```

`dropIfLastUse`は、「専用ノードにする理由」の節に示した定義である。どちらのケースも`splitBorrows`/`wrapDups`を呼ばない。ポインタを通して読むことも、すでにBoxedなオペランドのフィールドを読み直すことも、コピーを必要としないので、dupは一切挿入されない。一方で、*今回の*使用がそのオペランドの最後の使用かどうかを判断するために、どちらのケースも`owned`を参照する。これは、試行2が省いたせいで誤った、まさにその検査である。こうして、「専用ノードにする理由」で`RExtPrim`の扱いに見つけた欠落は埋まる。ただしその方法は、試行1のように`ROp`のパターンをそのまま再利用することでも、試行2のように所有権の追跡を全面的にやめることでもない。新しいパターン (`dropIfLastUse`) を用いる。

### Part A: ポインタ渡しの構造体FFIそのものに新しいロジックは要らない。`CFStruct`は`CFPtr`の既存の処理をそのまま使える

2つを並べて比べて確認した。`cTypeOfCFType CFPtr = "void *"`と`cTypeOfCFType (CFStruct x ys) = "void *"`は、すでに一致している (`Emit.idr:2241`/`2247`)。この設計では、構造体は常にポインタを介してアクセスされる。これは、上で確認した「すべての構造体名は`%foreign`のシグネチャに現れなければならない」という取り決めと合致し、Chez自身の前提とも合致する (この前提が成り立たないときに何が壊れるかは、「上流Idris2のissueトラッカーが述べていること」の #36を参照)。そのため、実際に壊れている次の2つのケースは、

```idris2
extractValue _ (CFStruct x xs) varName = idris_crash "..." -- Emit.idr:2295
packCFType (CFStruct x xs)     varName = "makeStruct(" ++ varName ++ ")" -- Emit.idr:2319, undefined function
```

`CFPtr`の、すでに動いている行をそのまま写せば直せる。

```idris2
extractValue _ (CFStruct x xs) varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
packCFType (CFStruct x xs)     varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
```

これだけで、構造体のポインタを引数に取る、または返す`%foreign`関数 (上の例の`prim__makePoint`/`prim__pointFree`) が直る。`getField`/`setField`とは無関係である。すでに検証済みのコード経路を再利用するだけで、新しいロジックではないので、リスクも低い。

### Part B: 収集フェーズ

`generateCSourceFile`の冒頭、`traverse_ (uncurry createCFunctions) defs`が走る前に、すべての`(Name, RCDef)`の組を走査して`MkRCForeign ccs fargs ret`を探す。その`fargs`/`ret`の`CFType`には、Chezの`mkStruct` (`Compiler/Scheme/Chez.idr`、前述) と同じ方法で再帰する。`CFIORes`/`CFFun`を通り抜けて、その中に入れ子になっているかもしれない`CFStruct n flds`を探す。見つかったすべての`(n, flds)`を、新しい`Ref StructDefs (SortedMap String (List (String, CFType)))`に集める。この`Ref`は、`generateCSourceFile`がすでに用意している`ConstDef`/`OutfileText`などのrefと並べて登録する。これは、Chezの`Structs`/`mkStruct`を構造としてそのまま移植したものである。再帰の形も、「最初に見た構造体名を採用し、再出力しない」という重複除去も同じになる。違いは、`List String`の`Ref`を持ち回る代わりに`SortedMap`を作る点と、出力すべきSchemeのコードがない点である。

### Part C: Cの構造体定義の出力

`header` (`Emit.idr`) で、`StructDefs`の表のエントリごとに`typedef struct { ... } name;`を1つ出力する。`header`は、`generateCSourceFile`の`traverse_`の直後に呼ばれるので、`createCFunctions`の間に行うフィールドの型の解決は、出力の順序に左右されない。各フィールドの`CFType`は、既存の`cTypeOfCFType`で変換する。型からCの型への新しいロジックは要らない。`%foreign`の引数と戻り値の型のために、すでにあるものであり、構造体のフィールドも同じ種類の型だからである。

### Part D: `emitRC`での`RStructGet`/`RStructSet`の下げ

`emitRC` (`Emit.idr:1882`) に、既存の`RExtPrim`のケースと並べてケースを追加する。Phase 1が`prim__getField`/`prim__setField`を変換すれば、これらは`RExtPrim`のケースにはまったく届かなくなる。そのため、既存の`RExtPrim`のケースにあるホワイトリストと汎用の呼び出しのロジックには、手を加えなくてよい。

```idris2
emitRC (RStructGet fc structVar sn fn postDrop) _ = do
    fields <- getStructFields sn   -- looks up the Ref from Part B
    let Just ty = lookup fn fields | Nothing => throw (InternalError ...)
    ptr <- rcVarToC structVar      -- reuses extractValue CFPtr's rendering (Part A)
    removeVars $ map varName postDrop   -- drops structVar iff this was its last use
    pure $ packCFType ty ("((\{sn}*)\{ptr})->\{fn}")
emitRC (RStructSet fc structVar sn fn value postDrop) _ = do
    fields <- getStructFields sn
    let Just ty = lookup fn fields | Nothing => throw (InternalError ...)
    ptr <- rcVarToC structVar       -- neither is ever duplicated to get here --
    valC <- rcVarToC value          -- extractValue ty, since value's own Rep matches ty
    removeVars $ map varName postDrop   -- drops whichever of structVar/value (0, 1,
                                         -- or both) this was the last use of
    pure $ "(((\{sn}*)\{ptr})->\{fn} = \{extractValue ty valC}, (IDRIS2RC2_Value*)NULL)"
```

これは最終的な構文ではなくスケッチである。`getStructFields`は、「Part Bが値を入れる`Ref`の`StructDefs`を引く」ことを指す。`Ref`の具体的な配線、エラー処理、Cの文と式のどちらの位置に出すかの扱いは、周囲の`emitRC`のケースがすでに使っている慣例に従う。それ以上の設計は、ここでは行わない。`packCFType`/`extractValue`は、Part Aが`CFStruct`について直したのと同じ既存の関数である。ここでは、構造体のポインタ自体ではなく、*フィールド*の`CFType`に対して再利用する。Phase 2で`dropIfLastUse`が計算した`postDrop`は、`structVar`/`value`のどちらを (あるいは両方を) dropすべきかを、このコードに正確に伝える。`postDrop`を持つほかのすべてのノードと同じ取り決めであり、`Emit.idr`がここで所有権を導き直すことはない。

**ネイティブなフィールドは、値をネイティブのまま読む** (2026-09-29)。`value`をBoxedのまま出力して取り出す方法は、定数をリークさせていた。setterを唯一の呼び出し元にインライン展開すると (`inlining.md`、基準B)、`9.0`そのものが渡される。これを`rcVarToBoxedC`がボックス化するが、誰も解放しない (Test24とTest120で、valgrind下で16バイト)。`cfTypeNative`が写す型のフィールドは、現在は`rcVarToNativeC`を通すので、定数はリテラルとして書き出される。

### 上流から具体的に移植できるもの

rc2は完全に独立したパッケージであり、`idris2-src`を編集することは決してない (`README.md`の「What's here」)。また、そこからコードを`import`することもできない。そのため、ここでいう「移植」は、ファイルのコピーではなく、同じロジックをrc2自身の流儀で導き直すことを意味する。具体的には次のとおりである。

- **直接アルゴリズムを移植するもの** (形は同じで、rc2の流儀で書き直す): 構造体名ごとに1度だけ集める`Structs`のrefと`mkStruct`のパターン (上のPart B)。これは、「同じ考え方を別の言語で書く」ことそのものであり、`%foreign`定義の戻り値型と引数型の中の`CFIORes`/`CFFun`への再帰も含む。
- **既存のrc2のコードがすでにカバーしており、まったく不要なもの**: Chezの`cftySpec` (`CFType`ごとのSchemeの型文字列の生成) に対応するものを、rc2で新しく書く必要はない。ほかのすべての`CFType`について、`cTypeOfCFType`/`extractValue`/`packCFType`が同じ役割をすでに果たしている。`CFStruct`は、Part A/Cで行うとおり、既存のケースごとの関数に追加するだけでよく、ゼロから再実装するものではない。
- **移植できず、新規に書く必要があるもの**: `chezExtPrim`の`GetField`/`SetField`のケースは、Scheme (`ftype-ref`/`ftype-set!`) を出力し、Chez Scheme自身のマクロ展開時の型解決に頼っている。rc2はCを直接出力し、Part Bで作る`StructDefs`の表に対して自前で解決する。問題は同じだが、解決方法は構造的に無関係である。Part D (および上の`RStructGet`/`RStructSet`のノードとPhase 1/Phase 2の仕組み) は、移植ではなく独自の設計である。この設計にある専用ノードという段階に相当するものは、Chezにはまったくない。Schemeは動的型付けなので、`chezExtPrim`は`ExtPrim`から`GetField`/`SetField`を直接下げることができ、rc2の`RExtPrim`にあるような所有権追跡の欠落を回避する必要もない (上の「専用ノードにする理由」を参照)。したがって、設計のこの部分には、移植元になる上流の対応物がそもそもない。

## rc2自身の設計に関する未解決の問い

- ~~未確認: `getField`/`setField`を、どの`%foreign`シグネチャにも現れない構造体名に使うプログラムは、Chezを含むどのバックエンドでどうなるか~~ **確認済み: Chezでも、コンパイル時に失敗する。** 今回の調査の再現コードを`idris2 --cg chez`で直接実行したところ、`Exception: unrecognized ftype name my_struct ... / Error: INTERNAL ERROR: Chez exited with return code 255`となった。その名前に対する`(define-ftype my_struct ...)`が一度も出力されていない (つまり、`Struct "my_struct" ...`に言及する`%foreign`シグネチャが1つもない) と、Chez Scheme自身の`ftype-ref`のマクロ展開が失敗する。したがって、`getField`/`setField`で使うすべての構造体名が、プログラム中のどこかの`%foreign`シグネチャに最低1回は現れていなければならないという条件は、rc2が新しく課す制限ではない。上流の既存の取り決めであり、リファレンスバックエンドがすでに強制している。強制するタイミングが理想より遅く、Idris2のコンパイル時ではなくSchemeのマクロ展開時になっているだけである。rc2はこれに頼ってよく、「構造体名が宣言されていない」場合を、rc2自身のコンパイルエラー以外の何かとして扱う必要はない。
- ~~未整理: フィールドの値が、rc2のBoxed/Nativeの`Rep`の区別とどう相互作用するか~~ **解決済み: 構造体のフィールドは、それ自体がBoxed (`IDRIS2RC2_Value*`) の値になることはない。したがって、`ConAltNative`のような別名参照やdupの問題を考える必要はまったくない。** `CFStruct`のフィールドリストは`List (String, CFType)`であり (`Core/CompileExpr.idr:199`)、`CFUser`以外のすべての`CFType`は、それぞれ固有の記憶域を持つ本物のCの型を表す。`CFInt`/`CFDouble`/`CFPtr`/ネストした`CFStruct`などがそうであり、`cTypeOfCFType`が各ケースについてすでに出力しているものである。

  `CFUser : Name -> List CFType -> CFType`は、任意のIdris2の型を表す (`extractValue`の`(CFUser x xs) varName = "(IDRIS2RC2_Value*)" ++ varName`のケースにより、Boxedとして出力される)。型の*文法*には存在するが、参照カウントされる本物のBoxedなIdris2の値には、Cの構造体メンバとしての意味のある記憶域がない。`int`/`double`/素のポインタのフィールドと違って、「このGC自身の生存期間に結び付いたポインタを保持するスロット」には、実際のCのレイアウトがないためである。

  そのため、`RStructGet`/`RStructSet`のフィールドの型の検索では、`CFUser`型のフィールドを対象外として扱ってよい。本物の所有権の設計が必要なケースとしてではなく、構造体の収集時 (Part B) のエラーとして扱う。`getField`/`setField`の読み書きは、常に本物のCの型の領域に対する`packCFType`/`extractValue`の変換であり、すでにBoxedな値を別名で読むことはない。したがって、読み出し側に`dup`は一切不要である。コンストラクタを分解したフィールドは、Boxedの記憶域への直接の別名なので事情が違うが、それは`Compiler.RC2.ConAltNative`の問題であり、ここの問題ではない。

  スカラのフィールドをネイティブ (アンボックス) のまま読み書きして、すぐにネイティブの文脈で使う値について`packCFType`/`extractValue`の往復を省くことは、将来の作業として引き続き妥当である。通常のコンストラクタから分解したフィールドに対して、`Compiler.RC2.ConAltNative`がすでに行っているのと同じ形である (`rc2/doc/con-alt-native.md`)。ただし、これは、動作する常にBoxedな版の上に載せる性能最適化であり、その版を作るための前提条件ではない。
- ~~未列挙: `RStructGet`/`RStructSet`のケースを追加する必要があるすべての箇所~~ **完了。下の「実装状況」を参照。** `RCExp`に触れるすべてのパスを監査した。実際の欠落が2件見つかって修正した (`Loop.idr`の`stripOwnership`、`Sink.idr`の`genuinelyUsedR`)。残りは、それぞれのワイルドカードのフォールスルーで、すでに正しいことを確認した。

## 実装状況

実装は`c-struct-support`ブランチで行った (`RCExp.idr`、`RC.idr`、`Loop.idr`、`Pretty.idr`、`Emit.idr`、`Sink.idr`。コメントのみの更新が`DualABI.idr`/`ConAltNative.idr`/`Reuse.idr`)。上の設計から大きく変えた点はない。実装の途中で行った改良が1つだけあり、設計では予期していなかった。それが`dropIfLastUse`自体である。`RStructGet`/`RStructSet`は`splitBorrows`/`wrapDups`を決して呼ばない (どのオペランドも複製されない)。しかし、設計を「何もdropしない」と素朴に読むと、ちょうど1回だけ使われてそれきりの構造体ポインタ (`f s = getField s "x"`) がリークした。まさにその再現コードに対して、`annotateDef`/`branchBody`/`dropUnusedOwnedVars`を手でたどった。そのうえで、上で説明した、`owned`を参照するがdupは決して挿入しない形に落ち着いた。

**手で検証した。** 当時は、`verify.sh`に統合された専用の回帰テストがまだなかった (下を参照)。検証に使ったのは、`%foreign`シグネチャで構造体を宣言し、いくつかのフィールドを読み書きするプログラムである。フィールドを2回続けて読み直すこと、`setField`の値オペランドを、その後さらに3回再利用することも含めた。この2つで、`RStructGet`と`RStructSet`の両方について、`dropIfLastUse`の出現順の扱いを検査した。結果は次のとおりである。

- 問題なくコンパイルでき、期待どおりの出力が得られる。
- 次のCが生成される。
  ```c
  typedef struct { int64_t x; double y; } point;
  /* ... */
  IDRIS2RC2_Value *primVar_9 = idris2rc2_mkInt64(((point*)((IDRIS2RC2_Pointer*)var_0)->p)->x);
  idris2rc2_drop(var_0);
  return primVar_9;
  ```
  これは`RStructGet`で、直接のポインタ参照外しになっている。`postDrop`は素の`idris2rc2_drop`として実現され、分岐もdupもどこにもない。そして次のCも生成される。
  ```c
  ((point*)((IDRIS2RC2_Pointer*)var_0)->p)->y = (idris2rc2_to_double(var_1));
  idris2rc2_drop(var_0);
  idris2rc2_drop(var_1);
  ```
  これは`RStructSet`で、形は同じである。両方のオペランドがdropされているのは、その呼び出し箇所がそれぞれのオペランドの最後の使用にたまたま当たっていたためである。
- 試したどの変種でも`valgrind --leak-check=full`がクリーンだった (`definitely lost: 0 bytes`、`0 errors`)。

**追加の監査。** 上のフィールド再利用のケースは、レビューの指摘ですでに見つけて修正してあった。その後、直接のレビューを受けて、`RCExp`に触れるほかのすべてのパスについて、そのワイルドカードのフォールスルーが2つの新しいノードを正しく扱えているかを調べた。実際の欠落が2件見つかって、修正した。

- `Loop.idr`の`stripOwnership`は、`ids`を`ROp`/`RCmpCase`/`RLoopContinue`/`RLoop`の`postDrop`/`prologueDrop`フィールドから取り除く。これは、ローカルをネイティブのシャドウに昇格させるときに、`Compiler.RC2.ConAltNative`/`Compiler.RC2.DualABI`が使う関数である。ところが`RStructGet`/`RStructSet`も、同じ種類の`postDrop`フィールドを持つのに、ワイルドカードを素通りしていた。ここでネイティブに昇格したローカルが残ると、一度もボックス化されていない値に対するdropが出力されてしまう。
- `Sink.idr`の`genuinelyUsedR`は、`RCExp.idr`の`freeLocalsR`とほぼ同じ自由変数解析だが、`structVar`/`value`を本物の使用として数えていなかった。これは、分岐のsinkingで、すでに見つかって修正された実際のミスコンパイルと同じ種類のバグである (`TestBuffer.idr`、`rc2/doc/branch-sinking.md`の「Not peeling through var's own death」を参照)。見逃していれば、`trySinkInto`の`RLet`のケースが、`getField`/`setField`の呼び出しが実際に読んでいる束縛を、その呼び出しの先へsinkしてしまうところだった。その場合、生成されるCに、定義より前の使用が現れる。

監査したそのほかの箇所では、いずれもワイルドカードのフォールスルーが、2つの新しいノードにすでに正しいことを確認した。対象は次のとおりである。

- `Reuse.idr`の`tryClaim`/`tryConsume`/`resolveReuse`
- `ConAltNative.idr`の`peelWrappers`/`applyConAltNativeExp`
- `MutualLoop.idr`の`tailCallTargets`/`buildGroup` (名前の付け替えを、完全に`Loop.idr`の`renameRCExp`に任せている。これは最初の実装と同時にすでに修正済みである)
- `DualABI.idr`の`tailValueReps`/`applyCallSiteRewriteBody`

特定のノードの一覧を挙げていたコメントは、そのことが明示されるよう更新した。振る舞いの変更は不要だった。`refc-suite`の全体 (19/19) とスモークテスト (23/23) の回帰スイートは、途中の変更を通じて通り続けた。新しいノードも、`Emit.idr`の`where`節のリファクタリング (Part Aの`cTypeOfCFType`/`extractValue`/`packCFType`をトップレベルに引き上げたもの) も、何も後退させなかったことが確認できた。

**`rc2/tests/verify.sh`に統合された正式な回帰テストを追加した。** `rc2/tests/Test24CStructSupport.idr`で、補助のCのコンストラクタとデストラクタの組 (`Test24CStructSupport.c`/`.h`) を持つ。このテストは、`RStructGet`/`RStructSet`の`dropIfLastUse`の所有権の扱いを直接検査する。具体的には、フィールドを2回続けて読み直すこと (`structVar`を2回使い、どちらもdupなし) と、`setField`の呼び出しの`value`オペランドを、その後さらに3回再利用することである。

`verify.sh`自体にも、このテストに必要だった一般的な仕組みが加わった。`TestN.idr`と並べて置いた`TestN.c`を一度コンパイルし、`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`経由で自動的にリンクする。ほかの既存のテストには影響せず、将来のスモークテストでも使える。`%foreign`宣言に、rc2/RefCが提供するプリミティブではなく、本物のCの実装が必要なテストである。

このテストは`NO_REFC_DIFF_TESTS`に加わった。本物のRefCには、比較対象になる`getField`/`setField`がないためである。`.expected`は手で検証したものを使う。また`LEAK_SENSITIVE_TESTS`にも加わった。このテストの眼目が、所有権の正しさだからである。`verify.sh`全体の実行結果は、39件が成功、既知の既存の1件 (`Test111Basics/Basics.idr`に記録済みのリーク。無関係) 、失敗0件だった。このテスト自身の`valgrind`の実行も、definitely lostが0バイトである。

補助ファイルを書いているときに、Cレベルのtypedefの衝突が起きた。これについて、記録する価値がある点がある。rc2が生成するCは、`StructDefs`のすべての構造体について、すでに`typedef struct { ... } name;`を出力している (上のPart C)。そのため、補助のヘッダが*同じ*構造体の形をもう一度宣言すると、たとえバイト単位で完全に一致していても、両方が同じ翻訳単位に`#include`された時点でtypedefの重複エラーになる。`Test24CStructSupport.h`は、自身の2つの関数を`test_point*`型ではなく`void*`型で宣言し、本物の`test_point`のtypedefを`.c`ファイルの内部に留めることで、これを避けている。これはrc2のバグではない。この方法で構造体名を確立する補助のCファイルなら、どれでも同じ衝突に遭う。ただし、同様のテストをもう一つ書く前に、知っておく価値がある。

**これには、正式な修正が入った。** `%cg rc2 externStruct=<name>` (`rc2/doc/directives.md`の5節) は、指定した名前の構造体 (複数可) について、`header`が出力する`typedef struct`を抑制する。まさにこのケースのためのものである。システムやライブラリのヘッダがインクルード済みで、すでにその構造体名を`typedef`している場合が該当する。実際の例はlibcurlで、`curl/curl.h`がすでに`curl_version_info_data`をtypedefしている (`idris2-curl`の`doc/version-info-struct.md`)。`StructDefs` (この節のPart B/Cの表) がこの指定で絞り込まれることはなく、Part Cのtypedefの*出力*だけが抑制される。`RStructGet`/`RStructSet` (Part D) は、どちらの場合でもまったく同じようにフィールドを解決する。

`void*`による回避ではなく、「正しい」やり方で一から作った例は`rc2/tests/Test120CStruct/`を参照。補助のヘッダが本物のtypedefを宣言している。`Test24CStructSupport`は、元のまま変更していない。その`void*`による回避は、今でも問題なく動き、間違いでもない。ただ、唯一の選択肢ではなくなっただけである。

## 調査したが見送ったもの: ネイティブ (アンボックス) な`Ptr`/`CFPtr`表現

実装が入った後に、直接の質問を受けて調べた。`getField`の結果も`setField`の`value`オペランドも、`Rep`の`RNative`に昇格されることはない。`Compiler.RC2.Types`の`repOf`が`RNative`を提案するのは`ROp`/`RPrimVal`だけで、`RStructGet`には対応するケースがなく、`Nothing`へ素通りする。さらに、`structVar`自体 (構造体のポインタ。Part A以降は`CFPtr`と同じ形) も、常にBoxedになる。生のポインタを1つ運ぶだけのために、`IDRIS2RC2_Pointer`のヒープ確保が1回必要になる (`packCFType CFPtr = idris2rc2_mkPointer(...)`)。そこで、構造体のポインタに限らず、`Ptr`/`CFPtr`の値一般を、固定幅のスカラと同じようにrc2の既存のネイティブ表現の仕組みに載せられないかを調べた。

**意味の問題に入る前に、構造上の理由で行き詰まる。** `Rep`の`RNative`/`RInlineNative`は`RNative PrimType`という型を持つ。この`PrimType` (`idris2-src/src/Core/TT/Primitive.idr`) は、rc2ではなく上流の型であり、ポインタのケースを一切持たない (`IntType`/.../`DoubleType`/`CharType`/`WorldType`で全部である)。`Compiler.RC2.Types`の`nativeEligible`が受け入れるのも、そのうちの一部だけである。ネイティブのポインタを表現するには、rc2独自の新しい`Rep`のバリアントが必要になる。再利用できる既存の`PrimType`の値がないためである。この変更は、`Rep`をパターンマッチするすべてのモジュール (`RC.idr`、`Types.idr`、`Emit.idr`、`Loop.idr`、`DualABI.idr`) に及ぶ。

これに加えて、次の問題がある。`RCExp`は、これらが走る時点でIdris2の型情報をすでに消去している。そのため、「このBoxedのローカルは実はポインタである」と認識できるのは、`CFType`の情報を直接持っている少数の箇所 (`RStructGet`のフィールドの型、`%foreign`呼び出しの戻り値の型) に限られる。現在の`ROp`/`RPrimVal`駆動のネイティブ昇格のような、一般的なローカルの型推論にはならない。

**それを脇に置いても、意味の面では、スカラほどすっきりとは成り立たない。** ネイティブのポインタは、「値としてコピーされ、参照カウントされない」という意味になる必要がある。素のアドレスなら、これは正しい。しかし、実際に2つの問題がある。

- **`CFGCPtr`は、そのままでは完全に壊れる。** `idris2rc2_mkGCPointer(raw, onCollect)`が`onCollect`を実行するのは、*Boxedのラッパー*が回収されたときである。外部のクリーンアップを起動するために、参照カウントに実際に依存している。ネイティブのポインタをどう設計しても、`CFGCPtr`は明示的に除外して、永久にBoxedのみのままにする必要がある。候補になりうるのは`CFPtr` (回収時のコールバックなし) だけである。
- **`CFPtr`自体も、確保のコストだけでなく、安全網を失う。** 現在の`IDRIS2RC2_Pointer`のラッパーは、生のポインタが指すメモリを保護しない。それはもともと、すべてプログラマの責任である (`Test24CStructSupport.idr`が明示的に`prim__freePoint`を呼んでいることを参照)。それでも、ポインタの各コピーがまだ到達可能かどうかを、IRの中の*何か*が (通常の`dup`/`drop`で) 追跡している。ネイティブのポインタは、追跡なしに自由にコピーされる。rc2が指す先のメモリについてすでに保証していること (何もない) が後退するわけではない。しかし、IR自体の上で見えること、確認できることは、確実に減る。ポインタであるフィールドを持つ構造体 (将来のネストした構造体の機能) では、これがさらに深刻になる。フィールドのポインタの生存期間を、それを所有する構造体の生存期間との関係で推論することは、まさに本物の借用やライフタイムのチェッカが存在する理由であり、rc2にはそれがない。

**結論**: `CFPtr`に限れば、意味としてはありうる。ポインタの値は、スカラと同じように、本当に「コピーであって参照カウントなし」だからである。しかし、見送る。`Rep`を広げるコストが大きく、`CFGCPtr`は永久に除外する必要があり、`IDRIS2RC2_Pointer`が現在提供している弱い到達可能性の追跡すら失う影響は、解決済みではなく、未解決の問題のままである。再検討するのは、プロファイルで`IDRIS2RC2_Pointer`の確保コストが実際に問題になると分かったときに限る。その場合は、`CFGCPtr`の分離と上のライフタイムの問題について、具体的な計画を立てる。現時点で計画はない。

## ファイル

- `rc2/tests/Test24CStructSupport.idr`/`.c`/`.h`/`.expected`: 回帰テスト。`rc2/tests/verify.sh`: このテストに必要だった、補助のCファイルのコンパイルとリンクの仕組み (`if [ -f "$RC2_DIR/tests/$name.c" ]; then ...`)。このテスト用の`NO_REFC_DIFF_TESTS`/`LEAK_SENSITIVE_TESTS`のエントリもある。
- `rc2/src/Compiler/RC2/RCExp.idr`: `Rep`の`RNative`/`RInlineNative PrimType`。「調査したが見送ったもの: ネイティブな`Ptr`/`CFPtr`」の節の出発点である。`rc2/src/Compiler/RC2/Types.idr`: `nativeEligible`/`repOf`。`rc2/src/Compiler/RC2/Emit.idr`: `packCFType`/`extractValue`の`CFPtr`/`CFGCPtr`のケース (`idris2rc2_mkPointer`/`idris2rc2_mkGCPointer`)。
- `idris2-src/src/Core/TT/Primitive.idr`: 上流の`PrimType`。`Rep`の`RNative`が再利用できるポインタのケースを持たないことの根拠である。
- 上流のissue: [#3830](https://github.com/idris-lang/Idris2/issues/3830) (まさにこの`extractValue`のクラッシュ。未解決で、修正されていない)、[#2062](https://github.com/idris-lang/Idris2/issues/2062) (RefCの`getField`サポートの先行する試み。断念された。重要なコメントは、上の「上流Idris2のissueトラッカーが述べていること」を参照)、[#1916](https://github.com/idris-lang/Idris2/issues/1916) (構造体の値渡し。対象外)、[#36](https://github.com/idris-lang/Idris2/issues/36) (Chez固有のネストした構造体のバグ。スカラのフィールドでは対象外)、[#3809](https://github.com/idris-lang/Idris2/issues/3809) (最近の、より広いFFIの提案。最初の実装では対象外)。
- `idris2-src/libs/base/System/FFI.idr`: `Struct`/`FieldType`/`getField`/`setField`/`prim__getField`/`prim__setField`。
- `idris2-src/src/Compiler/Scheme/Chez.idr`: `chezExtPrim`の`GetField`/`SetField`のケース、`mkStruct`、`Structs`、`cftySpec`の`CFStruct`のケース、`schFgnDef` (`%foreign`定義ごとに`mkStruct`を呼ぶ場所)。
- `idris2-src/src/Compiler/RefC/RefC.idr`: `cStatementsFromANF`の`AExtPrim`のディスパッチ (RefCとrc2が共有する`prims`ホワイトリスト)、`cTypeOfCFType`/`extractValue`/`packCFType`の`CFStruct`のケース (rc2が写した欠落と同じもの)。
- `rc2/src/Compiler/RC2/Emit.idr`: `emitRC`の`RExtPrim`のケース (`prims`ホワイトリスト)、`cTypeOfCFType`/`extractValue`/`packCFType`の`CFStruct`のケース (`extractValue`の`idris_crash`、`packCFType`の未定義の`makeStruct`呼び出し)、`generateCSourceFile`/`header` (提案した収集パスの置き場所)、`RStructGet`/`RStructSet`のための新しい`emitRC`のケース (上の「設計」を参照)。
- `rc2/src/Compiler/RC2/RCExp.idr`: `MkRCForeign` (`%foreign`定義の`CFType`のリストが、現在行き着く場所)。`ROp` (その`postDrop`フィールドを`RStructGet`/`RStructSet`が再利用する。ただし`ROp`の`splitBorrows`/`wrapDups`によるdupの挿入という半分は再利用しない)。`freeLocalsR`/`countUsesR`/`usedConstructorsR` (新しいノードにケースを追加する必要がある構造解析の関数)。
- `rc2/src/Compiler/RC2/RC.idr`に関する項目は次のとおり。
  - `normalize`の`LExtPrim`/`MkLForeign`のケース (`RC.idr:163-164`/`244`)。新しい`prim__getField`/`prim__setField`のケースが入る場所であり、この文書の「構造体のフィールドの型は`Lifted`にどう現れるか」の節がたどる`Lifted`から`RCExp`への`MkLForeign`/`MkRCForeign`の直接のコピーでもある。
  - `annotate`の`ROp`/`RExtPrim`のケース (`RC.idr:501-504`)。`RStructGet`/`RStructSet`の`annotate`/`dropIfLastUse`が、このパターンから外れる。`ROp`の`splitBorrows`/`wrapDups`は`dup`を挿入するが、`dropIfLastUse`は決して挿入しない。
  - `branchBody`/`dropUnusedOwnedVars` (`RC.idr:397-409`)。`freeLocalsR`が未使用と報告するものをdropする、最上位の仕組みである。上の試行2が、`structVar`/`value`までこれが面倒を見てくれると誤って想定した。
  - `annotateDef`/`definitionNatives` (`RC.idr:596-613`)。`f s = getField s "x"`の再現コードに対して手でたどり、試行2のバグを見つけた箇所である。
- `idris2-src/src/Compiler/LambdaLift.idr`: `LiftedDef`の`MkLForeign`と`Lifted`の`LExtPrim`。構造体のフィールドの型が、rc2自身の`RC.idr`が消費する`Lifted` IRに、(残る場合も残らない場合も) どう届くかを示す箇所である。
- `rc2/src/Compiler/RC2/InlineCExp.idr`: `buildEligible`/`applyInlineLifted`。構造体フィールドの表が従うことになる、プログラム全体を収集してから走査する形である。
- `idris2-src/src/Idris/CommandLine.idr`、`idris2-src/src/Compiler/Common.idr`: `--dumplifted`。上の例の出力に使ったデバッグ用フラグである。
- `idris2-src/src/TTImp/ProcessData.idr`: `calcNaty`。`FieldType`が引き金になる、一般的な「Natに似た型」の構造検出である (`Nat`専用の特別扱いではない)。`idris2-src/src/Core/CompileExpr.idr`: この検出が割り当てる`ConInfo`の`ZERO`/`SUCC`タグ。
