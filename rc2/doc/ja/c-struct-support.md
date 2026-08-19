# C構造体FFIサポート(`System.FFI.Struct`/`getField`/`setField`): 実装済み、回帰テスト付き

(原文: `doc/c-struct-support.md`。内容が乖離した場合は原文を正とする。)

本家Idris2の`System.FFI`モジュール(`idris2-src/libs/base/System/FFI.idr`)
は、`Struct`/`getField`/`setField`(`prim__getField`/`prim__setField`
ExtPrimに支えられている)経由でC構造体への直接アクセスを提供し、
加えて値渡しの構造体の`%foreign`引数/戻り値(`Core.CompileExpr`の
`CFStruct`)も提供する。Chezバックエンドはどちらも完全にサポート
している。RefCはそうではなかった -- そしてrc2は、RefC自身のExtPrim
ホワイトリストと`extractValue`/`packCFType`を無改造でコピーしていた
ため、全く同一の隙間を引き継いでいた。本書は、確認された事実、
本家自身のissueトラッカーがこの隙間について既に述べていること、
設計(下記「設計: 専用の`RStructGet`/`RStructSet`ノード、
`Emit.idr`で解決」-- 1行のコードも書く前に実際の`RCExp`/生成Cの
出力に対して検証済み)、そして実装そのもの(`c-struct-support`
ブランチ上)を記録する -- 実際に何が完成したか、途中で何を見つけて
何を修正したかは下記「実装状況」参照、回帰テストは
`rc2/tests/Test24CStructSupport.idr`参照(`rc2/tests/verify.sh`自体も
テストごとのコンパニオンCファイルをサポートするよう拡張されている。
これは、rc2とChezの両方が要求する形で、本物の`%foreign`シグネチャ
経由で構造体名を確立するために必要だった)。

## 確認された事実

**`getField`/`setField`はクリーンにコンパイルされるが、「理論上」
だけでなく実際にC言語コンパイルの段階で失敗する。** RefCとrc2は
どちらも`prim__getField`/`prim__setField`を「既知の」ExtPrimとして
受け入れ(`RefC.idr`自身の、`cStatementsFromANF`の`AExtPrim`ケースに
ある`prims`ホワイトリスト。`Emit.idr`の`emitRC`の`RExtPrim`ケース
にある同一のホワイトリスト)、それへの呼び出しを無改造で下降させる
(`idris2_prim__getField(...)` / `idris2rc2_prim__getField(...)`)
-- しかし`support/refc/`にも`rc2/support/rc2/`にも、その関数はどこに
も定義されていない。手作業で再現:

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

は`idris2 --cg refc`ではエラーなくコンパイルされるが、生成されたC
はC言語コンパイルの段階で失敗する:

```
build/exec/t.c: In function ‘Main_main’:
build/exec/t.c:310:22: error: implicit declaration of function
  ‘idris2_System_FFI_prim__getField’ [-Wimplicit-function-declaration]
  310 |     Value * var_13 = idris2_System_FFI_prim__getField(var_14, NULL, NULL, var_1, var_15, var_16);
```

rc2自身の`Emit.idr`は、類似の`idris2rc2_System_FFI_prim__getField(...)`
呼び出しを生成するはずで、同様に未定義である。

**値渡しの構造体FFI(`%foreign`の引数/戻り値の型としての`CFStruct`)
は、RefCとrc2の両方で明示的に未実装である。** `Emit.idr`自身の
`extractValue (CFStruct x xs) varName = idris_crash "INTERNAL ERROR:
Struct access not implemented: ..."`(`Emit.idr:2295`)は、本家の
`RefC.idr:763`の同一のクラッシュから無改造でコピーされている。
`packCFType`自身の`CFStruct`ケース(`Emit.idr:2319`)は
`makeStruct(...)`ヘルパーへの呼び出しを発行するが、これも
`rc2/support/rc2/`には存在しない(本家RefC.idr:788を鏡写ししており、
そちらでの状態も同じである)。

**フィールドの型情報は、`getField`/`setField`がANF/RCExpに到達する
時点までに消去されている。** `prim__getField : {s : _} -> forall fs,
ty . Struct s fs -> (n : String) -> FieldType n ty fs -> ty`は、構造体
名`s`とフィールド名`n`に加えて、2つの型レベル引数(フィールド
リスト`fs`、結果型`ty`)を持つ。上記の生成Cの呼び出しでは、この
2つは文字通りの`NULL`として現れている(`idris2_..._prim__getField(var_14,
NULL, NULL, var_1, var_15, var_16)`) -- これは実際の生成コードを
読んで確認済みであり、推測ではない。生き残るのは構造体名と
フィールド名だけであり、文字列リテラルとして残る(この例では
`var_15`/`var_16`、実際の`Str`定数)。**あらゆる実装は、あるフィールド
のC型を、コンパイル時に、まさにこの2つの文字列だけから解決しなけ
ればならない** -- ランタイムの呼び出しそのものには使える情報が何も
無い。

**Chezもこの解決問題を呼び出しサイトでは解いていない -- Chez
Scheme自身のFFI型システムへ委ねている。**
`Compiler/Scheme/Chez.idr`の`mkStruct`は、全ての`%foreign`シグネ
チャの引数/戻り値の`CFType`群を歩く。ある構造体名(`CFStruct n
flds`)が初めて見つかった時点で`(define-ftype n (struct [fld1 ty1]
[fld2 ty2] ...))`を発行し、`n`を`Structs`refへ記録して一度しか
定義されないようにする。`chezExtPrim`の`GetField`/`SetField`
ケースは、その後単に`(ftype-ref n (fld) structPtr)` /
`(ftype-set! n (fld) structPtr val)`を発行するだけである -- Chez
Scheme自身の`ftype-ref`/`ftype-set!`が、その名前の下に既に登録
されている`define-ftype`から、フィールドの型とオフセットをマクロ
展開時に解決する。**構造体のフィールド型情報は、`Struct`/
`CFStruct`に言及する`%foreign`シグネチャを経由してのみ、バック
エンドへ流れ込む** -- 裸の`getField`/`setField`呼び出しサイト自体
は、それを一切運んでいない。

## 構造体のフィールド型が`Lifted`に実際にどう現れるか

上記の分岐の両側を、コンパイラのソースの中で直接トレースし、
「`%foreign`経由でのみ」という主張を、Chezの挙動から推測するだけ
でなく、正確に確認した:

- **`%foreign`定義は完全な`CFType`情報を、手つかずのまま、
  `Lifted`を通してずっと保持する。** `LiftedDef`自身の外部定義
  コンストラクタ(`idris2-src/src/Compiler/LambdaLift.idr:249`)は
  `MkLForeign : (ccs : List String) -> (fargs : List CFType) -> (ret
  : CFType) -> LiftedDef`である -- `%foreign`シグネチャそのままの
  `CFType`群(`CFStruct n flds`を含む、`flds`自身のフィールド名/型
  も無傷のまま)が、このコンストラクタ上のデータとして運ばれており、
  一切消去されない。rc2はこれを正確に鏡写ししている:
  `RCExp.idr`の`MkRCForeign : (ccs : List String) -> (fargs : List
  CFType) -> CFType -> RCDef`、そして`RC.idr:244`の
  `normalizeDef (MkLForeign ccs fargs ret) = pure $ MkRCForeign ccs
  fargs ret`は、無改造の直接コピーである -- ここで`Lifted` ->
  `RCExp`への変換で情報は一切失われない。
- **通常の呼び出しサイト(`getField`/`setField`、あるいはその他
  あらゆる`ExtPrim`)は、構造上、型情報を一切運ばない。** `Lifted`
  自身の`LExtPrim`コンストラクタ
  (`idris2-src/src/Compiler/LambdaLift.idr:128`)は`LExtPrim : FC
  -> (lazy : Maybe LazyReason) -> (p : Name) -> (args : List (Lifted
  vars)) -> Lifted vars`である -- 単なるプリミティブ名と値の式の
  リストだけであり、コンストラクタ自体のどこにも`CFType`スロットは
  無い。これはまさに、`prim__getField`自身の2つの型レベル引数
  (`fs`、`ty`)が生成Cの中でランタイムの`NULL`として現れる理由
  である(上記参照): `LExtPrim`自身の形のどこにも、rc2自身の
  `RC.idr`(`normalizeDef (LExtPrim fc lazy p args) = ...`。
  `MkLForeign`の扱いを直接構造的に鏡写ししており、特定の`p`に
  対する特別扱いは一切無い)がそれを目にするよりずっと前の、
  `Lifted`段階で消去が実行された時点で、その情報が住める場所が
  一度も存在しなかった。
- **rc2自身のパイプラインへの帰結:** `Compiler.RC2.RC2`の
  `toRCDefs`(`RC2.idr`)は、各`RCDef`を独立に処理する -- 現時点
  では、パイプラインのどこにも、コンパイル単位内の全ての
  `MkRCForeign`を横断して、Chezの`Structs`refがやっているような
  名前で索引付けされたテーブルを構築するパスは存在しない。あらゆる
  `getField`/`setField`実装には、まさにそれが必要である:
  **コンパイルされたプログラム全体の全ての`MkRCForeign`に対する
  第一パス**が、見つかった全ての`CFStruct n flds`を(構造体名`n`
  で)テーブルへ収集し、その*後で*、`getField`/`setField`呼び出し
  サイトの構造体名/フィールド名の文字列リテラルをそれに照らして
  解決できる**第二パス**が続く。これは、rc2が今日持っているほとんど
  の最適化パス(1つの`RCDef`を独立に変換する)とは異なる形だが --
  これはまさに`Compiler.RC2.Inline`が既に確立している形である:
  `buildEligible lds : SortedMap Name Eligible`が全ての定義を一度
  走査してルックアップテーブルを構築し、その後
  `applyInlineLifted lds = traverse (inlineDef (buildEligible lds))
  lds`がそれを使ってプログラム全体を再び走査する。構造体フィールド
  テーブルは、`Name`の代わりに構造体名(`CFStruct`由来の`String`)を
  キーにするだけで、全く同一の2段階の形に従うことになる。

## `--dumplifted`からの具体例

本家Idris2には`--dumplifted <file>`というデバッグフラグ
(`idris2-src/src/Idris/CommandLine.idr:140`、`Compiler/Common.idr`
経由で配線)があり、これは上記で説明した`LiftedDef`群を、どの
バックエンドがそれに触れるより前に、テキストとしてダンプする。
以下に対して手作業で実行した:

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

(`idris2 --dumplifted lifted.txt --cg chez -o t T.idr`)。関連する行:

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

これは上記の2つの主張と正確に一致する: 2つの`MkLForeign`エントリは
完全な`struct "point" ("x", Int) ("y", Double)`の形を運んでいる
(これは`CFStruct`自身の`Show`出力であり、フィールド名と型の両方が
無傷のまま)。2つの`LExtPrim`呼び出しサイトは、構造体名/フィールド名
の文字列リテラル(`"point"`、`"x"`/`"y"`)と、かつて`fs`/`ty`だった
場所にある2つの`___`プレースホルダしか運んでいない。

**記録しておく価値のある副次的な発見: 将来のセッションがこれを
再導出せずに済むように -- 各`LExtPrim`呼び出しの末尾にある`0`/`1`
は、また別の消去済みプレースホルダではない。それは`FieldType`証明
(`fieldok`)が単なる整数に潰されたものである。** `FieldType n t fs`
(`System/FFI.idr:19`)は、Idris2のフロントエンドが「Natのような
もの」として認識する形をちょうど持っている
(`TTImp/ProcessData.idr`の`calcNaty`。`Core/CompileExpr.idr`の
`ConInfo`の`ZERO`/`SUCC`タグによって駆動される -- これは`Nat`固有の
ハックではなく、一般的な構造チェックである: 2つのコンストラクタ、
一方は0引数、もう一方は1つの引数を持ち同じ型コンストラクタへ再帰
する): `First : FieldType n t ((n, t) :: ts)`(0引数)が`ZERO`を
演じ、`Later : FieldType n t ts -> FieldType n t (f :: ts)`(1つの
再帰引数)が`SUCC`を演じる。つまり`FieldType`証明は、文字通りの
`Nat`と同じように単なる整数へ下降する -- 具体的には、構造体自身の
フィールドリスト内でのそのフィールドの0始まりの位置である(`"x"`は
フィールド0 -> `First` -> `0`; `"y"`はフィールド1 -> `Later First`
-> `1`)。

この位置を表す整数は、`getField`/`setField`実装が依拠する必要のある
ものではない -- Chez自身の`chezExtPrim`はこれを完全に無視している
(`GetField`自身のパターンマッチは裸の`_`で終わる)。代わりに純粋に
構造体名/フィールド名の文字列リテラルから解決しており、どのrc2の
設計もこれと同様にすべきである(フィールドの*位置*だけでは、その
*型*は運ばれない。型は依然として上記の`CFStruct`テーブルからのみ
回復可能である)。ここに記録したのは、これがダンプの中の説明の無い
`0`/`1`であり、恣意的なものではなく本物の、追跡可能な説明を持つと
判明したからにすぎない。

## 本家Idris2自身のissueトラッカーが述べていること

何かを設計する前に、既に誰かがこの壁にぶつかっていないかを確認する
ため、`idris-lang/Idris2`自身のissueで先行事例を検索した。ぶつかって
いた -- そしてそのうちの1件は、まさに本書の「構造体のフィールド型が
`Lifted`に実際にどう現れるか」節が独立に導出したのと同じ問題に
突き当たり、その後諦めていた。

- **[#3830](https://github.com/idris-lang/Idris2/issues/3830)**
  (2026-08-09に開かれ、まだ開いたまま、コメントなし): 上記で再現
  したのと全く同じクラッシュを報告している -- 本家自身の
  `samples/ffi/Struct.idr`に対する`idris2 --cg refc`は`ERROR:
  INTERNAL ERROR: Struct access not implemented: var_1`に突き当たり、
  本書が既に引用している`RefC.idr:763`の同じ`extractValue`の
  `idris_crash`まで追跡されている。この隙間が本物で、本家では現在
  未修正であり、この調査自身の再現コードの書き方に特有のもので
  ないことを裏付けている。
- **[#2062 "Align FFI with C FFI"](https://github.com/idris-lang/Idris2/issues/2062)**
  (2021-11-22に開かれ、2022-07-21にクローズ、議論は2026-08-31まで
  続いた): 最も直接関連する発見。ユーザー`xavierzwirtz`はRefC
  バックエンド向けに`getField`サポートを実装しようとし、5か月後に
  こう書いていた:
  > コンパイラは現在`CFType`を`MkForeign`に対してしか計算せず、
  > その`CFType`は`MkForeign`の戻り値型に使える形では紐付けられて
  > いません。`prim__getField`が動作するには、`prim__getField`の
  > 適用をコンパイルする際にアクセスされたフィールドの`CFType`を
  > 使って`packCFType`を呼び、RefCランタイム向けにパックできる
  > よう、式に`CFType`を紐付ける必要があると思います。要するに、
  > refcバックエンドの中から任意の式について`CFType`を得るには
  > どうすればいいのでしょうか?

  誰も答えなかった。その6か月後、「どうやってこれを解決したのか」
  と直接尋ねられ、彼はこう返信した: **「私は見切りをつけて先へ
  進みました。現状のIdrisのメモリモデルは、構造体渡しとうまく
  噛み合っていません。」** これは、本書自身の`Lifted`トレースが
  見つけたのと全く同じ隙間 -- `CFType`情報がどの`LExtPrim`呼び出し
  サイトでも消えてしまうこと -- を、実際に試みた人物から独立に
  裏付けるものである。

  **本書自身の計画が彼の求めていたものとどう異なるか**(そして
  なぜ彼が成功しなかったところで成功しうるか): xavierzwirtzは
  *任意の式*に対して`CFType`を回復する方法を求めていた -- 完全に
  一般的な機構である。彼のコメントには、本書が提案するより狭い
  アプローチ -- 式から型を回復することを一切せず、(呼び出しサイト
  まで生き残ることが上記で確認済みの)構造体名/フィールド名の
  *文字列リテラル*を、全ての`%foreign`シグネチャ自身の`CFStruct`
  から一度だけ構築したテーブルに照らして解決する。まさにChezの
  `Structs`/`mkStruct`が既にやっていることであり、彼がゼロから
  一般的に解決しようとするのではなくChez自身のアプローチから再導出
  していたはずのもの -- を検討した形跡は無い。この狭い道こそが、
  まさに彼がそれを見つけられなかった理由である可能性に注意を払う
  価値がある -- 彼は実際に必要な問題よりも難しい問題を解こうと
  していたのかもしれない。
- **[#1916 "Add support for value structs"](https://github.com/idris-lang/Idris2/issues/1916)**
  (2021年、#2062に有利な形でクローズ): *値渡しの*構造体FFI(Chezの
  `(& ftype)`対`(* ftype)`)についてであり、ポインタベースの
  `getField`/`setField`とは異なる、より難しい問題である -- 本書の
  スコープ外だが、上記の#2062を生んだ議論である。
- **[#36 "Nested Structs in FFI not read correctly"](https://github.com/idris-lang/Idris2/issues/36)**
  (2020年、まだ開いたまま): *Chez固有の*バグ -- それ自体が*値渡し*
  の構造体であるフィールド(`Ptr`ではなく)は誤った値を読む。これは
  `Struct`が(`define-ftype`自身のフィールドリストを含む)あらゆる
  場所で暗黙にポインタだと仮定されており、(メンテナ`edwinb`自身の
  コメントによれば)その区別をChez Schemeへ表現する方法が無いため
  である。scalarフィールドのみを対象とする最初のrc2実装の範囲外
  だが、ネストした構造体フィールドがいつかサポートされる場合には
  意識すべき本物の先行バグである -- そして注目すべきことに、rc2は
  Chezのような`ftype`ではなく本物のC `typedef struct`を発行する
  ため、これを無償で回避できるかもしれない。C自体はこのポインタ/
  値の曖昧さを共有していないためである。
- **[#3809 "FFI improvements (explicit Ptr) and additions (Union type and nested data fields)"](https://github.com/idris-lang/Idris2/issues/3809)**
  (2026-07-08に開かれ、開いたまま、まだコメントなし): 最近の、より
  野心的な提案 -- ポインタ`Struct`への明示的な`Ptr`、ネストした
  フィールドへのアクセスパス、非ポインタの構造体フィールド、そして
  `union`サポート -- Chezバックエンド向けのPRが添付されていると
  報告されている。本書のスコープ(基本的なscalarフィールドの
  `getField`/`setField`)を大きく超えているが、本家自身の
  `System.FFI`モジュールが今後進みうる方向として知っておく価値が
  ある。

## 設計: 専用の`RStructGet`/`RStructSet`ノード、`Emit.idr`で解決

この設計の初期の草案は、`getField`/`setField`を単純な`RExtPrim`
呼び出しのまま`Emit.idr`までずっと保持し、そこでのみ特別扱いする
というものだった。下記の所有権の隙間を発見した後に決めた現在の
方向: `prim__getField`/`prim__setField`を、早い段階
(`Compiler.RC2.RC`自身の`normalize`、Phase 1)で2つの新規の専用
`RCExp`ノードへ変換し、発行時に`RExtPrim`自身の汎用的な
`args : List RCLocal`の形をパターンマッチするのではなく、*それら*
のノードを構造体フィールドテーブルに照らして解決する。構造体名/
フィールド名は新規ノード上では単純な`String`のままである -- それを
プログラム全体のテーブルに照らして解決する処理は、初期の草案が
それを置いた場所(`Emit.idr`自身の`generateCSourceFile`)にそのまま
留まる。変わるのは*どのノード*がそのテーブルまでそれを運ぶかだけ
である。

### `RExtPrim`を直接下降させるのではなく専用ノードにする理由

実際にrc2で構造体を使うプログラムをコンパイルし、`RCExp`ダンプと
`RC.idr`自身のソースの両方を読んで確認した(コンストラクタの形だけ
から仮定したのではない)2つの事実:

1. `getField`/`setField`呼び出しサイトの構造体名とフィールド名の
   引数は、`RCExp`自体では`RCConst (Str ...)`であり、ランタイム
   ルックアップの背後にステージされたものではない -- コンパイル
   時に直接パターンマッチ可能であり、それらを回復するための追加の
   配線は不要である(初期の草案から変わっていない、依然として真)。
2. **`RExtPrim`は実際には、他のあらゆるオペランド消費ノードと
   同じ所有権処理を受けていない。** `RAppName`/`RUnderApp`/
   `RApp`/`RCon`/`ROp`自身の`annotate`(Phase 2、`RC.idr`)ケース
   は全て、同じ`wrapDups fc (splitBorrows natives owned args)
   (...)`パターンを通る -- `splitBorrows`は`args`を現在の`owned`
   集合に照らして歩き、まだ生きているオペランドを`dup`させ
   (`wrapDups`)、最後に使われるオペランドはそのまま所有権を移譲
   させる。対照的に`RExtPrim`自身のケース(`annotate natives owned
   (RExtPrim fc lazy p args) = pure $ RExtPrim fc lazy p args`、
   `RC.idr:504`)は裸の素通しである -- `splitBorrows`も
   `wrapDups`も無く、`owned`は参照すらされない。

   上記の実例をrc2自体でコンパイルし(`--directive dumprcexpr`、
   `idris2-rc2 --cg rc2`)、仮定するのではなく`annotate`が実際に
   何を決定したかを読んで確認した:

   ```
   def Main.getX  (fun args=["v0:Boxed"] ret=Boxed)
     extprim System.FFI.prim__getField [#"point", [__], [__], v0, #"x", #0]
   ```

   `getX`自身の本体のどこにも`v0`を包む`RDrop`/`RDup`は無い --
   それは何のラッピングも無いまま`extprim`呼び出しに到達しており、
   これはちょうど一度だけ使われる構造体ポインタにとっては*正しい*
   (これが唯一の使用箇所なので、所有権もろともそのまま渡すのが
   正しい) -- しかし、同じ関数内で同じ構造体ポインタが2つの
   `getField`呼び出しで読まれた場合、`RExtPrim`自身の`annotate`
   ケースの何一つとして正しい答えを計算し続けることはない:
   `owned`が一度も参照されないので、2回目の呼び出しは既に消費
   済みの参照を受け取ってしまう。これは本書が一般に修正すべき
   バグではない(現在の`RExtPrim`のあらゆる利用者 -- `prim__newIORef`、
   配列プリミティブなど -- は、実際には常に末尾/単一使用の位置
   にしか現れない)が、これは`RExtPrim`の既存の所有権処理が、新規
   の、複数回使われる可能性のある構造体アクセサがそのまま継承
   すべきものではないことを意味する。

専用ノードはこれを回避する -- しかし、それが正確に*どれだけの*
所有権機構を必要とするかを見極めるには、1回ではなく3回のパスが
必要だった。それぞれ、この設計中に直接のフィードバックによって
訂正された。将来のセッションが同じ間違った曲がり角を再びたどら
ずに済むよう、ここに記録する:

**パス1(誤り): `ROp`の`postDrop`/`splitBorrows`/`wrapDups`
パターンをそのまま再利用する**、`structVar`を`ROp`自身のオペランド
と同様に消費されるオペランドとして扱う。却下: `getField`/
`setField`は単純なCのポインタ参照解決/代入(`s->x`、`s->y = v`)へ
下降する -- ポインタ越しの読み書きは、そのポインタ自身の参照カウント
に一切触れない。そのため、以前の`RExtPrim`ベースの設計自身の
`postDrop`がやっていたように「引数を消費する」ものとしてモデル化
すべき*関数呼び出し*が残っていない。

**パス2(これも誤り): 両方のオペランドについて所有権機構を完全に
排除する** -- どちらのノードにも`postDrop`フィールドを一切持たせず、
`structVar`/`value`は決して消費されないので追跡すべきものが何も
無いと推論した。これは(下記「実際に真であること」参照)*半分*
正しいが、本物のケースを見逃している: `RStructGet`/`RStructSet`
経由でしか読まれず、二度と使われない変数(例えば`f s = getField s
"x"`、`s`はその後一度も使われない)は、それでも*いずれ*drop
される必要があり、そうしなければリークする。「それが束縛されて
いたスコープが何であれ、通常の`dropDeadLet`機構経由でそれを
dropしてくれるはずだ」というこのパスが依拠していた推論は、
実際には成り立たない: `dropDeadLet`/`dropUnusedOwnedVars`
(`RC.idr`、`branchBody`)は、ある変数をdropするかどうかを、
`freeLocalsR`が本体の*その後*でそれを依然として使用中だと報告
するかどうかで決める -- そして`RStructGet`が(生存性を追跡できる
ためには必然的に)`structVar`を自身の自由なローカルの1つとして
正しく報告するようになった時点で、この検査は`getField`呼び出し
サイトで`s`が「まだ使用中」だと判断し、したがってそこでも一度も
dropしない。呼び出しサイトも囲むスコープもそれをdropしないので、
`s`はリークする。まさにこの再現コードに対して`annotateDef`/
`branchBody`/`dropUnusedOwnedVars`を手作業でトレースして確認済み。

**実際に真であること、そしてその結果の設計:** `structVar`/`value`
は一度も*複製*されない(Cレベルでポインタをコピーする理由も、
一度だけ、あるいは100回使うためだけに既にBoxedなオペランド自身の
フィールドを再読み込みする理由も無い) -- パス2の核心の洞察は
生き残る。しかし、現在の使用が、そのオペランド自身の本当に最後の
使用である場合、他の通常のBoxedローカルと全く同じように*drop*は
依然として必要である。これは本物の、より狭いとはいえ、第三の形
である -- `ROp`の「まだ生きていれば常にdup、その後常にdrop」でも、
パス2の「決してdupしない、決してdropしない」でもない:

```idris2
||| [v] この使用が、囲むスコープにおけるv自身の最後の使用であり
||| (vはまだownedに残っている -- 上流の誰もそれを既に主張済み・
||| drop済みでない)、かつNativeでない場合; それ以外は[]
||| (その後もまだ生きている -- 借用であり、どちらにせよdupは
||| 不要である。ポインタ越しの読み取りはコピーを一切必要としない
||| ので -- あるいはNativeなローカルであり、そもそもBoxedの
||| 参照カウント対象では一度もない)。splitBorrowsとは異なり、
||| 決してdupしない: その後もまだ生きているオペランドは、ここでは
||| 一切の処置が不要である。
dropIfLastUse : SortedSet RCLocal -> Owned -> RCLocal -> List RCLocal
dropIfLastUse natives owned v =
    if contains v owned && not (contains v natives) then [v] else []
```

### 新規ノード

```idris2
||| Cの構造体ポインタから1つのフィールドを読む -- 純粋であり、
||| structVarを決して複製しない(Cのポインタ参照解決であって、
||| 何かを消費する呼び出しではない -- 上記「専用ノードにする理由」
||| 参照)。それでも、これがstructVar自身の最後の使用であれば
||| dropは必要 -- postDropがそれを捉える(0または1要素、
||| Compiler.RC2.RCのannotateがdropIfLastUse経由で計算する。
||| ROp自身のフィールドを鏡写ししているが、ROpのそれとは異なり
||| dupを一切引き起こさない)。structName/fieldNameは単純な文字列
||| のままである -- Emit.idr自身のgenerateCSourceFileで一度だけ
||| 構築されるプログラム全体の構造体フィールドテーブルに照らして
||| 解決される(下記「Part B/C/D」参照)。これはRPrimVal自身の
||| dyngen/orStagenがリテラルの具体的なCレンダリングを遅く解決
||| するのと同じ流儀であり、ここで事前にCFTypeへ解決済みなわけ
||| ではない。
RStructGet : FC -> (structVar : RCLocal) -> (structName : String) ->
             (fieldName : String) -> (postDrop : List RCLocal) -> RCExp

||| Cの構造体ポインタへ1つのフィールドを書き込み、Unitへ評価
||| される。structVar/valueの両方について、RStructGetと同じ理由
||| 付けが成り立つ -- これがそれ自身の最後の使用であれば、どちら
||| も(0、1、または2要素)postDropに入りうる。どちらも決して複製
||| されない。
RStructSet : FC -> (structVar : RCLocal) -> (structName : String) ->
             (fieldName : String) -> (value : RCLocal) ->
             (postDrop : List RCLocal) -> RCExp
```

どちらのノードも`ROp`自身の`postDrop`フィールドは保持しているが、
その`splitBorrows`/`wrapDups`のdup挿入半分は保持していない -- 本物
のハイブリッドな形であり、単純に`ROp`のものでも単純に`RV`のもので
もない。`ROp`ノードの`postDrop`をどう扱うかを既に知っている全ての
場所(`RCExp.idr`の`freeLocalsR`/`countUsesR`/`usedConstructorsR`、
`Compiler.RC2.Reuse`、`Compiler.RC2.Sink`の`consumedOperands`、
`Compiler.RC2.Loop`の`stripOwnership`)は、新しいパターンを発明する
のではなく、コピーすべき近い構造的先例を得ることになる -- 本書は
それらの各サイト自身が必要とする変更を今のところ全て列挙しようと
はしていない(それは実装作業であって、設計ではない)。

### Phase 1(`normalize`): `LExtPrim`/`RExtPrim`を新規ノードへ変換する

`Compiler.RC2.RC`の`normalize`において、汎用の`LExtPrim fc lazy p
args => bindMany env args (\locs => pure $ RExtPrim fc lazy p
locs)`(`RC.idr:163-164`)より前に、`p`の名前を具体的に
`prim__getField`/`prim__setField`と照合するケースを追加する。
`args`自身の形は既に確認済みである(上記「具体例」参照): 構造体名/
フィールド名の`String`を、それらが座る`RCConst (Str ...)`の位置から
そのまま取り出し、構造体ポインタ/値の`RCLocal`群は保持し、消去
された`fs`/`ty`プレースホルダと`FieldType`の位置整数は破棄する
(本書の他の箇所で、これがフィールド名文字列に対して冗長であり、
どの実装もそれに依存すべきでないことを確認済み)。`RStructGet`/
`RStructSet`を直接構築する -- `postDrop`はここでは空から始まる。
`ROp`自身のPhase 1の形が常に`postDrop = []`を構築し、それを埋める
のをPhase 2に任せているのと同じやり方である(`RCExp.idr`の`ROp`
コンストラクタ自身のドキュメントコメント参照)。

### Phase 2(`annotate`): 所有権

```idris2
annotate natives owned (RStructGet fc structVar sn fn _) =
    pure $ RStructGet fc structVar sn fn (dropIfLastUse natives owned structVar)
annotate natives owned (RStructSet fc structVar sn fn value _) =
    pure $ RStructSet fc structVar sn fn value
             (dropIfLastUse natives owned structVar ++ dropIfLastUse natives owned value)
```

(`dropIfLastUse`は上記「専用ノードにする理由」で定義済み。)どちら
のケースも`splitBorrows`/`wrapDups`を呼ばない -- ポインタ越しの
読み取りや、既にBoxedなオペランド自身のフィールドの再読み込みは
コピーを一切必要としないので、`dup`は一度も挿入されない -- しかし
どちらも`owned`を参照して、*この*使用がそのオペランド自身の最後の
使用かどうかを判定する。これはまさに上記のパス2が省略して誤って
いた検査である。これは「専用ノードにする理由」が`RExtPrim`自身の
処理の中に見つけた隙間を閉じるが、パス1が最初に試したように`ROp`の
パターンをそのまま再利用することによってでも、パス2がその後試した
ように所有権追跡を完全に排除することによってでもなく、真に新しい
パターン(`dropIfLastUse`)によってである。

### Part A: ポインタ渡しの構造体FFI自体は新しいロジックを一切必要としない -- `CFStruct`は`CFPtr`の既存処理をそのまま再利用できる

両者を並べて比較して確認済み: `cTypeOfCFType CFPtr = "void *"`と
`cTypeOfCFType (CFStruct x ys) = "void *"`は既に一致している
(`Emit.idr:2241`/`2247`) -- この設計では構造体は常にポインタ経由で
アクセスされる(上記で既に確認済みの「全ての構造体名は`%foreign`
シグネチャに現れなければならない」という契約に一致し、Chez自体が
仮定していることとも一致する -- その仮定が成り立たない場合に何が
壊れるかは、上記「本家のissueトラッカーが述べていること」の#36
参照)。そのため、実際に壊れている2つのケース --

```idris2
extractValue _ (CFStruct x xs) varName = idris_crash "..." -- Emit.idr:2295
packCFType (CFStruct x xs)     varName = "makeStruct(" ++ varName ++ ")" -- Emit.idr:2319、未定義の関数
```

-- は、`CFPtr`自身の既に動作している行の直接コピーになりうる:

```idris2
extractValue _ (CFStruct x xs) varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
packCFType (CFStruct x xs)     varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
```

これだけで、構造体ポインタを受け取る、または返す`%foreign`関数
(上記の実例の`prim__makePoint`/`prim__pointFree`)が修正される --
`getField`/`setField`とは独立しており、リスクが低い: 既に検証済みの
コードパスを再利用しているだけで、新しいロジックではない。

### Part B: 収集フェーズ

`generateCSourceFile`の先頭、`traverse_ (uncurry createCFunctions)
defs`が実行される前に、全ての`(Name, RCDef)`ペアを歩いて
`MkRCForeign ccs fargs ret`を探し、Chezの`mkStruct`(上記引用)が
やっているのと同じ方法で`fargs`/`ret`自身の`CFType`群を再帰する --
`CFIORes`/`CFFun`を通して、内側にネストしているかもしれない
`CFStruct n flds`を探す。見つかった全ての`(n, flds)`を、
`generateCSourceFile`が既に用意している既存の`ConstDef`/
`OutfileText`などのref群と並んで登録される新規の`Ref StructDefs
(SortedMap String (List (String, CFType)))`へ収集する。これは
Chezの`Structs`/`mkStruct`の直接的な構造的移植である -- 同じ再帰の
形、同じ「最初に見つかった構造体名が勝ち、再発行しない」重複排除
-- ただし`List String`の`Ref`を糸通しする代わりに`SortedMap`を
構築し、発行するSchemeコードは一切無い。

### Part C: C構造体定義の発行

`header`(`Emit.idr`、`generateCSourceFile`内の`traverse_`の直後に
呼ばれるため、`createCFunctions`中のフィールド型解決が発行順序に
依存しない)において、`StructDefs`テーブルの各エントリごとに1つの
`typedef struct { ... } name;`を発行し、各フィールドの`CFType`を
既存の`cTypeOfCFType`経由で変換する -- 新しい型からC型への変換
ロジックは不要であり、それは既に`%foreign`の引数/戻り値型のために
存在しており、構造体フィールドも同じ種類の型である。

### Part D: `emitRC`での`RStructGet`/`RStructSet`の下降

`emitRC`(`Emit.idr:1882`、既存の`RExtPrim`ケースの隣)にケースを
追加する(`prim__getField`/`prim__setField`は、一度Phase 1がそれらを
変換すればもうそこには一切到達しないので、既存の`RExtPrim`ケース
自身のホワイトリスト/汎用呼び出しロジックには触れる必要がない):

```idris2
emitRC (RStructGet fc structVar sn fn postDrop) _ = do
    fields <- getStructFields sn   -- Part BのRefを参照する
    let Just ty = lookup fn fields | Nothing => throw (InternalError ...)
    ptr <- rcVarToC structVar      -- extractValue CFPtrのレンダリングを再利用(Part A)
    removeVars $ map varName postDrop   -- structVarがこれが最後の使用だった場合のみdropする
    pure $ packCFType ty ("((\{sn}*)\{ptr})->\{fn}")
emitRC (RStructSet fc structVar sn fn value postDrop) _ = do
    fields <- getStructFields sn
    let Just ty = lookup fn fields | Nothing => throw (InternalError ...)
    ptr <- rcVarToC structVar       -- どちらもここへ至るまでに複製されない --
    valC <- rcVarToC value          -- extractValue ty、value自身のRepがtyと一致するため
    removeVars $ map varName postDrop   -- structVar/valueのどちら(0、1、
                                         -- または両方)がこれの最後の使用だったかに応じてdropする
    pure $ "(((\{sn}*)\{ptr})->\{fn} = \{extractValue ty valC}, (IDRIS2RC2_Value*)NULL)"
```

(スケッチであり最終的な構文ではない -- `getStructFields`は「Part B
が投入する`StructDefs`という`Ref`を参照する」ことを表す。`Ref`/
エラー処理/C文とC式のどちらの位置として糸通しされるかの正確な配線
は、囲む`emitRC`ケースが既に使っている流儀に従うものとし、ここでは
それ以上設計しない。)`packCFType`/`extractValue`は、Part Aが
`CFStruct`自体に対して既に修正した同じ既存関数であり -- ここでは
構造体ポインタ自身のものではなく*フィールド*の`CFType`について再び
再利用されている。`postDrop`(上記Phase 2で`dropIfLastUse`により
計算される)は、このコードに、`structVar`/`value`のどちら(あれば)
をdropすべきかを正確に伝える -- これは`postDrop`を運ぶ他の全ての
ノードが既に持っているのと同じ契約であり、Emit.idrはここで所有権を
再導出しない。

### 本家から実際に何が移植できるか、具体的に

rc2は完全に独立したパッケージであり、`idris2-src`を一切編集せず
(`README.md`自身の「What's here」参照)、そこからコードを`import`
することもできない -- そのためここでの「移植」は、ファイルを
コピーすることではなく、同じロジックをrc2自身の流儀で再導出する
ことを意味する。それが具体的に何になるか:

- **直接のアルゴリズム移植**(同じ形、rc2自身の慣用句で書き直し):
  `Structs`ref-and-`mkStruct`の構造体名ごとに一度だけ収集する
  パターン(上記Part B) -- これは`%foreign`定義自身の戻り値/引数型
  への`CFIORes`/`CFFun`再帰を含め、真に「同じ考え方、別の言語」で
  ある。
- **全く不要、既存のrc2コードで既にカバー済み**: Chezの`cftySpec`
  (`CFType`ごとのScheme型文字列生成)には、書くべきrc2の同等物が
  無い -- `cTypeOfCFType`/`extractValue`/`packCFType`は、既に他の
  全ての`CFType`について類似の仕事をしており、`CFStruct`は
  ゼロから再実装するのではなく、上記のPart A/Cがやっているように
  既存のケースごとの関数へ追加するだけでよい。
- **移植不可能、新規に書く必要がある**: `chezExtPrim`の
  `GetField`/`SetField`ケースはScheme(`ftype-ref`/`ftype-set!`)を
  発行し、Chez Scheme自身のマクロ展開時の型解決に依存している。
  rc2はCを直接発行し、Part Bで構築した`StructDefs`テーブルに照らして
  自前で解決を行う。同じ問題への、構造的に無関係な解法である --
  Part D(および上記の`RStructGet`/`RStructSet`ノード/Phase 1/
  Phase 2機構)はオリジナルの設計であって移植ではない。Chezには
  また、この設計の専用ノードのステップに相当するものが全く存在
  しない -- Scheme自身の動的型付けにより、`chezExtPrim`は
  `ExtPrim`から直接`GetField`/`SetField`を下降させることができ、
  rc2の`RExtPrim`が持つような所有権追跡の隙間(上記「専用ノードに
  する理由」参照)を回避する必要が無い -- そのため、この設計の
  その部分には移植元となる本家の類似物が全く存在しない。

## rc2自身の設計についての未解決の問い

- ~~未確認: Chezを含むどのバックエンドでも、プログラムが
  `%foreign`シグネチャに一切言及されていない構造体名に対して
  `getField`/`setField`を使った場合に何が起きるか~~ **確認済み:
  Chezもコンパイル時に失敗する。** この調査自身の上記の再現コードを
  `idris2 --cg chez`で直接実行した: `Exception: unrecognized ftype
  name my_struct ... / Error: INTERNAL ERROR: Chez exited with
  return code 255` -- Chez Scheme自身の`ftype-ref`マクロ展開は、
  その名前について一度も`(define-ftype my_struct ...)`が発行されて
  いない場合(つまり`Struct "my_struct" ...`に言及した`%foreign`
  シグネチャが一度も無い場合)、完全に失敗する。そのため、
  `getField`/`setField`と共に使われるあらゆる構造体名が、プログラム
  内のどこか少なくとも1つの`%foreign`シグネチャに現れていることを
  要求するのは、rc2が新たに課す制約ではない -- それは既存の本家の
  契約であり、リファレンスバックエンドによって(理想よりは遅く --
  Idris2コンパイル時ではなくScheme マクロ展開時に、ではあるが)既に
  強制されているものである。rc2はこれに依拠でき、「構造体名が一度も
  宣言されていない」ケースを、それ自身のコンパイルエラー以外の
  何かとして扱う必要は無い。
- ~~まだスコープされていない: フィールド値がrc2自身のBoxed/
  Native `Rep`の分割とどう相互作用するか~~ **解決済み: 構造体
  フィールドはそれ自体が一度もBoxed(`IDRIS2RC2_Value*`)値になる
  ことはないので、`ConAltNative`風のエイリアシング/dupの問いは
  そもそも一切発生しない。** `CFStruct`自身のフィールドリストは
  `List (String, CFType)`(`Core/CompileExpr.idr:199`)であり、
  `CFUser`以外のあらゆる`CFType`は、自身のストレージを持つ本物の
  C型を表す(`CFInt`/`CFDouble`/`CFPtr`/ネストした`CFStruct`など)
  -- これはまさに`cTypeOfCFType`が既に各ケースについてレンダリング
  しているものである。`CFUser : Name -> List CFType -> CFType`
  (任意のIdris2型、`extractValue`自身の`(CFUser x xs) varName =
  "(IDRIS2RC2_Value*)" ++ varName`ケース経由でBoxedとしてレンダ
  リングされる)は型*文法*の中には存在するが、真にBoxedな、
  参照カウントされるIdris2の値には、意味のあるC構造体メンバー
  ストレージが無い -- `int`/`double`/単純なポインタフィールドが
  持つような、「このGC自身の生存期間に紐付けられたポインタを保持
  するスロット」のための本物のCレイアウトは存在しない。そのため
  `RStructGet`/`RStructSet`自身のフィールド型ルックアップは、
  `CFUser`型のフィールドをスコープ外(構造体収集時のエラー、
  Part B)として扱うことができ、本物の所有権設計を必要とするケース
  として扱う必要はない -- `getField`/`setField`の読み書きは常に、
  真にC型を持つスロットに対する`packCFType`/`extractValue`変換で
  あり、既にBoxedな値のエイリアシングされた読み取りでは決して
  ない(コンストラクタ自身のdestructureされたフィールドとは異なる。
  あちらは*本当に*Boxedストレージへの直接のエイリアスであり --
  `Compiler.RC2.ConAltNative`自身の問題であって、これの問題では
  ない)。scalarフィールドのネイティブな(unboxed)読み書き、つまり
  どのみちネイティブコンテキストで使われる値についての
  `packCFType`/`extractValue`往復を回避する処理は、依然として
  もっともらしい将来の作業ではある(`Compiler.RC2.ConAltNative`が
  通常のコンストラクタdestructureされたフィールドについて既に
  やっているのと同じ形、`rc2/doc/con-alt-native.md`)が、それは
  動作する、常にBoxedなバージョンの上に乗るパフォーマンス最適化で
  あり、その前提条件ではない。
- ~~まだ列挙されていない: `RStructGet`/`RStructSet`ケースの追加が
  必要な全てのサイト~~ **完了 -- 下記「実装状況」参照。** `RCExp`
  に触れる全てのパスが監査された。2件の本物の隙間が見つかり修正
  された(`Loop.idr`の`stripOwnership`、`Sink.idr`の
  `genuinelyUsedR`)。残りは、自身のワイルドカードの素通しにより
  既に正しいことが確認された。

## 実装状況

`c-struct-support`ブランチ(`RCExp.idr`、`RC.idr`、`Loop.idr`、
`Pretty.idr`、`Emit.idr`、`Sink.idr`、加えて`DualABI.idr`/
`ConAltNative.idr`/`Reuse.idr`へのコメントのみの更新)に、上記の
設計をほぼそのまま実装した -- 実装中に行われた、設計では想定されて
いなかった唯一の改良は`dropIfLastUse`そのものである:
`RStructGet`/`RStructSet`は`splitBorrows`/`wrapDups`を一切呼ばない
(オペランドが複製されることは一度も無い)が、素朴に「何もdropしない」
と設計を読むと、ちょうど一度しか使われず二度と使われない構造体
ポインタ(`f s = getField s "x"`)がリークしてしまう -- 上記で説明
した、`owned`を参照するが`dup`は一切挿入しないという形に落ち着く前
に、まさにこの再現コードに対して`annotateDef`/`branchBody`/
`dropUnusedOwnedVars`を手作業で追跡した。

**手作業で検証済み**、専用の`verify.sh`統合の回帰テストはまだ存在
しないため(下記参照): `%foreign`シグネチャ経由で構造体を宣言し、
その後複数のフィールドを読み書きするプログラム(あるフィールドを
2回再読み込みすること、そして`setField`の値オペランドをその後さらに
3回再利用することを含む -- `RStructGet`と`RStructSet`の両方で
`dropIfLastUse`の出現順序処理を演習する) --

- クリーンにコンパイルされ、期待通りの出力を生成する、
- 以下のような形のCを生成する(「具体例」節と同じスタイル):
  ```c
  typedef struct { int64_t x; double y; } point;
  /* ... */
  IDRIS2RC2_Value *primVar_9 = idris2rc2_mkInt64(((point*)((IDRIS2RC2_Pointer*)var_0)->p)->x);
  idris2rc2_drop(var_0);
  return primVar_9;
  ```
  (`RStructGet`、直接のポインタ参照解決、`postDrop`が単純な
  `idris2rc2_drop`として処理される、分岐やdupはどこにも無い)、
  および
  ```c
  ((point*)((IDRIS2RC2_Pointer*)var_0)->p)->y = (idris2rc2_to_double(var_1));
  idris2rc2_drop(var_0);
  idris2rc2_drop(var_1);
  ```
  (`RStructSet`、同じ形、両方のオペランドがdropされるのは、その
  特定の呼び出しサイトがたまたまそれぞれの最後の使用だった場合
  のみ)、
- 試した全てのバリエーションで`valgrind --leak-check=full`が
  クリーン(`definitely lost: 0 bytes`、`0 errors`)である。

**追加の監査**(直接のレビューによって促された、上記のフィールド
再利用のケースが既にレビューで捕まって修正された後)が、`RCExp`に
触れる他の全てのパスについて、自身のワイルドカードの素通しが2つの
新規ノードを正しくカバーしているかを検査した。本物の隙間が2件
見つかり、修正された:
- `Loop.idr`の`stripOwnership`は、`ROp`/`RCmpCase`/`RLoopContinue`/
  `RLoop`自身の`postDrop`/`prologueDrop`フィールドから`ids`を
  フィルタする(ローカルをネイティブshadowへ昇格させる際に
  `Compiler.RC2.ConAltNative`/`Compiler.RC2.DualABI`が使う)が、
  同じ種類の`postDrop`フィールドを持つ`RStructGet`/`RStructSet`に
  ついては自身のワイルドカードで素通ししてしまっていた --
  ネイティブに昇格されたローカルがそこに生き残ると、そもそも一度も
  boxされたことのない値に対してdropを発行してしまうことになる。
- `Sink.idr`の`genuinelyUsedR`(`RCExp.idr`自身の`freeLocalsR`に
  ほぼ同一の自由変数解析)は、`structVar`/`value`を本物の使用として
  数えていなかった。これは、branch-sinking自身の本物の、既に修正
  済みのミスコンパイル(`TestBuffer.idr`、`rc2/doc/branch-sinking.md`
  の「varの死を通り越して剥がさない」参照)を引き起こしたのと同じ
  クラスのバグである -- 捕まえられないまま放置されると、
  `trySinkInto`の`RLet`ケースが、実際にそれを読んでいる
  `getField`/`setField`呼び出しを通り越して束縛を沈めてしまい、
  生成されたCの中に定義前使用の参照を生み出してしまう可能性が
  あった。

監査された他の全てのサイト(`Reuse.idr`の`tryClaim`/`tryConsume`/
`resolveReuse`、`ConAltNative.idr`の`peelWrappers`/
`applyConAltNativeExp`、`MutualLoop.idr`の`tailCallTargets`/
`buildGroup` -- これはリネームを完全に`Loop.idr`自身の
`renameRCExp`に委ねており、最初の実装と合わせて既に修正済み --
そして`DualABI.idr`の`tailValueReps`/`applyCallSiteRewriteBody`)は、
自身のワイルドカードの素通しが両方の新規ノードについて既に正しい
ことを確認した -- 特定のノードリストの名前を挙げているコメントは、
それが存在した箇所で明示的にそう述べるよう更新されたが、挙動の
変更は不要だった。フルの`refc-suite`(19/19)とスモークテスト
(23/23)の回帰スイートは全体を通して変更なく通過し -- 新規ノードも、
`Emit.idr`の`where`節のリファクタ(Part Aの`cTypeOfCFType`/
`extractValue`/`packCFType`をトップレベルへ引き上げたこと)も、
何も後退させていないことを確認した。

**今や適切な`rc2/tests/verify.sh`統合の回帰テストを持つ**:
`rc2/tests/Test24CStructSupport.idr`は、本物のコンパニオンCの
コンストラクタ/デストラクタペア(`Test24CStructSupport.c`/`.h`)を
伴い、`RStructGet`/`RStructSet`自身の`dropIfLastUse`所有権処理を
直接演習する -- あるフィールドを連続して2回再読み込みすること
(`structVar`が2回使われ、どちらの回も`dup`されない)と、
`setField`呼び出し自身の`value`オペランドをその後さらに3回再利用
することである。`verify.sh`自体も、これに必要な一般的な機構を
獲得した: `TestN.idr`の隣に`TestN.c`があれば、それは一度コンパイル
され、`IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS`経由で自動的にリンクされる
-- 他の既存の全てのテストにとっては何もしないが、本物のC実装が
必要な(rc2/RefC提供のプリミティブだけでは足りない)`%foreign`宣言
を持つ将来のあらゆるスモークテストで再利用可能である。手作業で
検証された`.expected`を伴う`NO_REFC_DIFF_TESTS`(本物のRefCには
diff対象となる`getField`/`setField`が無い)と`LEAK_SENSITIVE_TESTS`
(所有権の正しさこそがこのテストの全てである)に加わった。フルの
`verify.sh`実行: 39件成功、1件は既知の既存(`Test1Basics`自身の
記録済みリーク、無関係)、0件失敗 -- このテスト自身の`valgrind`
パスが確実に失われたバイト0で通過することを含む。

コンパニオンファイルを書いている最中に表面化した、C言語レベルの
typedef衝突は記録する価値がある: rc2自身の生成されたCは、
`StructDefs`内の全ての構造体について既に`typedef struct { ... }
name;`を発行している(上記Part C)ので、コンパニオンヘッダが
*同じ*構造体形状を再び宣言すると(バイト単位で同一であっても)、
両方が同じ翻訳単位に`#include`された時点でtypedef重複エラーに
なる -- `Test24CStructSupport.h`は、自身の2つの関数を
`test_point*`型ではなく`void*`型で宣言することでこれを回避して
おり、本物の`test_point`のtypedefは`.c`ファイルにローカルなまま
保持されている。rc2のバグではない(このやり方で構造体名を確立する
どんなコンパニオンCファイルも同じことに突き当たる)が、これと似た
別のテストを書く前に知っておく価値がある。

## 調査したが見送り: ネイティブ(unboxed)な`Ptr`/`CFPtr`表現

実装が着地した後の直接の質問に促された調査: `getField`自身の結果も
`setField`自身の`value`オペランドも、一度も`Rep`の`RNative`へ昇格
されない(`Compiler.RC2.Types`自身の`repOf`は`ROp`/`RPrimVal`にしか
それを提案せず、`RStructGet`にはケースが無く`Nothing`へ素通しする)
-- そしてより具体的には、`structVar`自体(構造体ポインタ、Part A
以降は`CFPtr`形)も常にBoxedであり、1つの生のポインタを持ち運ぶ
だけのために1回の`IDRIS2RC2_Pointer`ヒープ確保のコストを支払って
いる(`packCFType CFPtr = idris2rc2_mkPointer(...)`)。`Ptr`/
`CFPtr`値一般(構造体ポインタだけでなく)が、固定幅スカラーが既に
そうしているように、rc2の既存のネイティブ表現機構を通せるかどうか
を調査した。

**意味論を検討する前に、構造的にブロックされている**: `Rep`自身の
`RNative`/`RInlineNative`は`RNative PrimType`という型を持ち、
`PrimType`(`idris2-src/src/Core/TT/Primitive.idr` -- 本家自身の
型であり、rc2のものではない)にはポインタのケースが一切存在しない
(`IntType`/.../`DoubleType`/`CharType`/`WorldType`、他には何も
無い)。`Compiler.RC2.Types`自身の`nativeEligible`は、それらの
サブセットしか受け入れない。ネイティブポインタをそもそも表現する
には、rc2自身の新しい`Rep`バリアントが必要になる。再利用できる
既存の`PrimType`値が存在しないためである -- `Rep`をパターン
マッチする全てのモジュール(`RC.idr`、`Types.idr`、`Emit.idr`、
`Loop.idr`、`DualABI.idr`)に触れる変更である。これに追い打ちを
かけるように: `RCExp`は、これのどれかが実行される時点までに、既に
Idris2自身の型情報を消去してしまっているので、「この特定のBoxed
ローカルは実際にはポインタである」と認識できるのは、依然として
`CFType`情報を直接運んでいる一握りのサイト(`RStructGet`自身の
フィールド型、`%foreign`呼び出し自身の戻り値型)だけであり -- 今日
`ROp`/`RPrimVal`駆動のネイティブ昇格がやっているような、一般的な
ローカル型推論ではない。

**それを脇に置いたとしても、意味論はscalarのように綺麗には成り立た
ない。** ネイティブポインタは「値でコピー、参照カウントなし」を
意味する必要がある -- 単純なアドレスとしては真だが、2つの本物の
問題が表面化する:

- **`CFGCPtr`が完全に壊れる。** `idris2rc2_mkGCPointer(raw,
  onCollect)`は、*Boxedラッパー*が回収された時に`onCollect`を実行
  する -- 外部クリーンアップを引き起こすための、参照カウントへの
  本物の依存である。あらゆるネイティブポインタ設計は`CFGCPtr`を
  明示的に除外し、それを永久にBoxedのみに保つ必要がある。候補に
  なりうるのは`CFPtr`(回収コールバックなし)だけである。
- **`CFPtr`自体も、単なる確保だけでなく安全網を失う。** 現在の
  `IDRIS2RC2_Pointer`ラッパーは、生のポインタが指すメモリを保護
  しない(それは既に完全にプログラマ自身の責任である --
  `Test24CStructSupport.idr`自身の明示的な`prim__freePoint`呼び出し
  参照)が、それはIRの中の*何か*が、そのポインタのある特定のコピー
  が依然として到達可能かどうかを追跡する(通常の`dup`/`drop`)ことを
  意味してもいる。ネイティブポインタは、いかなる追跡も無くコピー
  される -- rc2が既にポイント先メモリについて保証していること
  (何も無い)の後退ではないが、IR自体で見える/検査できるものの
  本物の縮小である。それ自体がポインタであるような構造体フィールド
  (将来のネストした構造体機能)は、これをさらに悪化させる --
  あるフィールドポインタ自身の生存期間を、それを所有する構造体の
  生存期間との相対で推論することは、まさに本物の借用/生存期間
  チェッカーが存在する理由そのものであり、rc2にはそれが無い。

**結論**: `CFPtr`に限れば意味論的には妥当(ポインタ値は、scalarと
同様に真に「コピー、参照カウントなし」である)だが、追求しなかった
-- `Rep`の拡張コストは広範であり、`CFGCPtr`は永久な除外が必要に
なり、`IDRIS2RC2_Pointer`が現在提供している弱い到達可能性追跡すら
失うことは、解決済みの問題ではなく本物の未解決の問いである。
プロファイリングで`IDRIS2RC2_Pointer`の確保コストが実際に問題に
なると判明した場合に限り、上記の`CFGCPtr`分割と生存期間の問いに
対する具体的な計画と共に見直す -- 現時点では計画していない。

## ファイル

- `rc2/tests/Test24CStructSupport.idr`/`.c`/`.h`/`.expected` --
  回帰テスト; `rc2/tests/verify.sh` -- このテストが必要とした
  コンパニオンCファイルのコンパイル・リンク機構(`if [ -f
  "$RC2_DIR/tests/$name.c" ]; then ...`)、加えてこのテスト向けの
  `NO_REFC_DIFF_TESTS`/`LEAK_SENSITIVE_TESTS`エントリ。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `Rep`自身の`RNative`/
  `RInlineNative PrimType`。「調査したが見送り: ネイティブ`Ptr`/
  `CFPtr`」節自身の出発点。`rc2/src/Compiler/RC2/Types.idr` --
  `nativeEligible`/`repOf`。`rc2/src/Compiler/RC2/Emit.idr` --
  `packCFType`/`extractValue`自身の`CFPtr`/`CFGCPtr`ケース
  (`idris2rc2_mkPointer`/`idris2rc2_mkGCPointer`)。
- `idris2-src/src/Core/TT/Primitive.idr` -- 本家自身の`PrimType`。
  `Rep`の`RNative`が再利用できるポインタケースが無いことの確認。
- 本家のissue: [#3830](https://github.com/idris-lang/Idris2/issues/3830)
  (まさにこの`extractValue`クラッシュ、まだ開いたまま、未修正)、
  [#2062](https://github.com/idris-lang/Idris2/issues/2062)(RefC
  向け`getField`サポートへの先行の試み、断念 -- 主要なコメントは
  上記「本家Idris2自身のissueトラッカーが述べていること」参照)、
  [#1916](https://github.com/idris-lang/Idris2/issues/1916)(値渡し
  の構造体、スコープ外)、[#36](https://github.com/idris-lang/Idris2/issues/36)
  (Chez固有のネストした構造体のバグ、scalarフィールドについては
  スコープ外)、[#3809](https://github.com/idris-lang/Idris2/issues/3809)
  (最近の、より広範なFFI提案、最初の実装のスコープ外)。
- `idris2-src/libs/base/System/FFI.idr` -- `Struct`/`FieldType`/
  `getField`/`setField`/`prim__getField`/`prim__setField`。
- `idris2-src/src/Compiler/Scheme/Chez.idr` -- `chezExtPrim`の
  `GetField`/`SetField`ケース、`mkStruct`、`Structs`、`cftySpec`の
  `CFStruct`ケース、`schFgnDef`(`mkStruct`が`%foreign`定義ごとに
  呼ばれる場所)。
- `idris2-src/src/Compiler/RefC/RefC.idr` -- `cStatementsFromANF`の
  `AExtPrim`ディスパッチ(RefC/rc2が共有する`prims`ホワイトリスト)、
  `cTypeOfCFType`/`extractValue`/`packCFType`自身の`CFStruct`ケース
  (rc2がコピーした同じ隙間)。
- `rc2/src/Compiler/RC2/Emit.idr` -- `emitRC`の`RExtPrim`ケース
  (`prims`ホワイトリスト)、`cTypeOfCFType`/`extractValue`/
  `packCFType`自身の`CFStruct`ケース(`extractValue`の
  `idris_crash`、`packCFType`の未定義の`makeStruct`呼び出し)、
  `generateCSourceFile`/`header` -- 提案された収集パス自身の住処、
  そして`RStructGet`/`RStructSet`向けの新規`emitRC`ケース(上記
  「設計」参照)。
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCForeign`。`%foreign`定義
  自身の`CFType`リストが現在たどり着く場所; `ROp`。その`postDrop`
  フィールドを`RStructGet`/`RStructSet`が(`ROp`自身の
  `splitBorrows`/`wrapDups`のdup挿入半分を伴わずに)再利用している;
  `freeLocalsR`/`countUsesR`/`usedConstructorsR`。新規ノードが
  ケースの追加を必要とする構造解析関数。
- `rc2/src/Compiler/RC2/RC.idr` -- `normalize`の`LExtPrim`/
  `MkLForeign`ケース(`RC.idr:163-164`/`244`、新規の
  `prim__getField`/`prim__setField`ケースが差し込まれる場所、そして
  本書の「構造体のフィールド型が実際にどう現れるか」節がトレース
  している、直接の`Lifted` -> `RCExp`の`MkLForeign`/`MkRCForeign`
  コピー)、`annotate`の`ROp`/`RExtPrim`ケース(`RC.idr:501-504`、
  `RStructGet`/`RStructSet`自身の`annotate`/`dropIfLastUse`が
  そこから分岐しているパターン -- `ROp`自身の`splitBorrows`/
  `wrapDups`は`dup`を挿入するが、`dropIfLastUse`は一切しない)、
  `branchBody`/`dropUnusedOwnedVars`(`RC.idr:397-409`、上記のパス2
  が`structVar`/`value`もそれだけでカバーしてくれると誤って仮定
  した、「`freeLocalsR`が未使用だと言うものをdropする」という
  トップレベル機構)、`annotateDef`/`definitionNatives`
  (`RC.idr:596-613`、パス2のバグを見つけるために`f s = getField s
  "x"`の再現コードに対して手作業で追跡した)。
- `idris2-src/src/Compiler/LambdaLift.idr` -- `LiftedDef`の
  `MkLForeign`、`Lifted`の`LExtPrim` -- 構造体フィールド型が、
  rc2自身の`RC.idr`が消費する`Lifted` IRへ生き残る場所(そして
  生き残らない場所)。
- `rc2/src/Compiler/RC2/Inline.idr` -- `buildEligible`/
  `applyInlineLifted`。構造体フィールドテーブルが従うことになる
  プログラム全体の収集してから走査するという形。
- `idris2-src/src/Idris/CommandLine.idr`、
  `idris2-src/src/Compiler/Common.idr` -- `--dumplifted`。上記の
  実例を生成するために使ったデバッグフラグ。
- `idris2-src/src/TTImp/ProcessData.idr` -- `calcNaty`。`FieldType`
  が引き起こす一般的な「Natのような型」構造検出(`Nat`固有の特別
  ケースではない); `idris2-src/src/Core/CompileExpr.idr` --
  この検出が割り当てる`ConInfo`の`ZERO`/`SUCC`タグ。
