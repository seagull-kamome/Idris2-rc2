# C構造体FFIのサポート (`System.FFI.Struct`/`getField`/`setField`): 実装済み、回帰テスト付き

(原文: `doc/c-struct-support.md`。内容が乖離した場合は原文を正とする。)

上流のIdris2は、`System.FFI`モジュール (`idris2-src/libs/base/System/FFI.idr`) に`Struct`/`getField`/`setField`を用意している。これらは`prim__getField`/`prim__setField`というExtPrimで実装されており、Cの構造体への直接アクセスを提供する。加えて、`%foreign`の引数と戻り値に構造体を値渡しで使うこともできる (`Core.CompileExpr`の`CFStruct`)。Chezバックエンドは、この2つを完全にサポートしている。RefCはサポートしておらず、RefCのExtPrimのホワイトリストと`extractValue`/`packCFType`をそのまま写したrc2も、同じ欠落を引き継いでいた。

この文書は、次のことを記録する。

- 調査で確認できたこと。
- この欠落について、上流のissueトラッカーがすでに述べていること。
- 設計。下の「設計: 専用の`RStructGet`/`RStructSet`ノードを`normalize`で解決する」の節にある。コードを書く前に、実際の`RCExp`と生成されたCの出力で検証した。
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

## 設計: 専用の`RStructGet`/`RStructSet`ノードを`normalize`で解決する

`getField`/`setField`は、`RExtPrim`の呼び出しのままにはしない。`Compiler.RC2.RC`のPhase 1 (`normalize`。名前付きのcase treeを`RCExp`に下げる段階) が、`prim__getField`/`prim__setField`を2つの専用の`RCExp`ノード`RStructGet`/`RStructSet`に変換する。構造体名とフィールド名も、ここでプログラムの`%foreign`シグネチャから作った表に対して解決する。`Emit`が走る時点では、ノードがすでに構造体のフィールドリストとフィールドの`CFType`を持っており、`Emit`が名前を引くことはない。Cへの下げは、素のポインタの参照外しである。以降は、データの流れに沿って、ノード、それを作って注釈する2つのフェーズ、出力側 (Part A〜D) の順に述べる。

### `RExtPrim`を直接下げず、専用ノードにする理由

次の2つの事実が、決め手になった。

1. `getField`/`setField`の呼び出し箇所にある構造体名とフィールド名の引数は、正規化後のコードでは`RCConst (Str ...)`のローカルになっている (上の「`--dumplifted`による具体例」を参照)。そのためコンパイル時に直接パターンマッチでき、実行時の検索は要らない。
2. 構造体アクセサには、オペランドを消費するほかのノードとは別の所有権の規則が要る。`ROp` (および`RExtPrim`) の`annotate`のケースは、`wrapDups fc (splitBorrows natives owned args) ...`というパターンを通る。まだ生きているオペランドは`dup`され、消費側が自分の参照をあとで`drop`する。ところが`getField`/`setField`は、`((sn*)p)->f`や`((sn*)p)->f = v`に下げられる。ポインタを通した読み書きは、`IDRIS2RC2_Pointer`の箱を消費もコピーもしないので、`dup`は無駄でしかない。この設計を作った当時、`RExtPrim`の`annotate`は`owned`を一度も参照しない素通しだった。その欠落はその後、別に直された (IORefのセルや配列プリミティブの引数がリークしていた。`tests/Test44IORefExtPrimLeak`)。現在の`RExtPrim`は、`ROp`と同じく`splitBorrows`/`wrapDups`/`boxedOperands`を使う。だからといって、`ROp`の形が構造体アクセサに合うようになったわけではない。ノードが独自の規則を持つのはそのためである。

**規則の中身と、却下した2つの設計。** 最初の案は、`ROp`の`splitBorrows`/`wrapDups`のパターンをそのまま再利用するものだった。しかし、オペランドを消費するものとしてモデル化すべき呼び出しが、もう残っていない。2つ目の案は、ポインタの読み出しは何も消費しないという理由で、所有権の扱いをすべて省くものだった。これでは、最後の使用がそのアクセスである変数 (`f s = getField s "x"`) がリークする。ほかのどこもそれをdropしないためである。`branchBody`と`dropDeadLet` (`RC.idr`) は、ローカルをdropするかどうかを、本体の残りにまだ自由変数として現れるかで決める。`RStructGet`は`structVar`を自身の自由ローカルとして正しく報告するので、アクセスそのものが、変数を生かし続ける使用に見えてしまう。したがってアクセサは、その使用がオペランドの最後の使用であるときは自分でdropし、`dup`は決してしなければならない。これが`dropIfLastUse` (`RC.idr`) であり、下の「Phase 2」で述べる。

### 新しいノード

`RCExp.idr`で定義されている。

```idris2
record StructField where
  constructor MkStructField
  structName : String
  fields : List (String, CFType)
  fieldName : String
  fieldType : CFType
  0 isField : Elem (fieldName, fieldType) fields

RStructGet : FC -> (structVar : RCLocal) -> StructField -> (postDrop : List RCLocal) -> RCExp
RStructSet : FC -> (structVar : RCLocal) -> StructField -> (value : RCLocal) -> (postDrop : List RCLocal) -> RCExp
```

`StructField`は、構造体の宣言済みのフィールドリスト、フィールドの名前と`CFType`、そのフィールドがリストに含まれることの、消去される証明である。`RStructSet`はUnitに評価される。`postDrop`は`ROp`の`postDrop`フィールドと同じ役割だが、意味はより狭い。このノードが最後の使用になるオペランド (`structVar`、`RStructSet`では`value`も) を並べたもので、読み書きのあとにdropされる。Phase 1の直後は`[]`である。どちらのノードも、`dup`は一切挿入しない。`RCExp`を走査するすべてのパスに、2つのノードのケースがある (`RCExp.idr`の`freeLocalsR`/`countUsesR`/`mentionedLocalsAcc`、`Loop.idr`の`stripOwnership`、`Sink.idr`の`genuinelyUsedR`、`ConAltNative.idr`、`ConstFold.idr`、`DualABI.idr`、`LateInline.idr`など)。`structVar`と`value`は、常にそれらのローカルの使用として数えられる。`DualABI`は、どちらのノードの結果もネイティブな値としては扱わない (結果は常に、`packCFType`が出力するBoxedな値である)。

### Phase 1 (`normalize`): `prim__getField`/`prim__setField`を新しいノードに変換する

`normalize` (`RC.idr`) は、汎用の`NmExtPrim`のケースの前で、`NmExtPrim`のうち`prim__getField` (名前空間は問わない) で引数が6個の`[sn, _, _, sv, fn, _]`のものを照合する。引数は、構造体名、消去されたフィールドリストと型、構造体のポインタ、フィールド名、`FieldType`の位置である。`prim__setField`は、これに値と消去されたスロットが加わった`[sn, _, _, sv, fn, _, vl, _]`で照合する。引数をローカルに束縛し、`sn`と`fn`が文字列リテラルであることを要求する。`FieldType`の位置は無視する。フィールド名の文字列と重複しているためである。名前は、`structField`で解決する。

- プログラムの構造体の表は`StructTable`のrefであり、`normalizeProgram`の前に`lowerProgram` (`RC2.idr`) が埋める。すべての`MkNmForeign`定義の`CFType`に`collectStructDefs` (Part B) を畳み込んで作る。
- どの`%foreign`シグネチャにも現れない構造体や、その構造体が宣言していないフィールドは、コンパイル時の`GenericMsg`エラーになる ("struct ... is used by getField/setField but appears in no %foreign signature" / "has no field ... in its %foreign declaration")。これはChezバックエンドが強制しているのと同じ取り決めであり、強制するのが早いだけである (下の「rc2自身の設計に関する未解決の問い」を参照)。
- 構造体名やフィールド名がリテラルでない呼び出し (たとえば、まだインライン展開されていないコンストラクタの引数) は、`notInlinedStructFieldMarker`を先頭に付けた`InternalError`を投げる。通常のコンパイルではそのまま報告される。インクリメンタルコンパイル (`--inc rc2`) では、`normalizeProgram`がちょうどその接頭辞だけを捕まえ、その定義とそこからlambda liftされたものを落とす。そのため、その定義が実際に使われる場合に限り、リンク時に失敗する (`doc/incremental-compile.md`)。

### Phase 2 (`annotate`): 所有権

```idris2
annotate natives owned (RStructGet fc structVar sf _) =
    pure $ RStructGet fc structVar sf (dropIfLastUse natives owned [structVar])
annotate natives owned (RStructSet fc structVar sf value _) =
    pure $ RStructSet fc structVar sf value (dropIfLastUse natives owned [structVar, value])
```

`dropIfLastUse natives owned vars`は、`vars`のうち、今回の使用が最後の使用になるものを返す。条件は、まだ`owned`にあり、ネイティブのローカルではなく、不死のオペランド (`RCNull`/`RCConst`/`RCEmptyCon`/`RCConstCon`/`RCConstClosure`) でもないことである。`vars`を左から右へ走査し、見つけるたびに`owned`から取り除く。したがって、1つのノードに同じローカルが2回現れる場合 (たとえば、`structVar`と`value`が同じローカルのとき) は、1回だけdropされる。`dup`は決して挿入しない。まだ生きているオペランドには、何もする必要がないためである。`RForce` (`RC.idr`) も、自身のオペランドに同じ関数を使う。

### Part A: `CFStruct`は`CFPtr`と同じに扱う

構造体は常にポインタを介してアクセスされる。すべての構造体名は、どこかの`%foreign`シグネチャに現れなければならず (Chezも強制している取り決めである。「上流Idris2のissueトラッカーが述べていること」の#36を参照)、`%foreign`関数は構造体へのポインタを受け取るか返す。そのため`Emit/Util.idr`は、`CFStruct`に`CFPtr`とまったく同じ出力を与えている。

```idris2
cTypeOfCFType (CFStruct x ys) = "void *"
extractValue _ (CFStruct x xs) varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
packCFType (CFStruct x xs)     varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
```

これより前は、`extractValue`がクラッシュし、`packCFType`は存在しない`makeStruct`を呼んでいた (どちらもRefCから写したものである)。この変更だけで、構造体のポインタを引数に取る、または返す`%foreign`関数 (上の例の`prim__makePoint`/`prim__pointFree`) が動く。`getField`/`setField`とは無関係である。`cTypeOfCFType`/`extractValue`/`packCFType`は、`emitRC`がフィールドの`CFType`について共用できるように、`Emit/Util.idr`のトップレベルの関数になっている。

### Part B: 構造体の宣言を集める

`collectStructDefs` (`Emit/Util.idr`) は、`CFType`から、そこに現れる構造体の`SortedMap String (List (String, CFType))`を作る。`CFIORes`/`CFFun`を通り抜け、構造体のフィールドの型にも再帰する (フィールドが、ネストした構造体のポインタであることがある)。ある名前の最初の宣言を採用し、あとで同じ名前が現れても同一とみなす。Chezの`mkStruct`/`Structs`と同じ方針である。これを`%foreign`定義に対して2回、利用側ごとに1回ずつ走らせる。

- `lowerProgram` (`RC2.idr`) が、`normalize`が`getField`/`setField`を解決する先の`StructTable`を作る (Phase 1)。
- `generateCSourceFile` (`Emit.idr`) が、どの定義を下げるよりも前に、`MkRCForeign`定義から`StructDefs`のrefを作る。これにより、`header`は定義の順序によらずすべての構造体を見られる。

構造体の型を表に入れる方法は、`%foreign`で宣言することだけである。`%export`のシグネチャ (`RC2.idr`の`exportNfToCFType`) は、フィールドリストが空の`CFStruct sname []`を作る。その境界を越えるのはポインタだけであり、表はそこからは埋められない。

### Part C: Cの構造体定義の出力

`header` (`Emit.idr`) は、`StructDefs`のエントリごとに`typedef struct { <ctype> <field>; ... } name;`を1つ、すべての関数定義より前の「struct definitions」のブロックに出力する。各フィールドのC型は`cTypeOfCFType`で決める (ネストした構造体のフィールドは`void *`になる)。`%cg rc2 externStruct=<name>`で指定された名前 (`doc/directives.md`の5節) は、出力の対象からだけ外す。インクルードされたヘッダがすでに`typedef`しているためである。`StructDefs`自体は絞り込まず、そのような構造体のフィールドアクセスも通常どおり解決される。

### Part D: `emitRC`での`RStructGet`/`RStructSet`の下げ

`emitRC` (`Emit.idr`) には、ノードごとに1つのケースがある。`StructField`がノードの中にあるので、表を引く必要はない。`prim__getField`/`prim__setField`は、もう`RExtPrim`のケースには届かず、そのホワイトリストにも載っていない。

- `RStructGet`: 構造体のポインタをBoxedのローカルから読み (`rcVarToBoxedC`)、`extractValue CLangC CFPtr`で取り出す。式`((sn*)ptr)->field`は、フィールドの型の`cTypeOfCFType`へのキャストを付け、`packCFType`でBoxedにする。キャストするのは、実際の宣言 (`externStruct`の構造体なら、ヘッダのもの) が`const char *`のような修飾を持つことがあるためである。さらに`(IDRIS2RC2_Value*)`へのキャストも付ける。ポインタ系の型のpackerは、より狭いポインタ型を返すためである。例外は`CFInteger`で、`mpz_t`にはキャストの構文がなく、`packCFType CFInteger`は出力引数を期待する。そのため、`idris2rc2_mkIntegerFromMpz`でコピーする。`postDrop`のオペランドは、そのあとでdropされる (`finalizeSinkWithDrop`)。
- `RStructSet`: 文`((sn*)ptr)->field = value;`を出力し、`postDrop`のオペランドをdropして、`(IDRIS2RC2_Value *)NULL`に評価される。`cfTypeNative`が写す型のフィールドでは、`value`をネイティブのまま読む (`rcVarToNativeC`。`CFChar`は`(char)`キャストを付ける)。そのため、定数はリテラルとして書き出される。Boxedのまま出力して取り出すと、定数がリークしていた。setterを唯一の呼び出し元にインライン展開すると (`inlining.md`、基準B)、`9.0`そのものが渡される。これを`rcVarToBoxedC`がボックス化するが、誰も解放しない (Test24とTest120で、valgrind下で16バイト)。それ以外の型のフィールドは、Boxedの`value`から`extractValue`で読む。

`postDrop`はPhase 2が計算するので、`Emit`はそれを実行するだけで、所有権を自分では導かない。

### 上流から具体的に移植できるもの

rc2は完全に独立したパッケージであり、`idris2-src`を編集することは決してない (`README.md`の「What's here」)。また、そこからコードを`import`することもできない。そのため、ここでいう「移植」は、ファイルのコピーではなく、同じロジックをrc2自身の流儀で導き直すことを意味する。具体的には次のとおりである。

- **直接アルゴリズムを移植するもの** (形は同じで、rc2の流儀で書き直す): 構造体名ごとに1度だけ集める`Structs`のrefと`mkStruct`のパターン (上のPart B)。これは、「同じ考え方を別の言語で書く」ことそのものであり、`%foreign`定義の戻り値型と引数型の中の`CFIORes`/`CFFun`への再帰も含む。
- **既存のrc2のコードがすでにカバーしており、まったく不要なもの**: Chezの`cftySpec` (`CFType`ごとのSchemeの型文字列の生成) に対応するものを、rc2で新しく書く必要はない。ほかのすべての`CFType`について、`cTypeOfCFType`/`extractValue`/`packCFType`が同じ役割をすでに果たしている。`CFStruct`は、Part A/Cで行うとおり、既存のケースごとの関数に追加するだけでよく、ゼロから再実装するものではない。
- **移植できず、新規に書く必要があるもの**: `chezExtPrim`の`GetField`/`SetField`のケースは、Scheme (`ftype-ref`/`ftype-set!`) を出力し、Chez Scheme自身のマクロ展開時の型解決に頼っている。rc2はCを直接出力し、名前は`normalize`の中で、Part Bの`StructTable`に対して自前で解決する。問題は同じだが、解決方法は構造的に無関係である。Part D (および上の`RStructGet`/`RStructSet`のノードとPhase 1/Phase 2の仕組み) は、移植ではなく独自の設計である。専用ノードという段階に相当するものは、Chezにはまったくない。Schemeは動的型付けなので、`chezExtPrim`は`ExtPrim`から`GetField`/`SetField`を直接下げることができ、追跡すべき参照カウントもない。したがって、設計のこの部分には、移植元になる上流の対応物がそもそもない。

## rc2自身の設計に関する未解決の問い

- ~~未確認: `getField`/`setField`を、どの`%foreign`シグネチャにも現れない構造体名に使うプログラムは、Chezを含むどのバックエンドでどうなるか~~ **確認済み: Chezでも、コンパイル時に失敗する。** 今回の調査の再現コードを`idris2 --cg chez`で直接実行したところ、`Exception: unrecognized ftype name my_struct ... / Error: INTERNAL ERROR: Chez exited with return code 255`となった。その名前に対する`(define-ftype my_struct ...)`が一度も出力されていない (つまり、`Struct "my_struct" ...`に言及する`%foreign`シグネチャが1つもない) と、Chez Scheme自身の`ftype-ref`のマクロ展開が失敗する。したがって、`getField`/`setField`で使うすべての構造体名が、プログラム中のどこかの`%foreign`シグネチャに最低1回は現れていなければならないという条件は、rc2が新しく課す制限ではない。上流の既存の取り決めであり、リファレンスバックエンドがすでに強制している。強制するタイミングが理想より遅く、Idris2のコンパイル時ではなくSchemeのマクロ展開時になっているだけである。rc2はこれに頼ってよく、「構造体名が宣言されていない」場合を、rc2自身のコンパイルエラー以外の何かとして扱う必要はない。
- ~~未整理: フィールドの値が、rc2のBoxed/Nativeの`Rep`の区別とどう相互作用するか~~ **解決済み: 構造体のフィールドは、それ自体がBoxed (`IDRIS2RC2_Value*`) の値になることはない。したがって、`ConAltNative`のような別名参照やdupの問題を考える必要はまったくない。** `CFStruct`のフィールドリストは`List (String, CFType)`であり (`Core/CompileExpr.idr:199`)、`CFUser`以外のすべての`CFType`は、それぞれ固有の記憶域を持つ本物のCの型を表す。`CFInt`/`CFDouble`/`CFPtr`/ネストした`CFStruct`などがそうであり、`cTypeOfCFType`が各ケースについてすでに出力しているものである。

  `CFUser : Name -> List CFType -> CFType`は、任意のIdris2の型を表す (`extractValue`の`(CFUser x xs) varName = "(IDRIS2RC2_Value*)" ++ varName`のケースにより、Boxedとして出力される)。型の*文法*には存在するが、参照カウントされる本物のBoxedなIdris2の値には、Cの構造体メンバとしての意味のある記憶域がない。`int`/`double`/素のポインタのフィールドと違って、「このGC自身の生存期間に結び付いたポインタを保持するスロット」には、実際のCのレイアウトがないためである。

  そのため、`RStructGet`/`RStructSet`のフィールドの型の検索では、`CFUser`型のフィールドを対象外として扱ってよい。本物の所有権の設計が必要なケースとしてではなく、対象外として扱う。現在これを拒否するものはなく、`collectStructDefs` (Part B) はそのまま保持し、`cTypeOfCFType`は`void *`として出力する。`getField`/`setField`の読み書きは、常に本物のCの型の領域に対する`packCFType`/`extractValue`の変換であり、すでにBoxedな値を別名で読むことはない。したがって、読み出し側に`dup`は一切不要である。コンストラクタを分解したフィールドは、Boxedの記憶域への直接の別名なので事情が違うが、それは`Compiler.RC2.ConAltNative`の問題であり、ここの問題ではない。

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
- `rc2/src/Compiler/RC2/Emit.idr`: `emitRC`の`RExtPrim`のケース (`prims`ホワイトリスト。`prim__getField`/`prim__setField`はもう載っていない)、`RStructGet`/`RStructSet`のケース、`generateCSourceFile`/`header` (`StructDefs`の収集と`typedef struct`の出力。上の「設計」のPart BとC)。
- `rc2/src/Compiler/RC2/Emit/Util.idr`: `cTypeOfCFType`/`extractValue`/`packCFType`の`CFStruct`のケース (Part A。`CFPtr`と同じ出力である。以前は`idris_crash`と、未定義の`makeStruct`の呼び出しだった)、および`collectStructDefs` (Part B)。
- `rc2/src/Compiler/RC2/RCExp.idr`: `StructField`、`RStructGet`/`RStructSet`のノード (その`postDrop`は`ROp`と同じ役割を持つが、`ROp`の`splitBorrows`/`wrapDups`によるdupの挿入という半分は持たない)、`%foreign`定義の`CFType`のリストが行き着く`MkRCForeign`、およびこれらのノードのケースを持つ構造解析の関数 (`freeLocalsR`/`countUsesR`/`mentionedLocalsAcc`)。
- `rc2/src/Compiler/RC2/RC.idr`に関する項目は次のとおり。
  - `normalize`の`prim__getField`/`prim__setField`のケースと`structField` (Phase 1)。
  - `annotate`の`RStructGet`/`RStructSet`のケースと`dropIfLastUse` (Phase 2)。`ROp`の`splitBorrows`/`wrapDups`はdupを挿入するが、`dropIfLastUse`は決して挿入しない。
  - `branchBody`/`dropDeadLet`。使われなくなったものをdropする仕組みであり、上の「設計」が述べるとおり、それだけでは`structVar`/`value`をカバーできない。
  - `normalizeProgram`が行う、インクリメンタルコンパイルでの`notInlinedStructFieldMarker`の捕捉。
- `rc2/src/Compiler/RC2/RC2.idr`: `lowerProgram`。Phase 1の前に、`%foreign`定義から`StructTable`を作る。
- `idris2-src/src/Compiler/LambdaLift.idr`: `LiftedDef`の`MkLForeign`と`Lifted`の`LExtPrim`。構造体のフィールドの型が、rc2自身の`RC.idr`が消費する`Lifted` IRに、(残る場合も残らない場合も) どう届くかを示す箇所である。
- `idris2-src/src/Idris/CommandLine.idr`、`idris2-src/src/Compiler/Common.idr`: `--dumplifted`。上の例の出力に使ったデバッグ用フラグである。
- `idris2-src/src/TTImp/ProcessData.idr`: `calcNaty`。`FieldType`が引き金になる、一般的な「Natに似た型」の構造検出である (`Nat`専用の特別扱いではない)。`idris2-src/src/Core/CompileExpr.idr`: この検出が割り当てる`ConInfo`の`ZERO`/`SUCC`タグ。
