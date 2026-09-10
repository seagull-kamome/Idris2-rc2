# 全プログラム CAF 畳み込みと `RConCase` スクルティニー解決

(原文: `doc/const-caf-fold.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.ConstFold` の `RCConstCon`/`RCConstClosure` 畳み込み
(`rc2/doc/const-con-fold.md`/`rc2/doc/const-closure-fold.md` 参照)は、
かつては、定義ごとに新しい純粋にローカルな `env` を持つ単一のパス
(`foldConstDef`、`RCDef` ごとに 1 回呼ばれ、定義横断の状態なし)
経由で、*1 つの定義自身の本体内でのみ*畳んでいた。そこから 2 つの
ギャップが生じた: それ自体が完全に定数へ畳まれる別のトップレベル
0 引数定義(CAF)への `RAppName` 呼び出しが、呼び出し箇所で決して
定数として扱われなかったこと。そして `RConCase`(コンストラクタ
タグディスパッチ -- 単一 alt の `case` 経由で、通常のレコード
フィールド射影がデシュガーされるものでもある)が、`RConstCase`
(リテラル/`Constant` ディスパッチ)が既にそうしていたようには、
自身のスクルティニーを既知定数値に対して決して解決しなかったこと。

本書は、その 2 つを閉じる機構(`TODO.md` のかつての "Performance:
constant-constructor folding doesn't cross a CAF boundary or a case
scrutinee" エントリ。今や完全に解決されそこから削除済み)、全体を
ゲートする `noconstfold` ディレクティブ、`RConCase` 畳み込みを
`Compiler.RC2.RC` のオーナーシップ注釈へ配線する際に見つかって
修正された 1 つの実際のバグ、そして 4 つの新しい回帰テストを扱う。

## 設計

### CAF 境界越え: 全プログラム不動点

`ConstFold.idr` は、既存の定義ごとの `Env`(`RCLoc` 自身のローカル
id でキーづけされた `SortedMap Int (Subset RCLocal IsAnyConstLocal)`)
と並んで、2 つ目の、より広いテーブルを得る:

```idris2
public export
CafTable : Type
CafTable = SortedMap Name (Subset RCLocal IsAnyConstLocal)
```

(`ConstFold.idr:183-185`)。`CafTable` は `Name` でキーづけされる。
CAF 呼び出しは、ローカル id が意味を持たない定義境界を越えるから
である。`foldConst` は今やあらゆる場所で `Env` と並んで `CafTable`
を取り、その `RAppName` ケースは、`RLet` の値分類が既にローカル
変数を解決するのと同じ方法で CAF 参照を解決する:

```idris2
foldConst caf env (RAppName fc lazy n args) =
    let args' = map (resolveLocal env) args
    in case args' of
            [] => case lookup n caf of
                       Just (Element cval _) => RV fc cval
                       Nothing               => RAppName fc lazy n []
            _  => RAppName fc lazy n args'
```

(`ConstFold.idr:312-318`)。`args' = []` はまさに CAF 呼び出し
(0 引数トップレベル定義は常に空の `args` リストで適用される);
空でない `args'` は通常の呼び出しで、他の全ノードと同様に自身の
オペランドを解決される以外は放っておかれる。解決された CAF 参照は
素の `RV fc cval` になり、`RCConstCon`/`RCConstClosure` 畳み込みが
既に持っていたまさに同じ `RLet`/`RV` 分類アーム
(`ConstFold.idr:237-258`)を通じて `env` へ流れ込む -- 置換の後に
起こることのために別個の機構は不要。

`CafTable` 自体の構築は全プログラムパス
`Compiler.RC2.RC2.foldConstProgram`:

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

(`RC2.idr:137-150`)。各ラウンドは `foldConstDef`(形は不変、
今は現在の `CafTable` を取るだけ)を全トップレベル定義に対して
実行し、それから `cafValueOf` が認識する形になった定義から
テーブルを再構築する:

```idris2
cafValueOf : RCDef -> Maybe (Subset RCLocal IsAnyConstLocal)
cafValueOf (MkRCFun [] _ _ (RV _ cval)) = (\prf => Element cval prf) <$> isConstLocalProof cval
cafValueOf _ = Nothing
```

(`ConstFold.idr:417-419`) -- 本体が素の `RV fc cval` へ畳まれた
0 引数 `MkRCFun`。素の `RPrimVal` 本体は意図的にここで一致*しない*:
それほど単純な CAF は、`ConstFold` が実行される前に
`Compiler.RC2.Inline` 自身の `isCallFree (LPrimVal _ _) = True` に
よって既に全呼び出し箇所へ差し込まれているので、`cafValueOf` が
見る頃には消えている; `Inline` が到達できない
`RCConstCon`/`RCConstClosure` の形状(`isCallFree` 自身の
`LCon`/`LUnderApp` ケース、`const-con-fold.md`/`const-closure-fold.md`
参照)だけがこの経路をまだ必要とする。

ループは、`CafTable` 自身のキー数がラウンド間で成長を止めるか、
`maxConstFoldIterations = 4`(`RC2.idr:127-128`)の後に終了する --
GHC 自身の `-fmax-simplifier-iterations` デフォルトに合わせて、
同じ理由で選ばれた: 2 つの安全性が、外側の上限を単に便利なだけ
でなく安全にする。定義は*まだ定数と分かっていない*から*定数と
分かっている*へしか遷移できず、決して戻らないので、プロセスは
単調である; そして平坦な定数へ決して解決できない相互参照する
CAF のグループ(`a = More 1 b; b = More 2 a`)は、単にそのグループに
対してそれ以上の進捗をせず、通常の動的計算される定義として
残される -- 上限に達しても、深くチェーンした一部の CAF が畳まれ
ないまま(逃した最適化)を意味するだけで、決して誤った畳み込みを
意味しない。

`Compiler.RC2.RC2.toRCDefs` は、Phase 1 正規化と Phase 2 注釈の間に
全体を配線する:

```idris2
preFolded <- ... traverse (\(n, ld) => do d <- toRCDefPreFold n ld; pure (n, d)) lds
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
reused <- ... traverse (\(n, d) => do d1 <- toRCDefPostFold d; ...) folded
```

(`RC2.idr:152-165`) -- `toRCDefPreFold`/`toRCDefPostFold` は `RC.idr`
の既存の Phase 1/Phase 2 分割(この変更で未変更); 不動点ループは
完全にそれらの間に座り、Phase 1 の既に正規化されたがまだ注釈
されていない IR だけを見る。古いワンショットの `foldConstDef`
呼び出しがそうしていたのと同じ。

### `RConCase` スクルティニー解決

`RConstCase` 自身の `foldConst` ケースは既にスクルティニーを解決
していた:

```idris2
foldConst caf env (RConstCase fc sc alts mDef) =
    let alts' = map (foldConstConstAlt caf env) alts
        mDef' = map (foldConst caf env) mDef
    in case resolveConst env sc of
            Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
            Nothing => RConstCase fc sc alts' mDef'
```

(`ConstFold.idr:375-380`)。`RConCase` は同じ形を必要としたが、
`Constant` 等価性ではなくコンストラクタ*タグ*で alt を選び、かつ --
何も束縛しない `RConstCase` alt と異なり -- 一致した各 alt 自身の
フィールド束縛ローカル id を、解決された `RCConstCon` 自身の `args`
の中に既に座っている対応するサブ値で置換する。2 つの小さな
ヘルパがこれを行う:

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

(`ConstFold.idr:187-197`)、および `foldConst` 自身の `RConCase`
ケース:

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

(`ConstFold.idr:359-374`)。各フィールドに対して `isConstLocalProof`
を呼ぶ `insertConArgs` は、任意の配管ではない: `RCon` 自身の
畳み込み(`ConstFold.idr:288-294`)は、*全ての*フィールドが既に
`IsAnyConstLocal` を満たすときにのみ `RCConstCon` を生成するので、
実際にはここで置換される全フィールドは証拠を持ち、真に畳まれた
ローカルとまったく同じように `env` で追跡される -- `Nothing` 分岐は
全域性のために存在するのであって、`RCConstCon` 自身の `args` で
発火することが期待されているからではない。`RCEmptyCon`
(NIL/NOTHING/ZERO/UNIT)はフィールド置換を一切必要としない --
構築上フィールドを持たない -- ので、その分岐はタグで一致し、
選ばれた alt の本体へ直接再帰するだけ。

`RCrash "...matched no alt and had no default"` 分岐は防御的な
全域性クローザであり、このパスが実際に到達することを期待する
コード経路ではない: 本家 Idris2 自身の網羅性チェックが、
型付けされた `case` がスクルティニーの型の全コンストラクタを
(直接、あるいはデフォルト経由で)カバーすることを保証するので、
タグが `alts` の中の何とも一致せず `mDef` を持たない解決済み
`RCConstCon`/`RCConstClosure` は、*ソース*プログラム自身の case
カバレッジが既に不健全だったことを意味する -- `ConstFold` 自体が
引き起こせるものではない。

`RConCase` と `RConstCase` は `foldConst` の単一の相互ブロックを
共有するので、自身の定数性が後で処理される CAF によって(`RAppName`
の畳み込みアーム経由で)のみ確立されるスクルティニーは、同じ
外側の不動点ループから自動的に恩恵を受ける -- この半分についても
別個の再トリガ機構は不要だった。

## 見つかって修正されたバグ

### `RC.idr` の `annotate` に 5 つの定数形式インターセプトのうち 3 つが欠けていた

`RC.idr` の Phase 2 オーナーシップ注釈 `annotate` は、`RCLocal` の
5 つの定数形式のうち 2 つを「不死、dup を決して必要とせず、
所有/借用として決して追跡されない」として既に特別扱いしていた:

```idris2
annotate natives owned e@(RV _ (RCConstCon {})) = pure e
annotate natives owned e@(RV _ (RCConstClosure {})) = pure e
```

(`RC.idr:474,478`、この変更より前)。他の 3 つの形式(`RCConst`、
`RCEmptyCon`、`RCNull`)は `annotate` 自体に同等のインターセプトを
持たなかった -- この変更以前は無害。それら 3 つは常に `RLet` の中に
既に包まれた状態(別のコード経路で処理される)か通常の変数参照
としてのみ `annotate` に到達し、それを囲むバインダの無いこれらの
形式の素の、包まれていない `RV` としては決して到達しなかったから
である。`insertConArgs` はその仮定を破る: `RConCase` alt 自身の
フィールド束縛ローカル id を、(たとえば)解決された
`RCConst`/`RCEmptyCon`/`RCNull` サブ値で直接置換し、それから
その alt の本体へまっすぐ畳むと、まさにそのような素の `RV` が、
上に何も無い状態で初めて `annotate` へ到達しうる。

修正無しでは、`annotate` の汎用フォールバック --

```idris2
annotate natives owned (RV fc v) =
    pure $ if contains v natives || contains v owned then RV fc v else RDup fc v (RV fc v)
```

-- がそれを実際の `RDup fc v ...` で包む。`natives` も `owned` も
定数形式の値を決して追跡しないからである。`Compiler.RC2.Emit.Util`
の `varName` は、この方法で `RDup` に到達するこれら 5 つの形式の
どれに対してもレンダリングを持たない(設計上 -- これは以前は
到達不能だった)。それが誤答でも黙ったリークでもなく、実際の C
コンパイルエラーとして表面化した:

```c
idris2rc2_dup(/* [rc2] unreachable RCConst varName */)
```

-- プレースホルダコメントが `RDup` の出力が期待する実際の変数名の
代わりになるので、引数が少なすぎる呼び出し。

**修正**: `RCConstCon`/`RCConstClosure` に既に存在するのと同じ
3 つのインターセプトを追加:

```idris2
annotate natives owned e@(RV _ (RCConst _)) = pure e
annotate natives owned e@(RV _ (RCEmptyCon {})) = pure e
annotate natives owned e@(RV _ RCNull) = pure e
```

(`RC.idr:495-497`)。これは `annotate` を、最初から 5 つの定数
形式すべてを一様に除外していた
`splitBorrows`/`dropIfLastUse`/`boxedOperands` の `isBoxedOperand`
(`RC.idr:389-393`、`420-424`、`448-452`)と一致させる -- `annotate`
自体が、5 つのうち 2 つだけを特別扱いしていた唯一の場所だった。
`RConCase` 畳み込みが存在するまで、その 2 つだけが素で到達し得た
からである。

**検証方法**: `RConCase` 畳み込みの構築中に、それを行使する
再現コードをコンパイルし、結果の C コンパイルエラーを直接読んで
発見(ここでの失敗モードは黙ったミスコンパイルやリークではなく
ハードなコンパイルエラーなので、valgrind や出力差分で捕まえる
必要なく即座に表面化した)。3 つの追加インターセプトで再ビルド
し、同じ再現コードと完全な `rc2/tests/verify.sh` 回帰スイートを
再実行して修正を確認。

## `noconstfold` ディレクティブ

`--directive noconstfold` / `%cg rc2 noconstfold` は `foldConstProgram`
不動点パス全体を無効化する(両半分 -- CAF 境界越えと `RConCase`
スクルティニー解決は同じ `foldConst` 走査に住むので、より細かい
トグルは無い)。`noinline`/`noconaltnative`/`nomutualloop`/`noloop`/
`nosink`/`nodualabi`/`nodeadcode` とまったく同じ `no<stagename>`
パターンに従う(`RC2.idr:68-107` 自身のモジュールドキュメント
コメントがそれら全てをまとめて列挙している)。定数 `ExtPrim`
畳み込み(`prim__codegen`、`foldConst` の `constExtPrimValue` --
かつては `toRCDefPreFold` の中の別個の `Compiler.RC2.ConstExtPrim`
パス)は、今やこの同じ走査に住むので、これも `noconstfold` で
ゲートされる:

```idris2
folded <- if "noconstfold" `elem` disabled
             then pure preFolded
             else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
```

(`RC2.idr:157-159`)。このリストの他の全段階と同様、それをスキップ
しても依然として正しい(最適化は劣る)C を生成する -- 下流の
何も、CAF や case スクルティニーが畳まれていることを要求しない。

## テスト

4 つの回帰ケース。今や `rc2/tests/Test69ConstFoldClosure` の
セクション 5-8 として統合されている(そのファイル全体が
`rc2/tests/verify.sh` の `LEAK_SENSITIVE_TESTS` に登録されている;
セクション 7 -- 相互 CAF のもの -- はそれ自体でリークチェックする
ものが無い。その主眼が畳み込みが決して起こらないことである):

- **§5(旧 `Test74ConstFoldCafBoundaryClosure`)** -- *別の*定義
  (`useDict74`)からのみ参照され、`main` の中でインラインで構築
  されないクロージャ形状の CAF(`dict74 : Pair74; dict74 =
  MkPair74 d74op1 d74op2`)。これは意図的に、新しい全プログラム
  `CafTable` を `Compiler.RC2.Inline` 自身のコンストラクタ限定の
  差し込みサイドチャネル(自身の呼び出し箇所で構築された
  コンストラクタ形状の CAF にのみ到達する、`const-con-fold.md` の
  CAF 境界の議論参照)から分離する -- これが畳まれるなら、それは
  `Inline` ではなく新しい不動点ループがやった証拠。`--directive
  dumprcexpr` で手作業で確認: `Main.useDict74` 自身のダンプが
  `Main.dict74` を `RAppName ... "Main.dict74" []` 呼び出しではなく
  `RCConstCon`/`RCConstClosure` リテラルとして直接参照する。
- **§6(旧 `Test75ConstFoldConCaseScrutinee`)** -- `directCase` の
  スクルティニーは、`case` の直上の `let` で束縛された既知定数の
  `RCConstCon` なので、case 全体(タグディスパッチを含む)が単一の
  `RPrimVal` へ畳まれて消えねばならない。`areaOf` 自身の 2 つの
  呼び出しは、パスの必須のフォールバック(自身の再帰的に畳まれた
  alt 以外は `RConCase` 不変)を行使するために、真に動的な
  スクルティニー(通常の関数引数)を保つ。このテスト自身の
  パスする valgrind クリーンな実行は、`Compiler.RC2.Reuse` の予約
  ロジックと `Emit.idr` 自身の case ロワリングが、実際には一度も
  分解されないスクルティニーを正しく扱うという非公式の確認を
  兼ねる -- 下記「スコープ / 制限」参照。
- **§7(旧 `Test76ConstFoldMutualCafSafety`)** -- 畳み込みテスト
  ではなくセーフティネット: `chainA = More 1 chainB; chainB =
  More 2 chainA` は互いを参照する 2 つの CAF なので、何ラウンドの
  不動点が実行されてもどちらの `cafValueOf` も安定しない。
  チェックされる唯一のことは、`maxConstFoldIterations` がループを
  制限し、プログラムが(両 CAF が通常の畳まれていない `RAppName`
  呼び出しとして残される)コンパイラをハングさせたりクラッシュ
  させたりせず、依然として通常どおりコンパイル・実行されること。
  `sumFirst 3 chainA` は、CLI 引数無しでは常に偽の条件
  (`length args > 100`)の後ろにガードされているので、実際には
  一度も評価されない -- 純粋に `chainA`/`chainB` に生きた、静的に
  到達可能な使用を与えて、`ConstFold` がそれらをループする機会を
  得る前に `Compiler.RC2.DeadCode` がそれらを刈り取れないように
  するために存在する。
- **§8(旧 `Test77ConstFoldCafChainCap`)** -- `maxConstFoldIterations`
  自体の off-by-one 回帰: 2 フィールドレコードに対する 3 ホップの
  CAF エイリアスチェーン(`capC = capB; capB = capA; capA =
  MkBox d77op1 0`。2 フィールドなのは特に、このテストが行使する
  ために存在する CAF チェーンを回避してしまう透過的な単一
  フィールド newtype としてレコードが最適化されないようにするため)。
  各ホップは、チェーンの 1 つ先の CAF が*先行*ラウンドで既に
  `CafTable` へ入力されている場合にのみ解決されるので、チェーン
  全体の解決には 1 ラウンドではなく複数ラウンドが必要。手作業で
  確認: 上限が 4 のとき、`Main.capA`/`capB`/`capC` は `--directive
  dumprcexpr` 自身の出力から完全に消える(名前で呼ぶものが何も
  無くなると `Compiler.RC2.DeadCode` によって刈り取られる)。
  `main` が単一の畳まれた `RCConstClosure` を直接適用するのを
  残して。

## スコープ / 制限

- **依然として 4 ラウンド上限で制限される。** 5 ラウンド目
  (あるいはそれ以上)を必要とするほど深い CAF チェーンは、
  部分的に畳まれないまま -- 上記の単調性の議論により、逃した
  最適化であって決して正当性の問題ではない。`Test69ConstFoldClosure`
  §8 は、上限が現実的な短いチェーンには少なくとも十分高いことを
  確認する; 上限が実際に達せられることは行使しない。
- **`Compiler.RC2.Reuse`/`Emit.idr` の監査**: `const-con-fold.md`
  自身の「スコープ / 制限」節は、`case` スクルティニーが完全に
  畳まれて消えると、`Compiler.RC2.Reuse` の予約ロジックと
  `Emit.idr` 自身の case ロワリング -- どちらもスクルティニーが
  実際の、ランタイムで分解されるヒープ `RCLoc` だと仮定する --
  が正しい dup/drop 記帳のために監査を必要とする、と指摘した。
  実際にはこれは現行の懸念にならない: `RConCase`/`RConstCase` が
  スクルティニーを畳むと、`Compiler.RC2.RC` の注釈パスや
  `Compiler.RC2.Reuse` が実行される前に(`ConstFold` は `toRCDefs`
  で最初に実行される、`RC2.idr:152-165`)、case ノード全体
  (スクルティニーを含む)が選ばれた alt 自身の本体で置き換え
  られる -- それらの後のパスが見る生き残った `RConCase` ノードが
  無いので、それらが誤って扱うものが何も無い。
  `Test69ConstFoldClosure` §6 自身の `LEAK_SENSITIVE_TESTS` を通じた
  valgrind クリーンなパスがこの経験的な確認であって、形式的な
  証明ではない; 現在開いている残余の懸念は無い。
- `foldConst` 自身の `RConCase` ケースの `RCrash "...matched no alt
  and had no default"` 分岐は、本家自身の case カバレッジチェック
  (上記「設計」参照)を考えると到達不能と信じられている -- 全域性
  のために保持されているのであって、それらを行使する再現コードが
  存在すると期待されているからではない。

## ファイル

- `rc2/src/Compiler/RC2/ConstFold.idr` -- `CafTable`、`findConAlt`/
  `insertConArgs`、`RAppName`/`RConCase` 畳み込みケース、`cafValueOf`。
- `rc2/src/Compiler/RC2/RC2.idr` -- `maxConstFoldIterations`、
  `foldConstProgram`、`toRCDefs` 内の `noconstfold` ディレクティブ
  配線とその自身のモジュールドキュメントコメント。
- `rc2/src/Compiler/RC2/RC.idr` -- `annotate` の 3 つの追加
  インターセプト(`RCConst`/`RCEmptyCon`/`RCNull`)。
- `rc2/tests/verify.sh` -- 統合された `Test69ConstFoldClosure` が
  `LEAK_SENSITIVE_TESTS` にある(その §7 はリークチェックするものを
  何も畳まないが、ファイルの残りは畳む)。
- `rc2/tests/Test69ConstFoldClosure` §5-§8 -- 上記で説明した 4 つの
  回帰ケース(かつては単独の `Test74`-`Test77`)。

## 検証方法

1. `--directive dumprcexpr`(`rc2/doc/reading-the-ir.md` 参照)を
   各新テストに対して、変更の前後で使い、何が畳まれたか
   (`RAppName` 呼び出しを置き換える `RCConstCon`/`RCConstClosure`
   リテラル; 1 つの生き残った alt の本体へ潰れる `case`)を、
   プログラム出力から間接的に推論するのではなく正確に確認する。
2. 生成された C を直接読んで、もうそこに無いはずのものの*不在*を
   確認する: 畳まれた CAF 自身の C 関数への残余呼び出し無し、
   畳まれた辞書に対する `idris2rc2_mkClosure`/コンストラクタ割り当て
   呼び出し無し、スクルティニーがコンパイル時に解決された
   `RConCase` に対するランタイムタグディスパッチ `switch`/`if` 無し。
3. 完全な `rc2/tests/verify.sh`(valgrind 込み)実行: 101 passed、
   0 known、0 failed、全 `LEAK_SENSITIVE_TESTS` エントリにわたって
   0 bytes definitely lost -- 特に `Test69ConstFoldClosure` §6 は、
   解決されて破棄された `RConCase` スクルティニーが dup/drop 記帳
   エラーを導入しないという直接の valgrind ベースの確認である
   (上記「スコープ / 制限」参照)。
4. `Test69ConstFoldClosure` §7(相互参照する CAF)は、それ自体が
   不動点ループ自身の終了保証のための検証装置である -- 上限や
   変更検出ロジックの誤った実装は、単に誤答を生むのではなく、
   この入力でコンパイラを完全にハングさせるので、それ自身の
   成功したコンパイルがチェックである。
5. もし CAF 境界や `RConCase` 畳み込みに参加するノード形状を拡張
   するなら: `const-con-fold.md` 自身のバグ #2 が見つかったのと同じ
   方法で新しいリークを二分探索する(変更前ビルドに対して
   `git stash`、同一の再現コードを valgrind 下で再実行) --
   本書が説明する `annotate` のインターセプト欠落バグはハードな
   コンパイルエラーであってリークではなかったが、この領域の
   将来の全てのギャップがそれほど大声で捕まる保証は何も無い。
