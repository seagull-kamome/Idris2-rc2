# プログラム全体の CAF 畳み込みと `RConCase` の判別対象の解決

(原文: `doc/const-caf-fold.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.ConstFold` による `RCConstCon`/`RCConstClosure` の畳み込み
(`rc2/doc/const-con-fold.md`と`rc2/doc/const-closure-fold.md`を参照)は、
かつては1つの定義の本体の中だけで完結していた。定義ごとに新しい、純粋に
ローカルな `env` を使う1回きりのパスであり、`foldConstDef` を `RCDef` ごと
に1度呼ぶだけで、定義をまたぐ状態は持たなかった。このため、次の2つの隙間
が残っていた。

1つ目は、他のトップレベルの0引数定義(CAF)への `RAppName` 呼び出しであ
る。その CAF 自体が完全に定数へ畳み込まれていても、呼び出し側では定数と
して扱われなかった。2つ目は `RConCase`(コンストラクタのタグによる分岐)
である。通常のレコードのフィールド射影も、alt を1つだけ持つ `case` に脱糖
されてこれになる。`RConstCase`(リテラル/`Constant` による分岐)は、すで
に判別対象(scrutinee)を既知の定数と照らして解決していたが、`RConCase`
にはそれがなかった。

本書では、この2つの隙間を埋める仕組みを説明する。`TODO.md` にあった
「Performance: constant-constructor folding doesn't cross a CAF boundary or
a case scrutinee」の項目は、完全に解決したのでそこから削除した。あわせて、
全体を切り替える `noconstfold` ディレクティブ、`RConCase` の畳み込みを
`Compiler.RC2.RC` の所有権注釈へつなぎ込む際に見つけて直した実バグ1件、
そして新しい回帰テスト4件を扱う。

## 設計

### CAF 境界をまたぐ: プログラム全体の不動点計算

`ConstFold.idr` には、定義ごとの既存の `Env`(`RCLoc` 自身のローカル id を
キーとする `SortedMap Int (Subset RCLocal IsAnyConstLocal)`)に加えて、よ
り広い範囲を扱う2つ目のテーブルを追加した。

```idris2
public export
CafTable : Type
CafTable = SortedMap Name (Subset RCLocal IsAnyConstLocal)
```

(`ConstFold.idr:183-185`)。CAF の呼び出しは定義の境界をまたぐが、ローカル
id は境界の外では意味を持たない。そこで `CafTable` のキーは `Name` にした。
`foldConst` はすべての箇所で `Env` と並べて `CafTable` を受け取るようにな
り、その `RAppName` のケースは、`RLet` の値の分類がローカル変数を解決する
のと同じやり方で CAF 参照を解決する。

```idris2
foldConst caf env (RAppName fc lazy n args) =
    let args' = map (resolveLocal env) args
    in case args' of
            [] => case lookup n caf of
                       Just (Element cval _) => RV fc cval
                       Nothing               => RAppName fc lazy n []
            _  => RAppName fc lazy n args'
```

(`ConstFold.idr:312-318`)。`args' = []` がちょうど CAF の呼び出しにあたる
(0引数のトップレベル定義は、常に空の `args` で適用される)。`args'` が空
でなければ通常の呼び出しであり、ほかのノードと同様にオペランドだけを解決
して、あとは手を加えない。解決された CAF 参照は素の `RV fc cval` になる。
これは、`RCConstCon`/`RCConstClosure` の畳み込みがすでに持っていた
`RLet`/`RV` の分類のケース(`ConstFold.idr:237-258`)をそのまま通って
`env` に入る。置換後の処理のために別の仕組みを足す必要はなかった。

`CafTable` 自体の構築は、プログラム全体を対象とするパス
`Compiler.RC2.RC2.foldConstProgram` が行う。

```idris2
foldConstProgram : List (Name, RCDef) -> List (Name, RCDef)
foldConstProgram defs0 = go maxConstFoldIterations empty defs0
  where
    rebuildTable : List (Name, RCDef) -> CafTable
    rebuildTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    go : Nat -> CafTable -> List (Name, RCDef) -> List (Name, RCDef)
    go Z _ defs = defs
    go (S fuel) table defs =
        let folded = map (\(n, d) => (n, foldConstDef table d)) defs
            table' = rebuildTable folded
        in if length (SortedMap.toList table') == length (SortedMap.toList table)
              then folded
              else go fuel table' folded
```

(`RC2.idr:137-150`)。各ラウンドでは、すべてのトップレベル定義に
`foldConstDef` を適用する(形は従来どおりで、現在の `CafTable` を受け取る
ようになっただけである)。そのあと、`cafValueOf` が認識する形になった定義
からテーブルを作り直す。

```idris2
cafValueOf : RCDef -> Maybe (Subset RCLocal IsAnyConstLocal)
cafValueOf (MkRCFun [] _ _ (RV _ cval)) = (\prf => Element cval prf) <$> isConstLocalProof cval
cafValueOf _ = Nothing
```

(`ConstFold.idr:417-419`)。対象は、本体が素の `RV fc cval` まで畳み込ま
れた0引数の `MkRCFun` である。本体が素の `RPrimVal` の場合は、意図的にこ
こへ含めていない。それほど単純な CAF は、`ConstFold` が走るより前に
`Compiler.RC2.InlineCExp` 自身の `isCallFree (LPrimVal _ _) = True` によっ
て各呼び出し箇所へ展開済みであり、`cafValueOf` が見るころには残っていない
からである。この経路が必要なのは、`Inline` が手を出せない
`RCConstCon`/`RCConstClosure` の形(`isCallFree` 自身の `LCon`/`LUnderApp`
のケース。`const-con-fold.md`と`const-closure-fold.md`を参照)だけである。

ループは、ラウンド間で `CafTable` のキー数が増えなくなった時点か、
`maxConstFoldIterations = 4`(`RC2.idr:127-128`)のラウンドを終えた時点で
止まる。4という値は GHC の `-fmax-simplifier-iterations` の既定値に合わせ
たもので、考え方も同じである。上限を設けても正しさに影響しないのは、次の
2つの性質があるからである。1つは、定義が「定数と判明していない」状態から
「定数と判明した」状態へ移ることはあっても、逆戻りはしないこと、つまり処
理が単調であることである。もう1つは、平坦な定数に解決できない相互参照の
CAF 群(`a = More 1 b; b = More 2 a`)は、その群についてそれ以上進展しな
いまま、通常の動的に計算される定義として残ることである。したがって上限に
達しても、深く連鎖した一部の CAF が畳まれずに残る(最適化の取りこぼし)だ
けで、誤った畳み込みが起きることはない。

`Compiler.RC2.RC2.toRCDefs` は、フェーズ1の正規化とフェーズ2の注釈付けの
あいだに、この処理全体を組み込む。

```idris2
preFolded <- ... traverse (\(n, ld) => do d <- toRCDefPreFold n ld; pure (n, d)) lds
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
reused <- ... traverse (\(n, d) => do d1 <- toRCDefPostFold d; ...) folded
```

(`RC2.idr:152-165`)。`toRCDefPreFold`/`toRCDefPostFold` は `RC.idr` に以
前からあるフェーズ1/フェーズ2の分割であり、今回の変更では手を入れていな
い。不動点ループはこの2つのあいだに完全に収まる。従来の1回きりの
`foldConstDef` 呼び出しと同じく、フェーズ1で正規化済み・注釈付け前の IR
だけを見る。

### `RConCase` の判別対象の解決

`RConstCase` の `foldConst` のケースは、すでに判別対象を解決していた。

```idris2
foldConst caf env (RConstCase fc sc alts mDef) =
    let alts' = map (foldConstConstAlt caf env) alts
        mDef' = map (foldConst caf env) mDef
    in case resolveConst env sc of
            Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
            Nothing => RConstCase fc sc alts' mDef'
```

(`ConstFold.idr:375-380`)。`RConCase` にも同じ構造が必要だが、alt の選び方
は `Constant` の等価比較ではなく、コンストラクタのタグによる。また、
`RConstCase` の alt は何も束縛しないのに対し、`RConCase` では、選ばれた
alt がフィールドに束縛するローカル id を、解決済みの `RCConstCon` の
`args` にすでに入っている対応する部分値で置き換える必要がある。これを2つ
の小さな補助関数が担う。

```idris2
findConAlt : Maybe Int -> List RConAlt -> Maybe RConAlt
findConAlt tag [] = Nothing
findConAlt tag (alt@(MkRConAlt _ _ tag' _ _) :: rest) =
    if tag == tag' then Just alt else findConAlt tag rest

insertConArgs : List Int -> List RCLocal -> Env -> Env
insertConArgs (i :: is) (v :: vs) env =
    case isConstLocalProof v of
         Just prf => insertConArgs is vs (insert i (Element v prf) env)
         Nothing  => insertConArgs is vs env
insertConArgs _ _ env = env
```

(`ConstFold.idr:187-197`)。そして `foldConst` の `RConCase` のケースは次
のとおりである。

```idris2
foldConst caf env (RConCase fc sc alts mDef) =
    case resolveLocal env sc of
         RCConstCon _ _ tag args =>
             case findConAlt tag alts of
                  Just (MkRConAlt _ _ _ argIds body) =>
                      foldConst caf (insertConArgs argIds args env) body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         RCEmptyCon _ _ tag =>
             case findConAlt (Just tag) alts of
                  Just (MkRConAlt _ _ _ _ body) => foldConst caf env body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         _ => RConCase fc sc (map (foldConstAlt caf env) alts) (map (foldConst caf env) mDef)
```

(`ConstFold.idr:359-374`)。`insertConArgs` が各フィールドに
`isConstLocalProof` を呼ぶのは、`env` がフィールドを記録するのに必要な
`IsAnyConstLocal` の証明を得るためであり、実際に失敗することはない。`RCon` 自身の畳み
込み(`ConstFold.idr:288-294`)が `RCConstCon` を作るのは、全フィールドが
すでに `IsAnyConstLocal` を満たすときだけだからである。そのため、ここで置
換するフィールドにはすべて証明があり、本当に畳み込まれたローカル
と同じように `env` で追跡される。`Nothing` の枝は全域性のために置いてある
のであって、`RCConstCon` 自身の `args` で実行されることは想定していない。
`RCEmptyCon`(NIL/NOTHING/ZERO/UNIT)は、構造上フィールドを持たないので、
フィールドの置換がまったく要らない。この枝はタグで一致する alt を選び、そ
の本体へ直接再帰するだけである。

`RCrash "...matched no alt and had no default"` の枝は、全域性を閉じるた
めの防御用であり、このパスが実際に到達することは想定していない。上流
Idris2 自身の網羅性検査により、型付けの正しい `case` は、判別対象の型のす
べてのコンストラクタを(直接か、デフォルトを通じて)必ず覆うからである。
したがって、解決済みの `RCConstCon`/`RCEmptyCon` のタグが `alts` のどれに
も一致せず、`mDef` もない場合は、*ソース*プログラム自身の case の網羅性が
すでに不健全だったことを意味する。`ConstFold` が引き起こせる事態ではない。

`RConCase` と `RConstCase` は `foldConst` の同じ相互再帰ブロックに属して
いる。そのため、判別対象が定数であることが、後から処理される CAF によっ
て(`RAppName` の畳み込みのケースを通じて)初めて確定する場合も、外側の不
動点ループの恩恵を自動的に受ける。こちらの半分についても、再試行を起動す
る別の仕組みは要らなかった。

## 見つかったバグ

### `RC.idr` の `annotate` に、5つの定数形式のうち3つの横取りが欠けていた

`RC.idr` のフェーズ2の所有権注釈 `annotate` は、`RCLocal` の5つの定数形式
のうち2つを、すでに「不滅で、dup が不要で、所有・借用のどちらとしても追跡
しない」ものとして特別扱いしていた。

```idris2
annotate natives owned e@(RV _ (RCConstCon {})) = pure e
annotate natives owned e@(RV _ (RCConstClosure {})) = pure e
```

(`RC.idr:474,478`。今回の変更より前からある)。残る3つの形式(`RCConst`、
`RCEmptyCon`、`RCNull`)には、`annotate` 自体に同等の横取りがなかった。こ
れは今回の変更までは無害だった。この3つが `annotate` に届くのは、`RLet`
に包まれた状態(別の経路で処理される)か、通常の変数参照としてだけであり、
これらの形式の素の `RV` が、外側に束縛を持たないままむき出しで届くことは
なかったからである。

`insertConArgs` はこの前提を崩す。`RConCase` の alt がフィールドに束縛す
るローカル id を、解決済みの(たとえば)`RCConst`/`RCEmptyCon`/`RCNull` の
部分値で直接置換し、そのまま alt の本体へ畳み込むと、上に何もない状態で初
めて `annotate` に届く素の `RV` ができうる。

修正前は、`annotate` の汎用のフォールバックが働いた。

```idris2
annotate natives owned (RV fc v) =
    pure $ if contains v natives || contains v owned then RV fc v else RDup fc v (RV fc v)
```

`natives` にも `owned` にも定数形式の値が追跡されることはないため、このフ
ォールバックは値を本物の `RDup fc v ...` で包む。`Compiler.RC2.Emit.Util`
の `varName` には、5つの定数形式のどれについても、この形で `RDup` に届い
た場合の出力規則がない(従来は到達不能だったので、設計どおりである)。そ
の結果、誤った答えや気づかないままのリークではなく、本物の C コンパイル
エラーとして表面化した。

```c
idris2rc2_dup(/* [rc2] unreachable RCConst varName */)
```

引数が足りない呼び出しである。`RDup` の出力が期待する実際の変数名の代わ
りに、プレースホルダのコメントが入っているためである。

**修正**: `RCConstCon`/`RCConstClosure` にすでにある横取りと同じものを、3
つ追加した。

```idris2
annotate natives owned e@(RV _ (RCConst _)) = pure e
annotate natives owned e@(RV _ (RCEmptyCon {})) = pure e
annotate natives owned e@(RV _ RCNull) = pure e
```

(`RC.idr:495-497`)。これで `annotate` は、`splitBorrows`、
`dropIfLastUse`、`boxedOperands` の `isBoxedOperand`(`RC.idr:389-393`、
`420-424`、`448-452`)と揃った。これらは最初から5つの定数形式をすべて一様
に除外していた。5つのうち2つしか特別扱いしていなかったのは `annotate` だ
けであり、それは、`RConCase` の畳み込みができるまで、素のまま `annotate`
に届きうるのがその2つだけだったからである。

**検証の方法**: `RConCase` の畳み込みを作っている途中で、それを使う再現プ
ログラムをコンパイルし、出てきた C のコンパイルエラーを直接読んで見つけ
た。この失敗は、気づかないうちに誤コンパイルされたりリークしたりするので
はなく、ハードなコンパイルエラーになる。そのため valgrind や出力の差分に
頼らず、すぐに表面化した。3つの横取りを追加して再ビルドし、同じ再現プロ
グラムと `rc2/tests/verify.sh` の回帰スイート全体を再実行して、修正を確認
した。

## `noconstfold` ディレクティブ

`--directive noconstfold` / `%cg rc2 noconstfold` は、`foldConstProgram`
の不動点パス全体を無効にする。CAF 境界をまたぐ畳み込みと `RConCase` の判
別対象の解決は、同じ `foldConst` の走査の中にあるため、これより細かい切り
替えはない。命名は、`noinline`/`noconaltnative`/`nomutualloop`/`noloop`/
`nosink`/`nodualabi`/`nodeadcode` とまったく同じ `no<ステージ名>` の形式
に従う(`RC2.idr:68-107` のモジュールドキュメントコメントに、これらがまと
めて載っている)。定数の `ExtPrim` の畳み込み(`prim__codegen`、
`foldConst` の `constExtPrimValue`。以前は `toRCDefPreFold` の中にある独
立した `Compiler.RC2.ConstExtPrim` パスだった)も、いまは同じ走査の中にあ
る。そのため `noconstfold` で無効になる。

```idris2
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
```

(`RC2.idr:157-159`)。このリストにあるほかのステージと同じく、これを飛ば
しても C は正しく生成される(最適化の程度が下がるだけである)。後続のどの
パスも、CAF や case の判別対象が畳み込み済みであることを必要としない。

## テスト

回帰テストは4件あり、現在は
`rc2/tests/Test115ConstFoldClosure/ConstFoldClosure.idr` の§5〜§8にまとめ
られている。このファイル全体が `rc2/tests/verify.sh` の
`LEAK_SENSITIVE_TESTS` に登録されている。ただし§7(相互参照する CAF のケ
ース)は、畳み込みが起きないことそのものが目的なので、単独でリークを調べ
る対象がない。

- **§5(旧 `Test74ConstFoldCafBoundaryClosure`)**: クロージャの形をした
  CAF(`dict74 : Pair74; dict74 = MkPair74 d74op1 d74op2`)を、`main` の中
  に直接構築せず、*別の*定義(`useDict74`)からだけ参照する。これによって、
  新しいプログラム全体の `CafTable` を、`Compiler.RC2.InlineCExp` がコン
  ストラクタに限って行う展開(副次的な経路であり、コンストラクタの形の
  CAF が、その CAF の呼び出し箇所で組み立てられる場合にしか届かない。
  `const-con-fold.md` の CAF 境界についての議論を参照)から意図的に切り離
  している。これが畳み込まれたなら、`Inline` ではなく新しい不動点ループ
  の働きだという証拠になる。`--directive dumprcexpr` で手作業で確認し
  た。`Main.useDict74` のダンプは `Main.dict74` を
  `RCConstCon`/`RCConstClosure` のリテラルとして直接参照しており、
  `RAppName ... "Main.dict74" []` の呼び出しは残っていない。
- **§6(旧 `Test75ConstFoldConCaseScrutinee`)**: `directCase` の判別対象
  は、`case` の直前の `let` で束縛された、既知の定数 `RCConstCon` である。
  このため、タグによる分岐を含む `case` 全体が、単一の `RPrimVal` へ畳み
  込まれて消えなければならない。一方、`areaOf` の2つの呼び出しでは、判別
  対象を本物の動的な値(通常の関数引数)のままにしてある。パスに不可欠な
  フォールバック(再帰的に畳み込んだ alt 以外は変わらない `RConCase`)を
  試すためである。このテストが valgrind でもクリーンに通ることは、
  `Compiler.RC2.Reuse` の予約ロジックと `Emit.idr` の case の低水準化
  が、実際には分解されない判別対象を正しく扱うことの非公式な確認も兼ねる
  (後述の「スコープと制限」を参照)。
- **§7(旧 `Test76ConstFoldMutualCafSafety`)**: 畳み込みのテストではな
  く、安全網である。`chainA = More 1 chainB; chainB = More 2 chainA` は
  互いを参照する2つの CAF であり、不動点のラウンドを何回回しても、どちら
  の `cafValueOf` も安定しない。確認するのは、`maxConstFoldIterations` が
  ループを抑え、コンパイラがハングやクラッシュを起こさず、プログラムが通
  常どおりコンパイルされて動くことだけである(2つの CAF はどちらも、畳ま
  れない通常の `RAppName` 呼び出しのまま残る)。`sumFirst 3 chainA` は条
  件(`length args > 100`)で守られており、コマンドライン引数がなければ常
  に偽なので、実際には評価されない。この呼び出しは、`chainA`/`chainB` に
  静的に到達可能な生きた使用箇所を与えるためだけに存在する。これがない
  と、`ConstFold` がそれらをループにかける機会を得る前に、
  `Compiler.RC2.DeadCode` に刈り取られてしまう。
- **§8(旧 `Test77ConstFoldCafChainCap`)**: `maxConstFoldIterations` 自
  体についての、off-by-one の回帰テストである。2フィールドのレコードを包
  む、3段の CAF エイリアスの連鎖を使う(`capC = capB; capB = capA; capA =
  MkBox d77op1 0`)。フィールドを2つにしたのは、レコードが透過的な単一フ
  ィールドの newtype として最適化で消えると、このテストが試したい CAF の
  連鎖を迂回してしまうからである。各段が解決できるのは、連鎖を1つ下った
  CAF が*前の*ラウンドで `CafTable` に登録された後に限られる。そのため連
  鎖全体を解決するには、1ラウンドではなく複数のラウンドが要る。手作業で
  確認した。上限が4のとき、`Main.capA`/`capB`/`capC` は
  `--directive dumprcexpr` の出力から完全に消える(名前で呼ぶものがなく
  なった時点で `Compiler.RC2.DeadCode` が刈り取る)。`main` には、畳み込
  み済みの単一の `RCConstClosure` を直接適用する形だけが残る。

## スコープと制限

- **4ラウンドの上限は残る。** 5ラウンド目(以降)が必要になるほど深い
  CAF の連鎖は、一部が畳まれずに残る。上で述べた単調性の議論により、こ
  れは最適化の取りこぼしであり、正しさの問題にはならない。
  `Test115ConstFoldClosure/ConstFoldClosure.idr` の§8は、現実的な短い連
  鎖に対して上限が十分に高いことを確認するが、上限に実際に達する場合は試
  していない。
- **`Compiler.RC2.Reuse`/`Emit.idr` の監査**: `const-con-fold.md` の「ス
  コープ / 制限」節は、`case` の判別対象が完全に畳み込まれて消えた場合に
  ついて、`Compiler.RC2.Reuse` の予約ロジックと `Emit.idr` の case の低
  水準化を監査し、dup/drop の帳簿が正しいか確かめる必要があると指摘して
  いた。この2つは、判別対象が実行時に分解される本物のヒープ上の `RCLoc`
  であると仮定しているからである。実際には、これは問題にならない。
  `RConCase`/`RConstCase` が判別対象を畳み込むと、判別対象を含む case ノ
  ード全体が、選ばれた alt の本体に置き換わる。これは
  `Compiler.RC2.RC` の注釈パスや `Compiler.RC2.Reuse` が走るより前に起き
  る(`toRCDefs` では `ConstFold` が最初に走る。`RC2.idr:152-165`)。後続
  のパスが見るべき `RConCase` ノードは残っておらず、誤って処理する対象も
  ない。`Test115ConstFoldClosure/ConstFoldClosure.idr` の§6が
  `LEAK_SENSITIVE_TESTS` の valgrind で問題なく通ることが、その経験的な
  確認である。形式的な証明ではない。現時点で未解決の懸念はない。
- `foldConst` の `RConCase` のケースにある
  `RCrash "...matched no alt and had no default"` の枝は、上流の case 網
  羅性検査があるため到達不能と考えられる(上記「設計」を参照)。全域性の
  ために残してあり、これらの枝を通る再現プログラムが存在することは想定し
  ていない。

## ファイル

- `rc2/src/Compiler/RC2/ConstFold.idr`: `CafTable`、
  `findConAlt`/`insertConArgs`、`RAppName`/`RConCase` の畳み込みのケース、
  `cafValueOf`。
- `rc2/src/Compiler/RC2/RC2.idr`: `maxConstFoldIterations`、
  `foldConstProgram`、`toRCDefs` の中の `noconstfold` ディレクティブの組
  み込みと、そのモジュールドキュメントコメント。
- `rc2/src/Compiler/RC2/RC.idr`: `annotate` に追加した3つの横取り
  (`RCConst`/`RCEmptyCon`/`RCNull`)。
- `rc2/tests/verify.sh`: 統合後の
  `Test115ConstFoldClosure/ConstFoldClosure.idr` が `LEAK_SENSITIVE_TESTS`
  に入っている(§7 にはリークを調べる対象がないが、ファイルのそれ以外の
  部分にはある)。
- `rc2/tests/Test115ConstFoldClosure/ConstFoldClosure.idr` の§5〜§8: 上
  に説明した4件の回帰テスト(元は独立した `Test74`〜`Test77`)。

## 検証方法

1. 新しい各テストに対し、変更の前後で `--directive dumprcexpr`
   (`rc2/doc/reading-the-ir.md` を参照)を実行する。何が畳み込まれたか
   を、プログラムの出力から間接的に推測するのではなく、正確に確認するた
   めである(`RAppName` の呼び出しが `RCConstCon`/`RCConstClosure` のリテ
   ラルに置き換わったこと、`case` が唯一残った alt の本体へつぶれたこ
   と)。
2. 生成された C を直接読み、残っているべきでないものが*ない*ことを確認す
   る。畳み込まれた CAF 自身の C 関数への呼び出しが残っていないこと、畳
   み込まれた辞書に対する `idris2rc2_mkClosure` やコンストラクタ確保の呼
   び出しがないこと、判別対象がコンパイル時に解決された `RConCase` に対し
   て、実行時のタグ分岐の `switch`/`if` がないこと。
3. valgrind 付きで `rc2/tests/verify.sh` を全件実行した。結果は、成功
   101、既知の失敗 0、失敗 0 で、`LEAK_SENSITIVE_TESTS` の全エントリで
   definitely lost は 0 バイトだった。とくに
   `Test115ConstFoldClosure/ConstFoldClosure.idr` の§6は、解決されて捨て
   られた `RConCase` の判別対象が dup/drop の帳簿に誤りを持ち込まないこ
   とを、valgrind で直接確認したものである(上記「スコープと制限」を参
   照)。
4. `Test115ConstFoldClosure/ConstFoldClosure.idr` の§7(相互参照する
   CAF)は、それ自体が不動点ループの停止保証の検証手段になっている。上限
   か変更検出のロジックの実装が誤っていれば、この入力でコンパイラは誤っ
   た答えを出すのではなく完全にハングする。したがって、コンパイルが無事
   に終わること自体が検査である。
5. CAF 境界や `RConCase` の畳み込みの対象とするノードの形を広げる場合、
   新しいリークは、`const-con-fold.md` のバグ#2を見つけたときと同じ方法
   で二分探索する(変更前のビルドに対して `git stash` し、同一の再現プロ
   グラムを valgrind で再実行する)。本書の `annotate` の横取り漏れのバグ
   は、リークではなくハードなコンパイルエラーだった。しかし、この領域で
   将来見つかる隙間がすべて、これほどはっきり失敗してくれる保証はない。
