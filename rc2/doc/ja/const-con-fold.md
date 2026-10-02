# 定数コンストラクタの畳み込み(`RCConstCon`)

(原文: `doc/const-con-fold.md`。内容が乖離した場合は原文を正とする。)

フィールドが、再帰的にすべてコンパイル時定数であるコンストラクタ(`[1,2,3,4,5]`、`Just 42`、CAFの本体全体)は、このパスができるまで、評価のたびに新しいヒープ割り当てとして再構築されていた。たとえば`Main.constList`は、値が決して変わらないのに、読まれるたびに5つの`Cons`セルを割り当てていた。`Compiler.RC2.ConstFold`は、算術、比較、定数に対するcaseをすでに畳み込んでいたが、`RCon`自体は畳み込んでいなかった。

本書は、設計と、構築中に見つけて修正した2つのバグを扱う。設計の中心は、`RCLocal`の新しい`RCConstCon`ケースである。これは畳み込まれ、不死(immortal)のファイルスコープstaticとしてステージングされる。2つのバグのうち、1つは畳み込みを黙って無効にしており、もう1つは実際のメモリリークだった。

## 設計

### `RCLocal`の新しい定数形式

`RCExp.idr`は、既存の`RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon`に並べて、5つ目の`RCLocal`ケースを追加する。

```idris2
RCConstCon : Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> RCLocal
```

不変条件: `args`のすべての要素は、それ自身がこの5つの定数形式のいずれかである(再帰的に成り立つ)。素の`RCLoc`が現れることはない。この不変条件は`Compiler.RC2.ConstFold`だけが保つ。これが唯一の生成元だからである。

### 畳み込み(`Compiler.RC2.ConstFold`)

`foldConst`は、算術を`RPrimVal`に畳み込むのと同じやり方で、`RCon`を畳み込む。すべてのフィールドが定数形式に解決できる場合(直接解決できる場合と、`env`経由で解決できる場合の両方を含む)、`RCon`全体が`RV fc (RCConstCon ...)`になる。`env`は、このパスがすでに定数だと証明した変数の表であり、以前は単なる`Constant`の表だったが、今は`SortedMap Int RCLocal`として追跡する。外側の`RLet`のケースは、`RV`の`RCConstCon`という畳み込み結果を、畳み込まれた`RPrimVal`と同じように扱う。`env`に挿入し、`body`のどこにもその変数への参照が残らなくなったら、その`RLet`を完全に取り除く。

設計上の要点が2つある。

- **`reuseFrom`を持つ構築は畳み込まない。** すでに再利用の確保を主張している`RCon`は、動的なまま残す(`Compiler.RC2.Reuse`はPhase 1/2の後に走るので、Phase 2より前にこれが起きることは実際にはない。ただし、パターンマッチは`reuseFrom = Nothing`の場合にしか一致しない)。畳み込むと、確保が意味を失うからである。
- **引数0個の`RCon`は除外する。** NIL/NOTHING/ZERO/UNITは、`RCon`自身の`emitRC`のケースに到達する前に、すでに専用の`RCNull`の経路をたどる。そのため、本当に引数が0個の`RCon`がこのパスに届くと、ステージングされたstaticに長さ0のC配列が必要になる。素のCではこれは許されない(理論上の話にとどまらず、実際に問題になった理由は「見つかったバグ #1」を参照)。

**部分的な畳み込み**: すべてのフィールドが解決できたわけではない`RCon`は、動的なまま残る。ただし、解決できたフィールドは、すべてその場で書き換える。たとえば`partialConst x = x :: constList`は、`x`のための本物の実行時`Cons`の割り当てを残す。しかし2番目のフィールドは、すでにステージングされた`constList`のstaticを直接参照する。死んだ変数を読み直すことはない。

**`RCLocal`のオペランドを持つほかのすべてのノード**(`RAppName`、`RApp`、`RUnderApp`、`RExtPrim`、`RStructGet`/`RStructSet`、`ROp`、`RCmpCase`)も、今ではオペランドを`env`に対して解決する。これらのノードは、どれも自分自身の値には畳み込まれない。それでも、この処理は省略できない(「見つかったバグ #1」を参照)。

### ステージング(`Compiler.RC2.Emit.Util`)

既存の`ConstDef`の仕組み(`boxedConstExpr`、`Emit/Util.idr:637`)をほぼそのまま写している。新しい`ConstConDef`の状態は、名前による重複排除のための`SortedMap RCLocal String`と、ステージング順に並べた完成した定義テキストのリストの組である。この状態を、新しい`boxedConstConExpr`が参照する。`RCConstCon`をステージングするときは、ネストした`RCConstCon`のフィールドを、先に再帰的にステージングする。そのため、子は必ず親より前に定義リストへ入る。これは、Cのstaticの初期化子が、*すでに宣言された* staticのアドレスしか取れないために必要である(ファイルスコープでは前方参照ができない)。

ステージングされるCの形は、`IDRIS2RC2_Constructor`自身のレイアウト(`constructor-layout.md`)をフィールド単位でそのまま写している。違いは、可変長配列メンバではなく固定サイズの配列にしている点である(素のCには、可変長配列メンバに対するstaticの初期化子がない)。タグなしのコンストラクタには、名前を入れるためのスロットがもう1つ付く。

```c
static IDRIS2RC2_ConstConstructor2 const constcon_7 = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CONSTRUCTOR),
    2, 1,
    { (IDRIS2RC2_Value*)(&idris2rc2_smallInt64[5]), NULL }
};
```

`IDRIS2RC2_STOCKVAL`は、小さな整数のキャッシュや`ConstDef`の値がすでに使っている、不死の参照カウントのマーカー(`IDRIS2RC2_REFCOUNT_MAX`)と同じものである。**このおかげで、コンパイラのそれ以外の所有権解析(`Compiler.RC2.RC`の`annotate`)には、変更がまったく要らない。** `idris2rc2_dup`/`idris2rc2_drop`には`REFCOUNT_MAX`のガードがすでにあり、ステージングされた値に対するdup/dropは、実行時には何もしない。したがってannotateは、通常のBoxedな値に対して生成するのと同じdup/dropの呼び出しを、そのまま生成し続けてよい。

ただし、`annotate`が内部で使う補助関数のうち3つ(`RC.idr`の`splitBorrows`、`dropIfLastUse`、`boxedOperands`)は、dup/dropの呼び出しを出力する以外の目的でも、オペランドがboxedかどうかを*分類*している。たとえば、ある使用にdupが要るかどうかの判断や、`ROp`などの`postDrop`リストの決定である。これらには、既存の`RCConst`/`RCNull`/`RCEmptyCon`のケースと並べて、`RCConstCon`の明示的なケースが必要だった。理由は同じで、不死の値は、所有している変数や借用している変数のように追跡する必要がないからである。`Compiler.RC2.Sink`/`Compiler.RC2.DualABI`の、並行して存在する`localRepIn`補助関数にも、同じ1行の追加が必要だった(`RCEmptyCon`と同じく、常に`RBoxed`とする)。

## 見つかったバグ

### #1: 畳み込みがほとんど働いていなかった

最初に動いた版は、`RLet fc var rep (RCon ...) body`という形にしか一致しなかった。つまり、`RLet`の値が*直接* `RCon`である場合だけである。これでは、2つの形を取りこぼす。この2つは例外ではなく、むしろ普通の形だった。

- **ANFの`RLet`の連鎖は、フラットにならず、ネストする。** `[1,2,3,4,5]`は、`RLet v0 (Cons 5 Nil) (RLet v1 (Cons 4 v0) (... RLet v4 (Cons 1 v3) (RV v4)))`に正規化される。外側から読むと、`v0`の値は素の`RCon`だが、`v0`自身の*本体*は`RCon`ではなく、別の`RLet`である。直接一致する版は、いちばん内側のセルしか畳み込まず、`value`が`RCon`ではなく`RLet`だとわかった時点で諦めた。**修正**: 先に`value`を(再帰的に)畳み込み、そのあとで*元の* `value`の形に一致させるのではなく、*畳み込みの結果*を分類する。`RPrimVal`と、`RV`の`RCConstCon`は、どちらも「今は既知の定数である」ことを意味する。
- **畳み込まれた変数の、木のほかの場所での使用が、書き換えられていなかった。** 既存の算術の畳み込みの`env`は、`ROp`/`RCmpCase`/`RConstCase`からしか参照されず、畳み込み結果を*計算する*ためだけに使われていた。ノード自身の`args`を、その場で書き換えることはなかった。算術では、それで問題がなかった。畳み込みに失敗した`ROp`は、同じ`args`をそのまま出力し直すだけで、失われる情報がなかったからである。しかし`RLet`の、「`body`がもうその変数を参照しないなら、この束縛を捨てる」という検査(`contains (RCLoc var) (freeLocalsR body')`)は、それらの`args`が実際に書き換えられることを前提にしている。たとえば`RAppName`の引数リストの中に未解決の`RCLoc`が残っていると、その変数は「まだ使われている」ように見え続ける。すると、`RLet`(とそれが守る割り当て)が、永久に畳み込まれなくなる。**修正**: `RCLocal`のオペランドを持つすべてのノード(`RAppName`、`RApp`、`RUnderApp`、`RExtPrim`、`RStructGet`/`RStructSet`、および`ROp`/`RCmpCase`自身の`args`)も、`env`に対してオペランドを解決するようにした。目的は、`freeLocalsR`が置き換えを見られるようにすることだけである。この処理で、これらのノードが自分自身の値に畳み込まれることはない。

発見は、修正の前後の`--directive dumprcexpr`の出力を比べて行った。`Main.constMaybe`(本体全体が1つの`RCon`で、`RLet`のラッパが一切ないCAF)は、最初から正しく畳み込まれた。`Main.constList`(上記の`RLet`の連鎖の形)と、`Main.main`の中のすべての使用(`printLn constList`など。必ず`RLet`の連鎖を通って到達する)は、2つの修正が両方入るまで、まったく畳み込まれなかった。

### #2: ネイティブ対象でない定数を`env`から差し込むとメモリリークした

修正 #1によって`args`が実際にその場で書き換えられるようになると、2つ目の、より深刻なバグが現れた。`printLn (Just 42)`で、`42`がデフォルトの`Integer`(`BI`、GMP裏打ち)になる場合に、実行ごとに24+16バイトがリークした(`idris2rc2_mkIntegerLiteral`から`idris2rc2_mkInteger`、`aligned_alloc`へと続く経路。valgrindで確認し、同じ再現コードで、このブランチ以前のベースラインにはリークがないことも確認した)。

根本原因は次のとおり。`RC.idr`の`bindOne`には、`RCConst`を生成するのは、`litRep`が対象にする(ネイティブ対象の)`Constant`だけだ、という不変条件が文書化されている。`BI`/`Str`は、常に本物の`RCLoc`の背後に残る。これは、`Compiler.RC2.RC`の`annotate`が、それらの所有権を通常どおり追跡し続けるためである。`annotate`の`isBoxedOperand`/`splitBorrows`/`dropIfLastUse`は、**どの** `RCConst`も、無条件で非Boxedとして扱う(この不変条件のもとでは正しい。ネイティブのスカラーには、参照カウント操作が要らない)。ところが`ConstFold`の`RLet`のケースは、畳み込まれた*あらゆる* `RPrimVal`について`(var, RCConst c)`を`env`に挿入し、その`env`のエントリを、ほかのノードの`args`に差し込み始めた(修正 #1)。これがこの不変条件を壊した。`BI`(や`Str`)の定数が、素の`RCConst`のオペランドとして`annotate`に届き、「dropは不要」と分類されてしまう。その背後にある本物のヒープ割り当て(`idris2rc2_mkIntegerLiteral`の`mpz_t`)が、リークした。

**修正**: `env`に、`RPrimVal`で畳み込まれたエントリを追加するのは、`litRep c`が`Just _`(ネイティブ対象)の場合だけにした。畳み込まれた`BI`/`Str`の定数は、`bindOne`の不変条件がもともと求めているとおり、`RLet`(とほかの場所での`RCLoc`の使用)を保つ。`asConstLocal`(`RCon`のフィールドが、`RCConstCon`に畳み込めるほど「十分に定数」かを判定する)には、同じ根本的な理由による、しかし仕組みが異なる2つ目の独立した除外がある。具体的には`RCConst (BI _)`である。即値の範囲を超える`BI`のCへの出力(`idris2rc2_mkIntegerLiteral`)は、本物の関数呼び出しであり、staticの初期化子が保持できるコンパイル時の定数式には決してならない。リークを別にしても、これは除外する必要がある。

2つの除外は、それぞれ独立に必要である。`env`への登録のガード(上記)は`annotate`の所有権の追跡を守り、`asConstLocal`の`BI`の除外はC出力の段階を守る。片方だけを残してもう片方を外すと、最適化が劣化するだけでなく、本物のバグがまた現れる。

発見の経緯は次のとおり。拡張した回帰テストをゼロからvalgrindにかけたところ、存在するはずのないリークが報告された。`git stash`でこのブランチ以前のベースラインと比べて二分探索した(`f x = x + 1; main = printLn (f 100)`。`RCConstCon`はまったく関係しない)。その結果、このリークが新しく入ったものであると確認できた。さらに、`ConstFold.idr`に一時的に`Debug.Trace`を入れて、どの`RLet`が`RCLoc`を失っているかを突き止めた。

## スコープと制限(MVP)

**以下の2つの制限は、今ではどちらも解決済みである。** `rc2/doc/const-caf-fold.md`を参照する。CAFの境界をまたぐ制限は、プログラム全体の`CafTable`の不動点ループが解消する。2つ目の制限は、`RConCase`のスクルティニーを解決する仕組みが解消する。以下は、その後の拡張が入る前の畳み込みがどうなっていたかという、歴史的な経緯のために、書かれたままで残してある。

- **ほかのトップレベルCAFを通した畳み込みはしない。** 別のCAFを参照する`RAppName`は、そのCAFの本体が完全に畳み込まれる場合でも、決して定数として扱われない。扱うには、プログラム全体の依存関係の解決(2つのCAFが互いを参照する場合に、どちらを先に畳み込むか)が必要になる。このパスは、それをまだ意図的に試みていない。畳み込まれるのは、*1つの定義の本体の中*にある、リテラルのコンストラクタのネストだけである。
- **`RConCase`/`RConstCase`のスクルティニー(`sc`)は解決しない。** `sc`が、畳み込まれた`RCConstCon`だと証明できる場合でも、このパスは、一致する分岐を静的に選ぼうとしない。`sc`は`RCLoc`の参照(あるいはもともとの形)のままである。そのため、既知の定数のスクルティニーに対するcaseは、完全に畳み込まれて消えることなく、本物の実行時ディスパッチにコンパイルされる。`RCon`の`emitRC`のケースと、`Compiler.RC2.Reuse`の確保のロジックは、どちらも今のところ、スクルティニーを本物のヒープ上の`RCLoc`としてしか理解しない。ここで`sc`を解決するなら、それらの利用側にも、`RCConstCon`のスクルティニーを扱えるように教える必要がある。それはこのパスの範囲外である。

## ファイル

- `rc2/src/Compiler/RC2/RCExp.idr`: `RCLocal`の新しい`RCConstCon`のケース、`Eq`/`Ord`/`Show`のインスタンス(`List`を通して自分自身を参照するコンストラクタが、全域性検査の対象に入ったので、3つとも`covering`の注釈が必要になった。インスタンスの見出しを参照)。
- `rc2/src/Compiler/RC2/ConstFold.idr`: 畳み込みそのもの(`RLet`で拡張した`case value' of`、単独の`RCon`のケース、`RAppName`などのオペランド解決のケース)、`asConstLocal`の`BI`の除外。
- `rc2/src/Compiler/RC2/Emit/Util.idr`: `ConstConDef`の状態、`boxedConstConExpr`/`constConFieldExpr`、`RCLocal`を受け取る補助関数(`varName`/`repOfLocal`/`inlineExprFor`)に追加した`RCConstCon`のケース。
- `rc2/src/Compiler/RC2/Emit.idr`: `header`関数のstatic定義リストの出力。
- `rc2/src/Compiler/RC2/RC.idr`: `annotate`の`splitBorrows`/`dropIfLastUse`/`isBoxedOperand`/`(RV fc v)`のケースを拡張し、`RCConstCon`を不死として扱う(dup/dropを追跡する必要がない)ようにした。
- `rc2/src/Compiler/RC2/Sink.idr`、`rc2/src/Compiler/RC2/DualABI.idr`: `localRepIn`の`RCConstCon`のケース(常に`RBoxed`)。
- `rc2/support/rc2/datatypes.h`: `IDRIS2RC2_Constructor`のレイアウト(参照するだけで、変更していない)と、`IDRIS2RC2_STOCKVAL`/`IDRIS2RC2_REFCOUNT_MAX`(そのまま再利用)。
- `rc2/tests/Test17ConstFold.idr`: 回帰テスト(そのファイルの末尾に統合した)。完全な畳み込み(`constList`/`constMaybe`/`nestedConst`)、部分的な畳み込み(`partialConst`)、同じ不死の値を複数の箇所で分解するケース(`headOf`/`tailOf`/`unwrapMaybe`。それぞれ複数回呼ぶ)を含む。最後のケースは、dup/dropが何もしないという安全性の性質を直接検査する。
- `rc2/tests/BenchConstConFold.idr`: 定数の10要素のリストを300万回合計する。畳み込みを元に戻した同じrc2のビルドより約3.4倍速く、本物のRefCより約4.5倍速い。

## 検証手順(拡張する場合)

1. 再現コードに`--directive dumprcexpr`(`rc2/doc/reading-the-ir.md`を参照)を付けると、`RCConstCon`の値が`#Name@tag(args)`の形で表示される(`Show RCLocal`自身の表示)。生成されたCを見る前に、ある定義が完全に畳み込まれたか、部分的か、まったく畳み込まれなかったかを確認する、いちばん速い方法である。
2. 生成されたC自身のstatic定義の節を読む(`.c`の出力で`constcon_`をgrepする)。依存関係の順序(子が親より前)と、`IDRIS2RC2_STOCKVAL`が、いちばん外側だけでなく、ステージングされたすべての値にあることを確認する。
3. **畳み込み対象の`Constant`のケース(あるいはノード)を、`env`から差し込むものに増やすときは、必ず、ゼロから作った再現コードをvalgrindにかけること。** 上記のバグ #2が示すとおり、失敗の形は、クラッシュでも誤った答えでもなく、黙ったリークである。通常の出力のdiffには現れない。リークの出所が自明でない場合は、変更前のビルドと比べて二分探索する(ソースの変更を`git stash`し、再ビルドして、同じ再現コードをもう一度実行する)。このパスを拡張している最中に見つけたリークを、確認せずに、以前からあったものだと決めつけるわけにはいかない。
4. 将来、`RConCase`/`RConstCase`の`sc`を`env`に対して解決する場合(上記のスコープの制限を外す場合)、`Compiler.RC2.Reuse`と`Emit.idr`の`emitConCaseInto`/`emitConstCaseInto`は、どちらも現状では、スクルティニーを本物のヒープ上の`RCLoc`だと仮定している。畳み込みそのものだけでなく、この両方を監査してから制限を緩めること。
