# 定数コンストラクタ畳み込み(`RCConstCon`)

(原文: `doc/const-con-fold.md`。内容が乖離した場合は原文を正とする。)

フィールドが -- 再帰的に -- すべてコンパイル時定数であるコンストラクタ
(`[1,2,3,4,5]`、`Just 42`、CAF の本体全体)は、このパス以前は、評価
のたびに新しいヒープ割り当てとして再構築されていた:
`Main.constList` は値が決して変わらないのに、読まれるたびに 5 つの
`Cons` セルを割り当てていた。`Compiler.RC2.ConstFold` は既に
算術/比較/case-of-constant を畳み込んでいたが、`RCon` 自体は決して
畳み込まなかった。本書は設計(`RCLocal` の新しい `RCConstCon` ケース、
不死のファイルスコープ static として畳まれ・ステージングされる)と、
構築中に見つかって修正された 2 つのバグ -- 1 つは畳み込みを黙って
無効にしていたもの、1 つは実際のメモリリーク -- を扱う。

## 設計

### `RCLocal` の新しい定数形式

`RCExp.idr` は既存の `RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon` と並んで
5 つ目の `RCLocal` ケースを追加する:

```idris2
RCConstCon : Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> RCLocal
```

不変条件(唯一の生産者である `Compiler.RC2.ConstFold` だけが維持):
`args` の全要素はそれ自身が再帰的にこの 5 つの定数形式のいずれか
である -- 決して素の `RCLoc` ではない。

### 畳み込み(`Compiler.RC2.ConstFold`)

`foldConst` は今や、既に算術を `RPrimVal` へ畳み込んでいたのと同じ
方法で `RCon` を畳み込む: 全フィールドが -- 直接、あるいは `env`
(このパスが既に定数だと証明した変数。今は単なる `Constant` では
なく `SortedMap Int RCLocal` として追跡される)経由で -- 定数形式へ
解決されるなら、`RCon` 全体が `RV fc (RCConstCon ...)` になる。
それを囲む `RLet` ケースは、既に畳まれた `RPrimVal` を拾っていたの
と同じ方法で、`RV`-of-`RCConstCon` の畳み込み結果を拾う: `env` へ
挿入し、`body` の何もその変数を参照しなくなったら `RLet` を丸ごと
落とす。

明示的にしておく価値のある設計ポイントが 2 つ:

- **`reuseFrom` の構築は決して畳み込まれない。** 既に再利用予約を
  主張している `RCon`(`Compiler.RC2.Reuse` は Phase 1/2 の後に
  実行されるので、Phase 2 前には実際にはこれは起こり得ないが、
  パターンマッチはいずれにせよ `reuseFrom = Nothing` だけに一致する)
  は動的なまま -- 畳み込むと予約が無意味になる。
- **アリティ 0 の `RCon` は除外される。** NIL/NOTHING/ZERO/UNIT は
  `RCon` 自身の `emitRC` ケースに到達する前に既に専用の `RCNull`
  経路を取るので、このパスに到達する真にアリティ 0 の `RCon` は、
  ステージングされた static に長さ 0 の C 配列を必要とし、素の C は
  それを許さない(理論だけでなく実際にこれが問題になった理由は
  `Bugs found #1` 参照)。

**部分畳み込み**: フィールドが*すべて*は解決されない `RCon` は
動的なままだが、解決*された*全フィールドはその場で書き換えられる。
`partialConst x = x :: constList` は `x` のために実際のランタイム
`Cons` 割り当てを保つが、その 2 つ目のフィールドは、死んだ変数の
再読み取りではなく、既にステージングされた `constList` static への
直接参照である。

**`RCLocal` オペランドを持つ他の全ノード**(`RAppName`、`RApp`、
`RUnderApp`、`RExtPrim`、`RStructGet`/`RStructSet`、`ROp`、
`RCmpCase`)も、今やオペランドが `env` に対して解決される。どれも
それ自身の値へは畳まれないにもかかわらず。これは任意ではない --
`Bugs found #1` 参照。

### ステージング(`Compiler.RC2.Emit.Util`)

既存の `ConstDef` 機構(`boxedConstExpr`、`Emit/Util.idr:637`)をほぼ
そのまま鏡写しにする: 新しい `ConstConDef` 状態(名前で重複排除する
`SortedMap RCLocal String` と、ステージング順の完成した定義テキスト
リストのペア)が、新しい `boxedConstConExpr` によって参照される。
`RCConstCon` のステージングは、先にネストした `RCConstCon` フィールドを
再帰的にステージングする -- 子は常に定義リスト内で親より前に来る。
これが重要なのは、C の static 初期化子は*既に宣言済み*の static の
アドレスしか取れない(ファイルスコープでの前方参照なし)からである。

ステージングされた C の形状は、`IDRIS2RC2_Constructor` 自身の
レイアウトをフィールドごとに鏡写しにするが、フレキシブル配列
メンバの代わりに固定サイズ配列として(素の C はフレキシブル配列
メンバの static 初期化子を持たない):

```c
static struct {
    IDRIS2RC2_Header header;
    int32_t arity; int32_t tag; char const *name;
    IDRIS2RC2_Value *args[N];
} const constcon_7 = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CONSTRUCTOR),
    2, 1, NULL,
    { (IDRIS2RC2_Value*)(&idris2rc2_smallInt64[5]), NULL }
};
```

`IDRIS2RC2_STOCKVAL` は、小整数キャッシュと `ConstDef` 値が既に使って
いるのと同じ不死の参照カウントマーカ(`IDRIS2RC2_REFCOUNT_MAX`)で
ある -- **これが、コンパイラの残りのオーナーシップ解析
(`Compiler.RC2.RC` の `annotate`)に自身の変更を一切不要にさせる
ものである**: `idris2rc2_dup`/`idris2rc2_drop` 自身の `REFCOUNT_MAX`
ガードが、ステージングされた値に対するあらゆる dup/drop を既に
ランタイム no-op にするので、annotate は通常の Boxed 値に対して常に
生成するのと同じ dup/drop 呼び出しを生成し続けてよい。

とはいえ、`annotate` 自身のヘルパ関数のうち 3 つ(`RC.idr` の
`splitBorrows`、`dropIfLastUse`、`boxedOperands`)は、dup/drop 呼び出し
自体を出力する以外の理由で、オペランドを boxed かどうか*分類*する
(使用が dup を必要とするか否かの判断、`ROp` などの `postDrop`
リストの判断) -- これらは既存の `RCConst`/`RCNull`/`RCEmptyCon`
ケースと並んで明示的な `RCConstCon` ケースを必要とした。同じ理由:
不死の値は、所有/借用された変数のように追跡される必要が決して
ない。`Compiler.RC2.Sink`/`Compiler.RC2.DualABI` 自身の並行する
`localRepIn` ヘルパも同じ 1 行の追加を必要とした(常に `RBoxed`、
`RCEmptyCon` と同じ)。

## 見つかったバグ

### #1: 畳み込みがほぼ完全に無効だった

一番最初の動作版は `RLet fc var rep (RCon ...) body` -- 値が*直接*
`RCon` である `RLet` -- だけに一致した。これは、例外ではなく共通
ケースだと判明した 2 つの形状を見逃していた:

- **ANF 自身の `RLet` チェーンはネストする、平坦化しない。**
  `[1,2,3,4,5]` は `RLet v0 (Cons 5 Nil) (RLet v1 (Cons 4 v0) (... RLet
  v4 (Cons 1 v3) (RV v4)))` へ正規化される -- 外から内へ読むと、`v0`
  の値は素の `RCon` だが、`v0` 自身の*本体*は `RCon` ではなく別の
  `RLet` である。直接マッチ版は最内のセルだけを畳み、`value` として
  `RCon` の代わりに `RLet` を見た瞬間に諦めた。
  **修正**: 先に `value` を(再帰的に)畳み、それから*畳み込み結果*
  を分類する -- `RPrimVal` も `RV`-of-`RCConstCon` もどちらも「今や
  既知の定数」を意味する -- *元の* `value` の形状をパターンマッチ
  するのではなく。
- **畳まれた変数の、木の他の場所での使用が決して書き換えられ
  なかった。** 既存の算術畳み込みの `env` は `ROp`/`RCmpCase`/
  `RConstCase` によってだけ(畳み込み結果を*計算する*ために)参照
  され -- ノード自身の `args` をその場で書き換えることは決して
  なかった。それは算術には問題なかった(畳み込みが失敗した `ROp`
  は同じ `args` を変えずに再出力するだけで、情報の損失なし)。
  しかし `RLet` 自身の「`body` がその変数をもう参照しなくなったら
  この束縛を落とす」チェック(`contains (RCLoc var) (freeLocalsR
  body')`)は、それらの `args` が実際に書き換えられることに依存する
  -- 例えば `RAppName` の引数リストの中で未解決のまま残された
  `RCLoc` は、その変数を永遠に「まだ使われている」ように見せ、
  `RLet`(とそれが守る割り当て)が畳まれて消えるのを恒久的に
  ブロックする。**修正**: `RCLocal` オペランドを持つ全ノード
  (`RAppName`、`RApp`、`RUnderApp`、`RExtPrim`、`RStructGet`/
  `RStructSet`、および `ROp`/`RCmpCase` 自身の `args`)が、今や
  それらを `env` に対しても解決する。純粋に `freeLocalsR` が
  置換を見るように -- これらのノードのどれもこれから自身の値へは
  畳まれない。

`--directive dumprcexpr` の出力を前後で比較して捕捉:
`Main.constMaybe`(本体全体が 1 つの `RCon`、`RLet` ラッパーが
一切無い CAF)は最初から正しく畳まれた; `Main.constList`(上記の
`RLet` チェーン形状)と `Main.main` 内のあらゆる使用(常に `RLet`
チェーンを通じて到達される、`printLn constList` など)は、両修正が
入るまで全く畳まれなかった。

### #2: ネイティブ非適格な定数の `env` 差し込みがメモリをリークした

修正 #1 が実際に `args` をその場で書き換え始めると、2 つ目の、
より深刻なバグが浮上した: `42` が `Integer`(`BI`、GMP 裏付け)へ
デフォルトする `printLn (Just 42)` が、実行ごとに 24+16 バイトを
リークした(`idris2rc2_mkIntegerLiteral` -> `idris2rc2_mkInteger` ->
`aligned_alloc`、valgrind で確認、同一の再現コードでこのブランチ前の
ベースラインでは不在であることを確認)。

根本原因: `RC.idr` の `bindOne` には、`RCConst` は `litRep` で
カバーされる(ネイティブ適格な)`Constant` に対して*のみ*生成される
という文書化された不変条件がある -- `BI`/`Str` は常に実際の `RCLoc`
の後ろに留まる。特に `Compiler.RC2.RC` の `annotate` がそれらの
オーナーシップを通常どおり追跡し続けるためである。`annotate` 自身の
`isBoxedOperand`/`splitBorrows`/`dropIfLastUse` はいずれも**あらゆる**
`RCConst` を無条件に非 Boxed として扱う(その不変条件の下では正しい
-- ネイティブスカラは参照カウント操作を決して必要としない)。
`ConstFold` の `RLet` ケースは、*あらゆる*畳まれた `RPrimVal` に
対して `(var, RCConst c)` を `env` へ挿入し始め、その `env` エントリを
他のノード自身の `args` へ差し込み始めた(修正 #1)ことで、不変条件
を破った: `BI`(または `Str`)定数が、今や素の `RCConst` オペランド
として `annotate` に到達し、「決して drop を必要としない」と分類され、
その裏の実際のヒープ割り当て(`idris2rc2_mkIntegerLiteral` の
`mpz_t`)がリークした。

**修正**: `env` は `litRep c` が `Just _`(ネイティブ適格)のとき
だけ `RPrimVal` 畳み込みエントリを得る -- 畳まれた `BI`/`Str` 定数は
その `RLet`(と他の場所でのその `RCLoc` 使用)を保つ。まさに
`bindOne` 自身の不変条件が既に要求していたとおり。`asConstLocal`
(`RCon` フィールドが `RCConstCon` へ畳み込むのに「十分に定数」か
どうかの判断)は、同じ根底の理由だが別の機構による 2 つ目の、
独立した除外を持つ -- 特に `RCConst (BI _)`。`BI` 自身の C
レンダリング(`idris2rc2_getSmallInteger`/`idris2rc2_mkIntegerLiteral`)
は実際の関数呼び出しで、リークを脇に置いても、static 初期化子が
保持できるコンパイル時定数式では決してないからである。

両除外は独立して重要: `env` 登録ガード(上記)は `annotate` の
オーナーシップ追跡を守る; `asConstLocal` の `BI` 除外は C 出力段階を
守る。一方を保ったままもう一方を削除すると、単なる最適化の回帰では
なく、実際のバグを再導入する。

捕捉方法: 拡張された回帰テストに対するゼロからの valgrind 実行が、
存在するはずのないリークを検出した; `git stash` でブランチ前
ベースライン(`f x = x + 1; main = printLn (f 100)`、`RCConstCon` が
一切関与しない)に対して二分探索し、新規に導入されたことを確認、
それから `ConstFold.idr` の一時的な `Debug.Trace` で、どの `RLet` が
その `RCLoc` を失っているかを正確に確認した。

## スコープ / 制限(MVP)

**下記の両制限は今や解決済み -- `rc2/doc/const-caf-fold.md` を参照**。
CAF 境界のギャップを閉じる全プログラム `CafTable` 不動点ループと、
2 つ目を閉じる `RConCase` スクルティニー解決機構がそこにある。
歴史的文脈のためここに書かれたまま残す(これがその後の拡張が入る
前の畳み込みの姿である):

- **他のトップレベル CAF は畳み通されない。** 別の CAF を参照する
  `RAppName` は、その CAF 自身の本体が完全に畳まれても、決して定数
  として扱われない -- そうするには全プログラム依存関係解決(2 つが
  互いを参照する場合、どちらの CAF が先に畳まれるか)が必要で、
  このパスは意図的にまだそれを試みない。1 つの定義自身の本体*内*の
  リテラルなコンストラクタのネストだけが畳まれる。
- **`RConCase`/`RConstCase` のスクルティニー(`sc`)は決して解決
  されない。** `sc` が証明可能に畳まれた `RCConstCon` であっても、
  このパスは一致する分岐を静的に選ぼうとしない -- `sc` は `RCLoc`
  参照(あるいは既にそうだったもの)のまま。そのため既知定数の
  スクルティニーに対する case は、丸ごと畳まれて消える代わりに、
  依然として実際のランタイムディスパッチへコンパイルされる。
  `RCon` 自身の `emitRC` ケースと `Compiler.RC2.Reuse` の予約
  ロジックは、どちらも依然としてスクルティニーを実際のヒープ
  `RCLoc` としてしか理解しない -- ここで `sc` を解決するには、
  それらの消費者に `RCConstCon` スクルティニーも扱うよう教える
  必要があり、このパスのスコープ外。

## ファイル

- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCLocal` の新しい `RCConstCon`
  ケース、`Eq`/`Ord`/`Show` インスタンス(`List` を通じて自己参照
  するコンストラクタが停止性チェッカの射程に入ると、3 つとも
  `covering` 注釈を必要とした -- インスタンスヘッダ参照)。
- `rc2/src/Compiler/RC2/ConstFold.idr` -- 畳み込み自体(`RLet` の
  拡張された `case value' of`、単独の `RCon` ケース、`RAppName` 等の
  オペランド解決ケース)、`asConstLocal` の `BI` 除外。
- `rc2/src/Compiler/RC2/Emit/Util.idr` -- `ConstConDef` 状態、
  `boxedConstConExpr`/`constConFieldExpr`、`RCConstCon` ケースで
  拡張された `RCLocal` 消費ヘルパ(`varName`/`repOfLocal`/
  `inlineExprFor`)。
- `rc2/src/Compiler/RC2/Emit.idr` -- `header` 関数自身の static
  定義リスト出力。
- `rc2/src/Compiler/RC2/RC.idr` -- `annotate` 自身の `splitBorrows`/
  `dropIfLastUse`/`isBoxedOperand`/`(RV fc v)` ケース、`RCConstCon`
  を不死(dup/drop の追跡を決して必要としない)として扱うよう拡張。
- `rc2/src/Compiler/RC2/Sink.idr`、`rc2/src/Compiler/RC2/DualABI.idr`
  -- `localRepIn` 自身の `RCConstCon` ケース(常に `RBoxed`)。
- `rc2/support/rc2/datatypes.h` -- `IDRIS2RC2_Constructor` のレイアウト
  (参照のみ、未変更)と `IDRIS2RC2_STOCKVAL`/`IDRIS2RC2_REFCOUNT_MAX`
  (そのまま再利用)。
- `rc2/tests/Test17ConstFold.idr` -- 回帰テスト(そのファイルの末尾に
  統合済み): 完全畳み込み
  (`constList`/`constMaybe`/`nestedConst`)、部分畳み込み
  (`partialConst`)、同じ不死の値の複数箇所での分解
  (`headOf`/`tailOf`/`unwrapMaybe`、各々複数回呼ばれる)で
  dup/drop が no-op である安全性を直接行使する。
- `rc2/tests/BenchConstConFold.idr` -- 定数の 10 要素リストを 300 万回
  合計する; 畳み込みを戻したこの同じ rc2 ビルドより約 3.4 倍速く、
  本家 RefC より約 4.5 倍速い。

## 検証方法(これを拡張する場合)

1. `--directive dumprcexpr`(`rc2/doc/reading-the-ir.md` 参照)を
   任意の再現コードに使うと、`RCConstCon` 値が `#Name@tag(args)`
   (`Show RCLocal` 自身のレンダリング)として表示される -- 生成 C
   を見る前に、ある定義が完全に/部分的に/全く畳まれなかったかを
   確認する最速の方法。
2. 生成 C 自身の static 定義セクション(`.c` 出力で `constcon_` を
   grep)を読んで、依存関係の順序(子が親より前)と、最外の値
   だけでなく全てのステージングされた値に `IDRIS2RC2_STOCKVAL` が
   あることを確認する。
3. **`env` から差し込まれる `Constant` ケース(またはノード)を
   拡張するときは、常にゼロからの再現コードを valgrind すること。**
   上記のバグ #2 は、失敗モードがクラッシュや誤答ではなく黙った
   リークであることを示す -- 通常の出力差分には現れない。リークの
   出所が明白でないなら変更前ビルド(ソース変更を `git stash` し、
   再ビルドし、同じ再現コードを再実行)に対して二分探索すること;
   このパスの拡張中に見つかったリークを、チェックせずに既存の
   ものと決めつけないこと。
4. もし `RConCase`/`RConstCase` 自身の `sc` を `env` に対して解決
   する(上記のスコープ制限を解除する)なら: `Compiler.RC2.Reuse` と
   `Emit.idr` の `emitConCaseInto`/`emitConstCaseInto` は、どちらも
   現状スクルティニーが実際のヒープ `RCLoc` だと仮定している --
   畳み込み自体だけでなく、これを緩める前に両方を監査すること。
