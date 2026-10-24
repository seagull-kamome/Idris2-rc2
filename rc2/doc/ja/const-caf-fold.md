# プログラム全体のCAF畳み込みと`RConCase`の判別対象の解決

(原文: `doc/const-caf-fold.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.ConstFold`による`RCConstCon`/`RCConstClosure`の畳み込み(`rc2/doc/const-con-fold.md`と`rc2/doc/const-closure-fold.md`を参照)は、かつては1つの定義の本体の中だけで完結していた。定義ごとに新しい、純粋にローカルな`env`を使う1回きりのパスであり、`foldConstDef`を`RCDef`ごとに1度呼ぶだけで、定義をまたぐ状態は持たなかった。このため、次の2つの隙間が残っていた。

1つ目は、他のトップレベルの0引数定義(CAF)への`RAppName`呼び出しである。そのCAF自体が完全に定数へ畳み込まれていても、呼び出し側では定数として扱われなかった。2つ目は`RConCase`(コンストラクタのタグによる分岐)である。通常のレコードのフィールド射影も、altを1つだけ持つ`case`に脱糖されてこれになる。`RConstCase`(リテラル/`Constant`による分岐)は、すでに判別対象(scrutinee)を既知の定数と照らして解決していたが、`RConCase`にはそれがなかった。

本書では、この2つの隙間を埋める仕組みを説明する。`TODO.md`にあった「Performance: constant-constructor folding doesn't cross a CAF boundary or a case scrutinee」の項目は、完全に解決したのでそこから削除した。あわせて、全体を切り替える`noconstfold`ディレクティブ、`RConCase`の畳み込みを`Compiler.RC2.RC`の所有権注釈へつなぎ込む際に見つけて直した実バグ1件、そして新しい回帰テスト4件を扱う。

## 設計

### CAF境界をまたぐ: プログラム全体の不動点計算

`ConstFold.idr`には、定義ごとの既存の`Env`(`RCLoc`自身のローカルidをキーとする`SortedMap Int (Subset RCLocal IsAnyConstLocal)`)に加えて、より広い範囲を扱う2つ目のテーブルを追加した。

```idris2
public export
CafTable : Type
CafTable = SortedMap Name (Subset RCLocal IsAnyConstLocal)
```

(`ConstFold.idr:183-185`)。CAFの呼び出しは定義の境界をまたぐが、ローカルidは境界の外では意味を持たない。そこで`CafTable`のキーは`Name`にした。`foldConst`はすべての箇所で`Env`と並べて`CafTable`を受け取るようになり、その`RAppName`のケースは、`RLet`の値の分類がローカル変数を解決するのと同じやり方でCAF参照を解決する。

```idris2
foldConst caf env (RAppName fc lazy n args) =
    let args' = map (resolveLocal env) args
    in case args' of
            [] => case lookup n caf of
                       Just (Element cval _) => RV fc cval
                       Nothing               => RAppName fc lazy n []
            _  => RAppName fc lazy n args'
```

(`ConstFold.idr:312-318`)。`args' = []`がちょうどCAFの呼び出しにあたる(0引数のトップレベル定義は、常に空の`args`で適用される)。`args'`が空でなければ通常の呼び出しであり、ほかのノードと同様にオペランドだけを解決して、あとは手を加えない。解決されたCAF参照は素の`RV fc cval`になる。これは、`RCConstCon`/`RCConstClosure`の畳み込みがすでに持っていた`RLet`/`RV`の分類のケース(`ConstFold.idr:237-258`)をそのまま通って`env`に入る。置換後の処理のために別の仕組みを足す必要はなかった。

`CafTable`自体の構築は、プログラム全体を対象とするパス`Compiler.RC2.RC2.foldConstProgram`が行う。

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

(`RC2.idr:137-150`)。各ラウンドでは、すべてのトップレベル定義に`foldConstDef`を適用する(形は従来どおりで、現在の`CafTable`を受け取るようになっただけである)。そのあと、`cafValueOf`が認識する形になった定義からテーブルを作り直す。

```idris2
cafValueOf : RCDef -> Maybe (Subset RCLocal IsAnyConstLocal)
cafValueOf (MkRCFun [] _ _ (RV _ cval)) = (\prf => Element cval prf) <$> isConstLocalProof cval
cafValueOf _ = Nothing
```

(`ConstFold.idr:417-419`)。対象は、本体が素の`RV fc cval`まで畳み込まれた0引数の`MkRCFun`である。本体が素の`RPrimVal`の場合は、意図的にここへ含めていない。それほど単純なCAFは、`ConstFold`が走るより前に`Compiler.RC2.InlineCExp`自身の`isCallFree (LPrimVal _ _) = True`によって各呼び出し箇所へ展開済みであり、`cafValueOf`が見るころには残っていないからである。この経路が必要なのは、`Inline`が手を出せない`RCConstCon`/`RCConstClosure`の形(`isCallFree`自身の`LCon`/`LUnderApp`のケース。`const-con-fold.md`と`const-closure-fold.md`を参照)だけである。

ループは、ラウンド間で`CafTable`のキー数が増えなくなった時点か、`maxConstFoldIterations = 4`(`RC2.idr:127-128`)のラウンドを終えた時点で止まる。4という値はGHCの`-fmax-simplifier-iterations`の既定値に合わせたもので、考え方も同じである。上限を設けても正しさに影響しないのは、次の2つの性質があるからである。1つは、定義が「定数と判明していない」状態から「定数と判明した」状態へ移ることはあっても、逆戻りはしないこと、つまり処理が単調であることである。もう1つは、平坦な定数に解決できない相互参照のCAF群(`a = More 1 b; b = More 2 a`)は、その群についてそれ以上進展しないまま、通常の動的に計算される定義として残ることである。したがって上限に達しても、深く連鎖した一部のCAFが畳まれずに残る(最適化の取りこぼし)だけで、誤った畳み込みが起きることはない。

`Compiler.RC2.RC2.toRCDefs`は、フェーズ1の正規化とフェーズ2の注釈付けのあいだに、この処理全体を組み込む。

```idris2
(preFolded, infos) <- normalizeProgram incremental main defs   -- in lowerProgram
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
reused <- ... traverse (\(n, d) => do d1 <- toRCDefPostFold d; ...) folded
```

`normalizeProgram`と`toRCDefPostFold`は`RC.idr`のフェーズ1/フェーズ2の分割である(前者を`lowerProgram`が、残りを`toRCDefs`が呼ぶ)。不動点ループはこの2つのあいだに完全に収まる。従来の1回きりの`foldConstDef`呼び出しと同じく、フェーズ1で正規化済み・注釈付け前のIRだけを見る。

### `RConCase`の判別対象の解決

`RConstCase`の`foldConst`のケースは、すでに判別対象を解決していた。

```idris2
foldConst caf env (RConstCase fc sc alts mDef) =
    let alts' = map (foldConstConstAlt caf env) alts
        mDef' = map (foldConst caf env) mDef
    in case resolveConst env sc of
            Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
            Nothing => RConstCase fc sc alts' mDef'
```

(`ConstFold.idr:375-380`)。`RConCase`にも同じ構造が必要だが、altの選び方は`Constant`の等価比較ではなく、コンストラクタのタグによる。また、`RConstCase`のaltは何も束縛しないのに対し、`RConCase`では、選ばれたaltがフィールドに束縛するローカルidを、解決済みの`RCConstCon`の`args`にすでに入っている対応する部分値で置き換える必要がある。これを2つの小さな補助関数が担う。

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

(`ConstFold.idr:187-197`)。そして`foldConst`の`RConCase`のケースは次のとおりである。

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

(`ConstFold.idr:359-374`)。`insertConArgs`が各フィールドに`isConstLocalProof`を呼ぶのは、`env`がフィールドを記録するのに必要な`IsAnyConstLocal`の証明を得るためであり、実際に失敗することはない。`RCon`自身の畳み込み(`ConstFold.idr:288-294`)が`RCConstCon`を作るのは、全フィールドがすでに`IsAnyConstLocal`を満たすときだけだからである。そのため、ここで置換するフィールドにはすべて証明があり、本当に畳み込まれたローカルと同じように`env`で追跡される。`Nothing`の枝は全域性のために置いてあるのであって、`RCConstCon`自身の`args`で実行されることは想定していない。`RCEmptyCon`(NIL/NOTHING/ZERO/UNIT)は、構造上フィールドを持たないので、フィールドの置換がまったく要らない。この枝はタグで一致するaltを選び、その本体へ直接再帰するだけである。

`RCrash "...matched no alt and had no default"`の枝は、全域性を閉じるための防御用であり、このパスが実際に到達することは想定していない。上流Idris2自身の網羅性検査により、型付けの正しい`case`は、判別対象の型のすべてのコンストラクタを(直接か、デフォルトを通じて)必ず覆うからである。したがって、解決済みの`RCConstCon`/`RCEmptyCon`のタグが`alts`のどれにも一致せず、`mDef`もない場合は、*ソース*プログラム自身のcaseの網羅性がすでに不健全だったことを意味する。`ConstFold`が引き起こせる事態ではない。

`RConCase`と`RConstCase`は`foldConst`の同じ相互再帰ブロックに属している。そのため、判別対象が定数であることが、後から処理されるCAFによって(`RAppName`の畳み込みのケースを通じて)初めて確定する場合も、外側の不動点ループの恩恵を自動的に受ける。こちらの半分についても、再試行を起動する別の仕組みは要らなかった。

## 見つかったバグ

### `RC.idr`の`annotate`に、5つの定数形式のうち3つの横取りが欠けていた

`RC.idr`のフェーズ2の所有権注釈`annotate`は、`RCLocal`の5つの定数形式のうち2つを、すでに「不死で、dupが不要で、所有・借用のどちらとしても追跡しない」ものとして特別扱いしていた。

```idris2
annotate natives owned e@(RV _ (RCConstCon {})) = pure e
annotate natives owned e@(RV _ (RCConstClosure {})) = pure e
```

(`RC.idr:474,478`。今回の変更より前からある)。残る3つの形式(`RCConst`、`RCEmptyCon`、`RCNull`)には、`annotate`自体に同等の横取りがなかった。これは今回の変更までは無害だった。この3つが`annotate`に届くのは、`RLet`に包まれた状態(別の経路で処理される)か、通常の変数参照としてだけであり、これらの形式の素の`RV`が、外側に束縛を持たないままむき出しで届くことはなかったからである。

`insertConArgs`はこの前提を崩す。`RConCase`のaltがフィールドに束縛するローカルidを、解決済みの(たとえば)`RCConst`/`RCEmptyCon`/`RCNull`の部分値で直接置換し、そのままaltの本体へ畳み込むと、上に何もない状態で初めて`annotate`に届く素の`RV`ができうる。

修正前は、`annotate`の汎用のフォールバックが働いた。

```idris2
annotate natives owned (RV fc v) =
    pure $ if contains v natives || contains v owned then RV fc v else RDup fc v (RV fc v)
```

`natives`にも`owned`にも定数形式の値が追跡されることはないため、このフォールバックは値を本物の`RDup fc v ...`で包む。`Compiler.RC2.Emit.Util`の`varName`には、5つの定数形式のどれについても、この形で`RDup`に届いた場合の出力規則がない(従来は到達不能だったので、設計どおりである)。その結果、誤った答えや気づかないままのリークではなく、本物のCコンパイルエラーとして表面化した。

```c
idris2rc2_dup(/* [rc2] unreachable RCConst varName */)
```

引数が足りない呼び出しである。`RDup`の出力が期待する実際の変数名の代わりに、プレースホルダのコメントが入っているためである。

**修正**: `RCConstCon`/`RCConstClosure`にすでにある横取りと同じものを、3つ追加した。

```idris2
annotate natives owned e@(RV _ (RCConst _)) = pure e
annotate natives owned e@(RV _ (RCEmptyCon {})) = pure e
annotate natives owned e@(RV _ RCNull) = pure e
```

(`RC.idr:495-497`)。これで`annotate`は、`splitBorrows`、`dropIfLastUse`、`boxedOperands`の`isBoxedOperand`(`RC.idr:389-393`、`420-424`、`448-452`)と揃った。これらは最初から5つの定数形式をすべて一様に除外していた。5つのうち2つしか特別扱いしていなかったのは`annotate`だけであり、それは、`RConCase`の畳み込みができるまで、素のまま`annotate`に届きうるのがその2つだけだったからである。

**検証の方法**: `RConCase`の畳み込みを作っている途中で、それを使う再現プログラムをコンパイルし、出てきたCのコンパイルエラーを直接読んで見つけた。この失敗は、気づかないうちに誤コンパイルされたりリークしたりするのではなく、ハードなコンパイルエラーになる。そのためvalgrindや出力の差分に頼らず、すぐに表面化した。3つの横取りを追加して再ビルドし、同じ再現プログラムと`rc2/tests/verify.sh`の回帰スイート全体を再実行して、修正を確認した。

## `noconstfold`ディレクティブ

`--directive noconstfold` / `%cg rc2 noconstfold`は、`foldConstProgram`の不動点パス全体を無効にする。CAF境界をまたぐ畳み込みと`RConCase`の判別対象の解決は、同じ`foldConst`の走査の中にあるため、これより細かい切り替えはない。命名は、`noinline`/`noconaltnative`/`nomutualloop`/`noloop`/ `nosink`/`nodualabi`/`nodeadcode`とまったく同じ`no<ステージ名>`の形式に従う(`RC2.idr:68-107`のモジュールドキュメントコメントに、これらがまとめて載っている)。定数の`ExtPrim`の畳み込み(`prim__codegen`、`foldConst`の`constExtPrimValue`。以前はフェーズ1の中にある独立した`Compiler.RC2.ConstExtPrim`パスだった)も、いまは同じ走査の中にある。そのため`noconstfold`で無効になる。

```idris2
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
```

(`RC2.idr:157-159`)。このリストにあるほかのステージと同じく、これを飛ばしてもCは正しく生成される(最適化の程度が下がるだけである)。後続のどのパスも、CAFやcaseの判別対象が畳み込み済みであることを必要としない。

## テスト

回帰テストは4件あり、現在は`rc2/tests/Test115ConstFoldClosure/ConstFoldClosure.idr`の§5〜§8にまとめられている。このファイル全体が`rc2/tests/verify.sh`の`LEAK_SENSITIVE_TESTS`に登録されている。ただし§7(相互参照するCAFのケース)は、畳み込みが起きないことそのものが目的なので、単独でリークを調べる対象がない。

- **§5(旧`Test74ConstFoldCafBoundaryClosure`)**: クロージャの形をしたCAF(`dict74 : Pair74; dict74 = MkPair74 d74op1 d74op2`)を、`main`の中に直接構築せず、*別の*定義(`useDict74`)からだけ参照する。これによって、新しいプログラム全体の`CafTable`を、`Compiler.RC2.InlineCExp`がコンストラクタに限って行う展開(副次的な経路であり、コンストラクタの形のCAFが、そのCAFの呼び出し箇所で組み立てられる場合にしか届かない。`const-con-fold.md`のCAF境界についての議論を参照)から意図的に切り離している。これが畳み込まれたなら、`Inline`ではなく新しい不動点ループの働きだという証拠になる。`--directive dumprcexpr`で手作業で確認した。`Main.useDict74`のダンプは`Main.dict74`を`RCConstCon`/`RCConstClosure`のリテラルとして直接参照しており、`RAppName ... "Main.dict74" []`の呼び出しは残っていない。
- **§6(旧`Test75ConstFoldConCaseScrutinee`)**: `directCase`の判別対象は、`case`の直前の`let`で束縛された、既知の定数`RCConstCon`である。このため、タグによる分岐を含む`case`全体が、単一の`RPrimVal`へ畳み込まれて消えなければならない。一方、`areaOf`の2つの呼び出しでは、判別対象を本物の動的な値(通常の関数引数)のままにしてある。パスに不可欠なフォールバック(再帰的に畳み込んだalt以外は変わらない`RConCase`)を試すためである。このテストがvalgrindでもクリーンに通ることは、`Compiler.RC2.Reuse`の予約ロジックと`Emit.idr`のcaseの低水準化が、実際には分解されない判別対象を正しく扱うことの非公式な確認も兼ねる(後述の「スコープと制限」を参照)。
- **§7(旧`Test76ConstFoldMutualCafSafety`)**: 畳み込みのテストではなく、安全網である。`chainA = More 1 chainB; chainB = More 2 chainA`は互いを参照する2つのCAFであり、不動点のラウンドを何回回しても、どちらの`cafValueOf`も安定しない。確認するのは、`maxConstFoldIterations`がループを抑え、コンパイラがハングやクラッシュを起こさず、プログラムが通常どおりコンパイルされて動くことだけである(2つのCAFはどちらも、畳まれない通常の`RAppName`呼び出しのまま残る)。`sumFirst 3 chainA`は条件(`length args > 100`)で守られており、コマンドライン引数がなければ常に偽なので、実際には評価されない。この呼び出しは、`chainA`/`chainB`に静的に到達可能な生きた使用箇所を与えるためだけに存在する。これがないと、`ConstFold`がそれらをループにかける機会を得る前に、`Compiler.RC2.DeadCode`に刈り取られてしまう。
- **§8(旧`Test77ConstFoldCafChainCap`)**: `maxConstFoldIterations`自体についての、off-by-oneの回帰テストである。2フィールドのレコードを包む、3段のCAFエイリアスの連鎖を使う(`capC = capB; capB = capA; capA = MkBox d77op1 0`)。フィールドを2つにしたのは、レコードが透過的な単一フィールドのnewtypeとして最適化で消えると、このテストが試したいCAFの連鎖を迂回してしまうからである。各段が解決できるのは、連鎖を1つ下ったCAFが*前の*ラウンドで`CafTable`に登録された後に限られる。そのため連鎖全体を解決するには、1ラウンドではなく複数のラウンドが要る。手作業で確認した。上限が4のとき、`Main.capA`/`capB`/`capC`は`--directive dumprcexpr`の出力から完全に消える(名前で呼ぶものがなくなった時点で`Compiler.RC2.DeadCode`が刈り取る)。`main`には、畳み込み済みの単一の`RCConstClosure`を直接適用する形だけが残る。

## スコープと制限

- **4ラウンドの上限は残る。** 5ラウンド目(以降)が必要になるほど深いCAFの連鎖は、一部が畳まれずに残る。上で述べた単調性の議論により、これは最適化の取りこぼしであり、正しさの問題にはならない。`Test115ConstFoldClosure/ConstFoldClosure.idr`の§8は、現実的な短い連鎖に対して上限が十分に高いことを確認するが、上限に実際に達する場合は試していない。
- **`Compiler.RC2.Reuse`/`Emit.idr`の監査**: `const-con-fold.md`の「スコープ / 制限」節は、`case`の判別対象が完全に畳み込まれて消えた場合について、`Compiler.RC2.Reuse`の予約ロジックと`Emit.idr`のcaseの低水準化を監査し、dup/dropの帳簿が正しいか確かめる必要があると指摘していた。この2つは、判別対象が実行時に分解される本物のヒープ上の`RCLoc`であると仮定しているからである。実際には、これは問題にならない。`RConCase`/`RConstCase`が判別対象を畳み込むと、判別対象を含むcaseノード全体が、選ばれたaltの本体に置き換わる。これは`Compiler.RC2.RC`の注釈パスや`Compiler.RC2.Reuse`が走るより前に起きる(`toRCDefs`では`ConstFold`が最初に走る。`RC2.idr:152-165`)。後続のパスが見るべき`RConCase`ノードは残っておらず、誤って処理する対象もない。`Test115ConstFoldClosure/ConstFoldClosure.idr`の§6が`LEAK_SENSITIVE_TESTS`のvalgrindで問題なく通ることが、その経験的な確認である。形式的な証明ではない。現時点で未解決の懸念はない。
- `foldConst`の`RConCase`のケースにある`RCrash "...matched no alt and had no default"`の枝は、上流のcase網羅性検査があるため到達不能と考えられる(上記「設計」を参照)。全域性のために残してあり、これらの枝を通る再現プログラムが存在することは想定していない。

## ファイル

- `rc2/src/Compiler/RC2/ConstFold.idr`: `CafTable`、`findConAlt`/`insertConArgs`、`RAppName`/`RConCase`の畳み込みのケース、`cafValueOf`。
- `rc2/src/Compiler/RC2/RC2.idr`: `maxConstFoldIterations`、`foldConstProgram`、`toRCDefs`の中の`noconstfold`ディレクティブの組み込みと、そのモジュールドキュメントコメント。
- `rc2/src/Compiler/RC2/RC.idr`: `annotate`に追加した3つの横取り(`RCConst`/`RCEmptyCon`/`RCNull`)。
- `rc2/tests/verify.sh`: 統合後の`Test115ConstFoldClosure/ConstFoldClosure.idr`が`LEAK_SENSITIVE_TESTS`に入っている(§7にはリークを調べる対象がないが、ファイルのそれ以外の部分にはある)。
- `rc2/tests/Test115ConstFoldClosure/ConstFoldClosure.idr`の§5〜§8: 上に説明した4件の回帰テスト(元は独立した`Test74`〜`Test77`)。

## 検証方法

1. 新しい各テストに対し、変更の前後で`--directive dumprcexpr` (`rc2/doc/reading-the-ir.md`を参照)を実行する。何が畳み込まれたかを、プログラムの出力から間接的に推測するのではなく、正確に確認するためである(`RAppName`の呼び出しが`RCConstCon`/`RCConstClosure`のリテラルに置き換わったこと、`case`が唯一残ったaltの本体へつぶれたこと)。
2. 生成されたCを直接読み、残っているべきでないものが*ない*ことを確認する。畳み込まれたCAF自身のC関数への呼び出しが残っていないこと、畳み込まれた辞書に対する`idris2rc2_mkClosure`やコンストラクタ確保の呼び出しがないこと、判別対象がコンパイル時に解決された`RConCase`に対して、実行時のタグ分岐の`switch`/`if`がないこと。
3. valgrind付きで`rc2/tests/verify.sh`を全件実行した。結果は、成功101、既知の失敗0、失敗0で、`LEAK_SENSITIVE_TESTS`の全エントリでdefinitely lostは0バイトだった。とくに`Test115ConstFoldClosure/ConstFoldClosure.idr`の§6は、解決されて捨てられた`RConCase`の判別対象がdup/dropの帳簿に誤りを持ち込まないことを、valgrindで直接確認したものである(上記「スコープと制限」を参照)。
4. `Test115ConstFoldClosure/ConstFoldClosure.idr`の§7(相互参照するCAF)は、それ自体が不動点ループの停止保証の検証手段になっている。上限か変更検出のロジックの実装が誤っていれば、この入力でコンパイラは誤った答えを出すのではなく完全にハングする。したがって、コンパイルが無事に終わること自体が検査である。
5. CAF境界や`RConCase`の畳み込みの対象とするノードの形を広げる場合、新しいリークは、`const-con-fold.md`のバグ#2を見つけたときと同じ方法で二分探索する(変更前のビルドに対して`git stash`し、同一の再現プログラムをvalgrindで再実行する)。本書の`annotate`の横取り漏れのバグは、リークではなくハードなコンパイルエラーだった。しかし、この領域で将来見つかる隙間がすべて、これほどはっきり失敗してくれる保証はない。
