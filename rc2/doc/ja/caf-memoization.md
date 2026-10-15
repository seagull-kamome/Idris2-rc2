# CAFのメモ化: 新しいIRノード`RMemoize`

(原文: `doc/caf-memoization.md`。内容が乖離した場合は原文を正とする。)

**状態: 実装済み、検証済み。** `Test86CafMemoization.idr`は下記の`TODO.md`の例をそのまま再現し、`0 0 0`ではなく`0 1 2`になることを確認している。`verify.sh`全体(`refc-suite`、スモークテスト、valgrind)も問題なく通る。対象はボックス化されたCAFだけである。ネイティブの場合は実装せず、到達不能だと確認した。理由は「Emit側のCコード生成」を参照。

## 修正するバグ

次のような、引数を取らないトップレベルの定義を考える。

```idris2
counter : IORef Int
counter = unsafePerformIO (newIORef 0)
```

このメモ化がなければ、これは参照のたびに再実行される普通のC関数にコンパイルされる。共有されるはずの`IORef`が、参照ごとに3つの別々の`IORef`になってしまう。この挙動は`--cg rc2`でも本家の`--cg refc`でも同じであることを確認した(Chezは正しく共有する)。引数なしのトップレベル`Delay`定義に対する`Lazy`/`Inf`のメモ化(`rc2/doc/lazy-memoization.md`)は、このノードの上に成り立っている。

**この設計の範囲**: 対象は上の単純なCAF、つまり本物の(副作用を持ちうる)本体を持つ引数なしの定義である。`RMemoize`はCAF自身の本体を包み、高々1回しか評価されないことを保証する。

引数なしのトップレベル`Delay`定義は、このノードが挿入されるより前に別の処理で扱う。`Compiler.RC2.LazyCaf`が先にそれを単純な`x = e`に書き換えるので、`RMemoize`は実際の値`e`を直接メモ化することになる(`rc2/doc/lazy-memoization.md`の「`Delay`」)。`Delay`のまま残しても`RMemoize`は正しく動く。CAFのトップレベルのスロットを包めば、`RDelay`が作る1つのセルがすべての参照で共有され、そのセルは2回目の`force`で自分の値をキャッシュするからである。ただしそれでは、1つの仕事を2層のメモ化がこなすことになる。`LazyCaf`のモジュールコメントにも「セルが同じ値を二重にメモ化してしまう」と明記されている。

## IRノード

```idris2
RMemoize : FC -> Name -> Rep -> RCExp -> RCExp
```

CAF自身の本体を包むノードである。引数なしの`MkRCFun`の本体*全体*としてのみ生成され、より大きな式の内側にネストすることも、ほかの形の定義に対して生成されることもない。`rep`は、その`MkRCFun`自身の`retRep`をそのままコピーしたもので、あらためて導出したものではない。

**識別子は、新しいカウンタではなくCAF自身の`Name`を使う。** `Name`はすでにグローバルに一意であり、このコードベースのほかの場所でも`cName`で一貫してマングルされている。それを再利用すれば、IDを割り当てる仕組みを新設せずに済み、Emitが使う静的変数の名前もそのまま得られる。

将来どれかのパスが`RMemoize`ノードを複製したとしても(現状複製するパスがない理由は「`Inline`との相互作用」を参照)、`Name`が一緒に複製される限り、どのコピーも同じ静的変数を指す。式を複製しうるすべてのパスが`RMemoize`に注意を払わなくても、複製後にメモ化が保たれる。

### `Compiler.RC2.InlineCExp`との相互作用

`Inline`の基準A(`buildEligible`)は、呼び出し先の本体が`isCallFree`(関数呼び出しを一切含まない)であることを、呼び出し元に差し込む前の条件にしている。`RMemoize`のガードが必要になりうるCAFは、本物の副作用を持つものか、共有する価値のある重い計算である。そのようなCAFは、`unsafePerformIO`や、その下にあるプリミティブ、あるいは重さの原因となる呼び出しのうち、少なくとも1つの呼び出しを必ず含む。したがって`isCallFree`を満たすことはあり得ない。

**`Inline`の変更は要らない。** 現状では、`Inline`が複製しうるCAFの集合と、`RMemoize`がガードすべきCAFの集合は、構造上互いに素である。`Inline`の適格性基準を変更するときは、この文書の論拠を再確認すること。

## 挿入位置: `ConstFold`の直後、Phase 2の直前

`Compiler.RC2.RC2.toRCDefs`のパイプラインは、現在次の形をしている。

```
Inline (Lifted level)
  -> toRCDefPreFold (Lifted -> RCExp, "Phase 1", per definition)
  -> foldConstProgram (ConstFold, whole-program CafTable fixpoint)
  -> [insertMemoize goes here]
  -> toRCDefPostFold (Phase 2 ownership annotation) + Reuse + ConAltNative
  -> MutualLoop -> Loop -> Sink -> DualABI -> DeadCode -> DupMerge -> Emit
```

新しいパス`insertMemoize : List (Name, RCDef) -> List (Name, RCDef)`は、`folded`(ConstFoldの出力)に対して実行する。その結果は、既存の`reused <- ...`の`traverse`に、`folded`の代わりに渡す。

**この位置である理由(前でも後でもない理由):**

- **`ConstFold`より前ではない。** `Compiler.RC2.ConstFold`の全プログラム`CafTable`不動点(`doc/const-caf-fold.md`)は、本当に定数であるCAFを定義の境界を越えてリテラルに解決する。その前にすべての引数なし定義を`RMemoize`で包むと、`ConstFold`はラッパーの内側まで見通すか、メモ化済みの定義を畳み込み対象から外すかしなければならない。得るものは何もない。`ConstFold`が定数と証明できるCAFには、実行時のガードがそもそも要らない。
- **`ConstFold`より後なので、残ったものだけを包める。** この時点で残っている引数なしの`MkRCFun`のうち、本体が単なるリテラル(`RPrimVal`)でも、すでに不死の静的定数コンストラクタ(`RCConstCon`、`doc/const-con-fold.md`)でもないものは、本物の副作用か、本当に定数でない計算のどちらかである。ガードが必要なのはまさにこれらであり、`unsafePerformIO`に見えるかどうかを調べる別のヒューリスティクスは要らない(下記「なぜ`unsafePerformIO`だけを検出しないのか」を参照)。
- **Phase 2(`toRCDefPostFold`/`annotateDef`)より前であり、後ではない。** `annotateDef`の`branchBody`呼び出しは、定義の本体全体を1つのトップレベルの所有権コンテキストとして扱う。ここに挿入すれば、`RC.idr`の`annotate`に素通しの節を1つ足すだけで済む。
  ```idris2
  annotate natives owned (RMemoize fc n rep body) =
      RMemoize fc n rep <$> annotate natives owned body
  ```
  `RMemoize`が包むのは常にCAFの本体全体なので、`body`の最終的な値をどう所有するかは、普通の関数の戻り値をどう所有するかと同じである。これは、包まれていない場合に`branchBody`/`annotate`がすでに計算している内容そのものである。シンク専用の所有権管理を新設する必要はない。`RMemoize`が自身のランタイム呼び出しに渡す値は、構造上、関数が直接返すはずだった単一参照の結果と同じものになる。

### 挿入基準

`Compiler.RC2.RC2.insertMemoize`は、`ConstFold`を通過した`(name, MkRCFun [] retRep isWorker body)`のすべてを`RMemoize fc name retRep body`で包む。ただし、`cafValueOf (MkRCFun [] retRep isWorker body)`が`Just _`を返す場合は包まない。

ここでは`ConstFold`の述語をそのまま再利用しており、「この形はすでに自明か」という別の判定は導出し直していない。`cafValueOf`の定義(`MkRCFun [] _ _ (RV _ cval)`で`cval`が定数と証明されたもの)は、「本体がコンパイル時定数への単なる参照になっている」という条件である。これは、この挿入基準が知りたい内容と同じである。

### なぜ`unsafePerformIO`だけを検出しないのか

`Lifted`/`RCExp`の段階には、「これは`unsafePerformIO`由来である」と区別できる目印がそもそもない。`unsafePerformIO`は、最後に`%World`トークンを捨てる普通の呼び出しの連鎖に脱糖されており、ほかの計算と区別がつかない。パターンに基づく検出器は、構文的な一致が起きない場所で同じバグを再発させる偽陰性の危険を負う。

そこで、ConstFoldを通過した定数でない引数なし定義を、無条件にすべてメモ化する。このほうが単純であり、かつ確実に安全である。純粋だが重いCAFの場合、参照ごとに安価なアトミック検査が1回増えるだけで、観測できる挙動は変わらない(参照透過性により、共有するか冗長に再計算するかは性能の問題にすぎない)。本物の副作用の場合には、これがまさに必要な修正になる。

`Compiler.RC2.RC2.collectLazyCAFs`/`isLazyCAF`には、この種の検出がすでにある(現時点では`dumprcexpr`のためだけに使われている)。`Compiler.RC2.LazyCaf`(上記「この設計の範囲」を参照)は、同じ「引数なしのトップレベル`Delay`」という形が必要になったとき、`isLazyCAF`を呼ばずに、同じ1節のマッチを自前で持つ形になった(`LazyCaf.idr`の`lazyCaf`)。両者は統合されていない。

## パイプラインの残りの部分への対応

`RCExp.idr`の汎用の構造再帰ヘルパーは、それぞれ`RMemoize`のための素通しの節が1つずつ必要である(このファイルが掲げる設計目標は「`RCExp`のコンストラクタを足すとき、更新を3箇所ではなく1箇所で済ませる」ことである)。

- `freeLocalsR (RMemoize _ _ _ body) = freeLocalsR body`
- `countUsesR l (RMemoize _ _ _ body) = countUsesR l body`
- `usedConstructorsR (RMemoize _ _ _ body) = usedConstructorsR body`
- `foldRCNamesR`の`go`も、同じように`body`へ素通しする。

`Reuse`、`ConAltNative`、`MutualLoop`、`DeadCode`、`DupMerge`は、変更が要らなかった。コンストラクタを追加したあとのビルドが通れば、網羅的な監査になると考えていた。Idris2のカバレッジチェッカは、全域でないパターンマッチをすべて指摘するからである。しかしこれが保証するのは、包括パターンを*持たない*マッチだけである。

`Sink`の`applySinkExp`とDualABIの`applyCallSiteRewriteBody`/`inlineFFIWorkersExp`は、最後が`_ = e`で終わる。そのためビルドは通ったが、メモ化された本体に対しては何もせずに素通りしていた。ネイティブな呼び出し箇所の書き換えも、FFIのインライン展開も、CAF内でのシンクも行われなかったのである。この問題は2026-09-25に、インライン展開によって`main`のIO本体全体が`__mainExpression`というCAFの中に入るようになったときに見つかった(`constructor-escape-analysis.md`)。現在は3つとも`RMemoize`を素通しするようになっており、`tests/Test89CafDualABI`がこれを検査する。

その次の段階(RCアノテーションの前に、呼び出し元が1つだけの呼び出し先を差し込む)では、CAFの本体にさらに多くのコードが入るようになり、同種の問題がさらに4件見つかった。

- `Compiler.RC2.Reuse`の`resolveReuse`。`annotate`が任せているフィールドの`dup`もここで挿入するため、これが漏れるとuse-after-freeになる(`refc-suite/clock`)。
- `Compiler.RC2.RC`の`nativeLocalsR`。
- 同じく`alwaysUnboxedBoxedLocalsR`。この2つが漏れると、ネイティブなローカルがBoxedとして扱われ、宣言されていないC変数を`drop`する(`refc-suite/doubles`)。
- `ConAltNative`の走査。

最初から素通しの節を1行足す必要があったファイルは2つある。1つは`Compiler.RC2.Loop`の`renameRCExp`である。自己末尾呼び出しをリネームするこの走査は`RCExp`に対して網羅的だが、実際には`RMemoize`がここに届くことはない。引数なしのCAFにはループで持ち回すパラメータがなく、`applyLoop`が適用されないからである。もう1つは`Pretty.idr`の`prettyExp`(`dumprcexpr`の表示処理)である。

### 制限

メモ化された本体の末尾は、関数の末尾ではない。値はメモのスロットに保存されてから返されるので、そこでの呼び出しを末尾呼び出し(クロージャやトランポリンへの遅延)として扱ってはならない。末尾位置を区別するパスは、「末尾ではない」として`RMemoize`の中に降りる必要がある。DualABIの`applyCallSiteRewriteBody`はそうしている。また、アノテーションより後のパスで包括的な節を持つものには、`RMemoize`の節を明示的に書く必要がある。カバレッジチェッカは、その節を求めてくれないからである。

`LateInline`が別の本体の中へ移した`RMemoize`にしか出会わないヘルパーは、それを安全に読み飛ばせる。移された本体はCAFのものなので閉じており、移し先の本体のローカル変数を読むことがないからである。Sinkの使用走査とdrop走査、DualABIの末尾解析、DupMergeの領域ヘルパー、ConAltNativeの枝ごとのヘルパーは、この性質に依拠している。ただし、定義全体を走査するパスは、すべてのCAFの先頭で`RMemoize`に出会うので、その節が必要である。

`RMemoize`は移動してもよいが、コピーしてはならない。メモのスロットは、CAFの名前を付けたCの`static`変数(`idris2rc2_memo_<name>`)である。そのため、どこへ移っても1つだけであり、評価も1回だけになる。`LateInline`が呼び出し元が1つだけのCAFをその呼び出し元に差し込むのは移動にあたり、idris2-lspでは426件中156件がこの形で移動している。一方、コピーして2つにすると、静的変数が別々に2つできてしまう(2つの関数、あるいは1つの関数の2つのブロックに置かれる)。その場合は本体が2回評価される。`insertMemoize`の後で、`RMemoize`を含みうるコードをコピーするパスは、現時点ではない。`LateInline`が差し込むのは呼び出し元が1つだけの呼び出し先に限られ、`Sink`がコピーするのは単一のノードだけだからである。

`insertMemoize`より前にCAFを差し込んではならない。本体がラップされないまま差し込まれ、呼び出し元が実行されるたびに1回ずつ評価されてしまう。そのため、RCアノテーション前の早い段階の`LateInline`(`RC2.idr`の「Early inline」)は`inlineCafs = False`で実行する。

## Emit側のCコード生成

ランタイムに新しいファイルの組`rc2/support/rc2/caf_memoize.h`/`.c`を追加した(生成コードの親ヘッダ`idris2rc2_runtime.h`からincludeされる)。この設計の出発点にした手書きのスケッチには、ランタイムレベルのバグが2つあった。それを次のように修正している。

1. **「計算済み」フラグと「グローバルなクリーンアップリストの次のノード」へのリンクは、別々の2つのフィールドにする。** 両方の役目を1つの`next`ポインタに共有させてはいけない。共有すると、最初にメモ化されたCAFのフラグ用フィールドが、空の`head`リストにつながれた時点で`NULL`になる。これは「未計算」と区別がつかず、まさにその1つのCAFについてだけ、保証が気づかないうちに崩れる。
2. **「ほかのスレッドの最初の計算を待つ」スピン待ちには、`rc2/support/rc2/util.h`の`idris2rc2_spin_lock`がすでに確立している、このコードベースのスピンの書き方(`atomic_flag`/`_Atomic bool`)を使う。** 手書きのCASループにはしない。グローバルなクリーンアップリストの先頭(`caf_memoize.c`の`idris2rc2_memo_boxed_cleanupHead`)は本当に`_Atomic`であり、本物のTreiberスタックのCASリトライループでpushする。

実際のAPI(`caf_memoize.h`)は次のとおりである。

```c
typedef struct idris2rc2_memo_boxed {
  atomic_flag claimed;
  _Atomic bool done;
  IDRIS2RC2_Value *value;
  struct idris2rc2_memo_boxed *cleanup_next; // written once, before publish -- see caf_memoize.c
} idris2rc2_memo_boxed;

bool idris2rc2_memo_boxed_claim(idris2rc2_memo_boxed *memo);      // true: you must compute + store
void idris2rc2_memo_boxed_store(idris2rc2_memo_boxed *memo, IDRIS2RC2_Value *value);
IDRIS2RC2_Value *idris2rc2_memo_boxed_wait(idris2rc2_memo_boxed *memo, const char *name); // spins, then dups
void idris2rc2_memo_boxed_dropAll(void);                          // idris2rc2_rtFinish only
```

`Emit.idr`の`emitMemoizeInto`は、`RMemoize`を次のように下ろす。

```c
static idris2rc2_memo_boxed idris2rc2_memo_<cName n> = IDRIS2RC2_MEMO_BOXED_INIT;
IDRIS2RC2_Value *result;
if (idris2rc2_memo_boxed_claim(&idris2rc2_memo_<cName n>)) {
    <body's own statements, forced into a fresh SinkVar bodyVar>
    idris2rc2_memo_boxed_store(&idris2rc2_memo_<cName n>, bodyVar);
    result = bodyVar;
} else {
    result = idris2rc2_memo_boxed_wait(&idris2rc2_memo_<cName n>, "<Idris name>");
}
<result finalized into whatever this RMemoize's own real sink/tailPosition wants>
```

`body`は、`RMemoize`自身の`sink`へ直接出力せず、必ず強制的に作った`SinkVar`へ出力する。値をどこかへ渡す前に、`idris2rc2_memo_boxed_store`の呼び出しのためにここで読み戻す必要があるからである。`SinkReturn`のシンクでは、それができない。

**ネイティブ(アンボックス)の`RMemoize`は実装していない。中途半端に作ったのではなく、到達不能であることを確認した。** `rep`は常に外側の`MkRCFun`の`retRep`のコピーであり、`Compiler.RC2.RC`の`normalizeDef`(Phase 1)は、すべての通常の定義で`retRep = RBoxed`と固定している。これは推測ではなく、直接確認した。ネイティブな`retRep`が導入されるのは`Compiler.RC2.DualABI`のワーカー合成だけだが、そこで作られるのは元のラッパーとは*別の*定義であり、しかも`insertMemoize`が実行されたあとである(`ConstFold -> insertMemoize -> Phase 2 -> ... -> DualABI`)。

実装しない理由はもう1つあり、前の理由とは独立している。`Sink`の`SinkVar`(`Emit/Util.idr`)は常に`IDRIS2RC2_Value *`を宣言する。ネイティブな値を中間変数へ強制的に入れるシンクの形は存在しないので、本物のネイティブ`RMemoize`を作るなら、まずそれを用意しなければならない。`emitMemoizeInto`の`RNative`/`RInlineNative`の場合は、検証できないコードを出力する代わりに`InternalError`を投げる。

静的変数の名前は、`RMemoize`の`Name`フィールドから既存の`cName`マングルで導く。別のカウンタや割り当て方式は使わない。

## ランタイムのライフサイクル

`idris2rc2_rtFinish`(`runtime.c`、`doc/runtime-lifecycle.md`)は`idris2rc2_memo_boxed_dropAll`を呼ぶ。追加したのはこの呼び出しだけで、ライフサイクルのフックを新設したわけではない。

## 自分自身に依存するCAF

メモを獲得したスレッドは、そのメモに自分自身を記録する(`owner`。スレッドローカル変数のアドレスである)。待機しようとして、そこに自分のスレッドが記録されていた場合、そのCAFは評価に自分自身の値を必要としている。`x = x + 1`がその例であり、`LazyCaf`によってCAFになったあとに自分自身をforceするトップレベルの`Delay`(`lazy-memoization.md`)も同じである。このまま待てば、自分自身を永久に待ち続ける。

この場合は、stderrに値の名前を示して"idris2rc2: the top-level value <name> depends on itself"と出力し、終了ステータス1で停止する(`idris2rc2_memo_cycle`)。ほかのスレッドが評価中のメモに対する待機は、従来どおり待ち続ける。`rc2/tests/Test126LazySelfForce`がこれを検査する。

## インクリメンタルコンパイル

Cの`static`変数は内部リンケージを持つので、2つのモジュールがメモ変数に同じ名前を独立に付けても、モジュール間でシンボルが衝突する危険はない(そもそも名前は`Name`から導出するので、異なる2つのトップレベル定義が同じマングル名を持つことはなく、この心配は意味を持たない)。

`ConstFold`の`foldConstProgram`は、`toRCDefs`の`incremental`フラグに関係なく実行される(`preFolded`の構築だけがフラグで分岐する)。`insertMemoize`はパイプライン上の同じ位置に置いてあり、インクリメンタル専用の処理は要らない。1つのモジュールの部分的な`toIR`の範囲だけを前提にしても正しく動く。これは`ConstFold`自身がすでに受け入れている制約と同じである。

## 残っている既知のエッジケース(優先度低)

CAFの計算が、完了する前に同じスレッドで自分自身へ到達する場合(ほかのCAFを介した直接再帰や相互再帰を含む)は、`idris2rc2_memo_cycle`が検出する(「自分自身に依存するCAF」を参照)。循環がほかのスレッドを経由する場合は、やはりデッドロックする(スピン待ちが「done」を永久に見られない)。検査が比較するのは、待機するスレッドとメモを獲得したスレッドだけだからである。

これは新たに導入された故障モードではない。遅延されていない、本当に循環したトップレベル値の参照は、この設計の前から未定義であり、発散していた。ここではこれ以上追求しない。

## 検証

`rc2/tests/Test86CafMemoization/`は、`TODO.md`にかつて載っていた例をそのまま再現する。`unsafePerformIO (newIORef 0)`で作った`IORef`を3回読み出してインクリメントする例で、結果は`--cg chez`と同じ`0 1 2`である。以前は`0 0 0`を出力していた(`--cg rc2`と本家の`--cg refc`の両方で確認した)。

このテストは、`verify.sh`の`NO_REFC_DIFF_TESTS`に登録してある。本物のRefCには元のバグが残っており、diffを取る共通のベースラインがないためである。また`LEAK_SENSITIVE_TESTS`にも登録してある。メモが保持する永続的な参照は、`valgrind`で確認する価値のあるまさにその種のものであり、結果はdefinitely lostが0バイトだった。

この変更を入れた状態で、`verify.sh`全体(`refc-suite` 21/21、すべてのスモークテスト、すべての`valgrind`)が問題なく通っている。ただし`refc-suite/callingConvention`のゴールデンスナップショット`expected`だけは、一度再生成した。無害な`tmp_N`/`var_N`の番号のずれを吸収するためである。`insertMemoize`が、プログラム内のほかのすべてのCAFが一時変数のカウンタ値を得るより前に実行されるようになったことで生じたずれで、このスイートの過去にも、全プログラムを対象とするパスを前に挿入するたびに起きた、同種の無害なずれである。再生成の前にdiffを読んで確認したところ、ロジックは同一で、変数名の番号が振り直されただけだった。
