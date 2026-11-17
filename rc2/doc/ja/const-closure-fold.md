# 定数クロージャの畳み込み(`RCConstPartial`)

(原文: `doc/const-closure-fold.md`。内容が乖離した場合は原文を正とする。)

この文書が扱う、捕捉を持たないクロージャは`RCConstPartial n missing []`である。これは、定数を捕捉するクロージャ(最後の節)と統合されるまでは、独自のコンストラクタ(`RCConstClosure`)だった。staticは`constclosure_N`という名前のままで、ダンプでは`~closure`と表示される。

インターフェース辞書の形をしたCAFとは、メソッドごとに1つのクロージャを持つレコードで、各クロージャは名前付きのトップレベル関数を、引数を何も埋めずに部分適用しただけのものである。このパスができる前は、これを呼び出しのたびに一から組み立て直していた。6メソッドの辞書なら、`idris2rc2_mkClosure`の新規確保が6回と、`IDRIS2RC2_Constructor`の新規確保が1回かかり、結果はメモ化されなかった(rc2には、CAFを共有する独自の仕組みがない)。

この文書は、`Compiler.RC2.ConstFold`にすでにある`RCConstCon`の畳み込み(`rc2/doc/const-con-fold.md`)を、このような辞書の内部にまで届かせる拡張を扱う。拡張により、辞書全体を1つの不死のstaticにまとめられる。あわせて、この拡張によって見つかった正当性上の実際のギャップと、関連する既存のバグも扱う。

## 設計

### `RCLocal`の新しい定数の形

`RCExp.idr`は、`RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon`/`RCConstCon`に加えて、6つ目の`RCLocal`のケースを追加する。

```idris2
RCConstPartial : Name -> (missing : Nat) -> (caps : List RCLocal) -> RCLocal
```

この文書が扱う形では、`caps`は空である(`RCConstPartial n missing []`)。`RCConstCon`と違い、これは真の葉である。引数を何も埋めていないクロージャは、捕捉した引数をまったく持たないので、再帰してたどるべき入れ子がない。(捕捉した値が定数で`caps`が空でないクロージャは、最後の節で扱う。)

`IsConstPartialLocal`は、専用の狭いウィットネス型である(`RCConstCon`に対する`IsConstLocal`と同じ考え方で作った)。`IsAnyConstLocal`は5つ目のコンストラクタ`ItIsConstPartial2`を持つ。このため、`RCConstPartial`に畳み込まれた辞書のフィールドは、`RCConstCon`が自身のフィールドにすでに課している`All IsAnyConstLocal args`の義務を、同じように満たす。`RCConstPartial`を構築するのは、`Compiler.RC2.ConstFold`だけである。

### 畳み込み(`Compiler.RC2.ConstFold`)

畳み込みは、`foldConst`の節1つ(`ConstFold.idr:419`)である。この節が、リテラルで引数が0個の`RUnderApp`を、定数として`RV`に変換する。

```idris2
foldConst _ env (RUnderApp fc n missing []) = RV fc (RCConstPartial n missing [])
```

この`RV`に畳み込まれた値を持つ`RLet`は、続いて`RV _ cval@(RCConstPartial {})`のアーム(`ConstFold.idr:328-332`。全体は後述の「ギャップ: `let`による再束縛 ...」の節に示す)で分類される。このアームは、定数を`env`に挿入し、`body`がその変数をもう参照しなければ`RLet`を取り除く。`RUnderApp`そのものに一致する`RLet`のアームはない。`RLet`が`value'`を見る時点で、`RUnderApp`の節がすでにそれを畳み込んでいるからである。

引数リストがリテラルに空であるというマッチ(`RUnderApp fc n missing []`)が、2つを区別する。1つは畳み込んでよい、`n`への素の参照である。もう1つは畳み込めない部分適用で、動的な値かもしれないものを捕捉する(`RUnderApp fc n missing (x :: xs)`)。後者は`foldConst`の次の節に落ちて、捕捉した引数だけが解決された`RUnderApp`のまま残るので、`RLet`は本物のまま残る。引数が0個の`RUnderApp`の中には、非定数になりうるものが何もない。

この節1つと、`RV`のアーム、`RCConstPartial`を`IsAnyConstLocal`として認識する`isConstLocalProof`のケースを除けば、**`ConstFold.idr`のほかのコードは変わっていない**。`RCon`自身の畳み込みのケース(`ConstFold.idr:390-396`。コンストラクタの解決済みの`args`に対する`allConstLocal`)も、変更していない。このケースがもともと気にしているのは、各フィールドが`IsAnyConstLocal`を満たすかどうかだけである。5つ(今は6つ)ある定数の形のどれであるかは問わない。

インターフェース辞書は、構造上は単なる`RCon`であり、そのすべてのフィールドが、たまたま`RCConst`/`RCEmptyCon`ではなく`RCConstPartial`に解決されたものである。既存の仕組みは、定義をまたぐ新しい解析をまったく足さずに、これを`RCConstCon`に畳み込む。`[1,2,3,4,5]`や`Just 42`をすでに畳み込んでいるのと、まったく同じ方法である。

### ステージング(`Compiler.RC2.Emit.Util`)

新しい`boxedConstPartialExpr`(`Emit/Util.idr:809-826`)は、`RCConstPartial`を最初に見たときにstaticとしてステージングし、以後の参照では、ステージング済みのstaticへの参照を返す。重複の除去には、`boxedConstConExpr`がすでに使っているのと同じ`ConstConDef`の状態を使う。`Eq`/`Ord RCLocal`が`RCConstPartial`もカバーするようになった(この変更で両方を拡張した)ので、同じ`(Name, missing)`の組に畳み込まれる2つの辞書フィールドは、自動的に同じマップのキーに衝突する。別の重複除去用のテーブルは要らない。

`boxedConstConExpr`より単純である。引数を何も埋めていないクロージャには、再帰的にステージングすべき捕捉済みの引数がないので、あちらの関数の`All`で添字付けされた仕掛けは、ここでは要らない。

ステージングしたCの形は、staticな構造体リテラルである。

```c
static struct { IDRIS2RC2_Header header; void *fn; uint8_t arity; uint8_t filled; }
    const constclosure_7 = { IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CLOSURE), (IDRIS2RC2_Value *(*)())Main_greet_Dog, 1, 0 };
```

これは、`IDRIS2RC2_Closure`の本当のレイアウトを完全に写したものでは、意図的に**ない**。`idris2rc2_datatypes.h`の実際の構造体は次のとおりである。

```c
typedef struct {
  IDRIS2RC2_Header header;
  void *fn;
  uint8_t arity;
  uint8_t filled;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Closure;
```

末尾は柔軟配列メンバである。素のCには、柔軟配列メンバに対するstaticな初期化子の構文がない。そもそも、初期化すべき要素もない。ここでは構造上`filled`が常に`0`だからである(これは、引数が0個のリテラルな`RUnderApp`からしか生じない)。

ステージングした型は、先頭の`header; fn; arity; filled`というメンバの並びだけを共有し、配列は完全に省いている。これで問題がないのは、次の2つが成り立つからである。

- `filled == 0`のとき、`i < filled`の範囲の`->args[i]`を読むものがない。
- このstaticに対して`sizeof(IDRIS2RC2_Closure)`を計算するものがない(このstaticはヒープに確保されることがなく、本当の柔軟配列メンバのレイアウトを前提とするものに渡されることもない)。

特に、`idris2rc2_isUnique`/`idris2rc2_tailcallApplyClosure`のインプレース成長の分岐(`args[filled]`に書き込むことになる)が、不死(`REFCOUNT_MAX`)のヘッダに対して実行されることはありえない。`idris2rc2_isUnique`は、`refCount == 1`を素で検査するだけだからである。

`IDRIS2RC2_STOCKVAL`は、`RCConstCon`自身のステージング済みのstatic、小整数キャッシュ、`ConstDef`の値がすでに使っているのと同じ、不死の参照カウントの印(`IDRIS2RC2_REFCOUNT_MAX`)である。所有権解析(`Compiler.RC2.RC`の`annotate`)は、自身に変更を加える必要がない。必要なのは、`RCConstPartial`を不死として扱う変更を、`RCConstCon`のために1行ずつ追加が必要だった少数の分類用ヘルパーに入れることだけである(`RC.idr`の`splitBorrows`/`dropIfLastUse`/`isBoxedOperand`と、`Util.idr`の`localRepIn`)。`idris2rc2_dup`/`idris2rc2_drop`自身が持つ`REFCOUNT_MAX`のガードにより、ステージング済みの値に対するdup/dropは、実行時には何もしない操作になるからである。

## 適用範囲の広さ: すべてのプログラム自身のエントリポイント

この畳み込みが効く範囲は、インターフェース辞書だけよりはるかに広い。プログラム自身のエントリポイントの継続`{__mainExpression:0}`は、それ自体が、名前付きの関数に対する、引数を何も埋めていないクロージャである。そのため、この畳み込みは、インターフェースを使うプログラムに限らず、rc2でコンパイルした*すべての*プログラムで動く。

`refc-suite/callingConvention`のゴールデンファイルを再生成する必要があったのは、まさにこのためである。そのファイルの生成されたCに出てくる`tmp_N`の名前が、すべて1つずつ繰り上がった(`tmp_4`が`tmp_5`になる、など)。コードの形が変わったからではない。エントリポイントのクロージャをステージングすることで、`tmp_N`/`constcon_N`/`constclosure_N`の名前を作る、共有の`ArgCounter`(`Emit/Util.idr`の`getNextCounter`)のカウントが1つ進むようになったためである。意味の変化ではなく、無害な番号のずれだが、この畳み込みが普遍的に働くことが目に見える形で表れている。

## 見つかったバグ

### #1: `Compiler.RC2.DeadCode`が、畳み込み済みクロージャ自身の参照を見られなかった

`DeadCode.idr`の到達可能性を調べるウォーカー`usedFunctionNamesR`は、`RCExp`のノードが呼び出したり参照したりしうる`Name`をすべて計算する。ただし、調べるのは`RCExp`のノードそのものだけで、`RCLocal`自身のフィールドの中は見ていなかった。

この変更の前は、これで問題がなかった。`RCLocal`のどの定数の形も、自身の`Name`を持っていなかったからである(`RCConstCon`が持つのは*コンストラクタ*の名前で、`defs`の関数名のキーとは別の名前空間なので、除外して正しかった)。`RCConstPartial`ができた時点で、これは、実際に確認された正当性上のギャップになった。畳み込み済みの辞書が、自身のメソッドの1つを参照している唯一の箇所は、`RCConstPartial`のフィールドの中に埋め込まれた`Name`である。ところがウォーカーは、`RCLocal`のレベルで、外側の`RCon`/`RCConstCon`自身の`args`のリストの先を見ない。

そのため`DeadCode.pruneDeadDefs`は、畳み込み済みの辞書のフィールド*経由でしか*到達できないメソッドを、不要なコードとして刈り取ってしまう。`Emit.Util`が、そのフィールド用に生成する不死のstaticリテラルが、自身のCの初期化子の中でそのメソッドをシンボルで参照しているにもかかわらず、である。

**修正**: 新しい`usedFunctionNamesL : RCLocal -> SortedSet Name`が、`RCConstPartial`(`singleton n`)と`RCConstCon`(その`args`に対する`concatMap usedFunctionNamesL`)の中へ再帰する。そして`usedFunctionNamesR`は、末尾に`_ = empty`という包括的なケースがある関数から、`RCExp`のすべてのコンストラクタについて本当に網羅的な関数へ書き直した。`RCLocal`型のフィールドを触るすべての箇所(`RV`自身のローカル、すべての`args`/`postDrop`のリスト、`RCon`の`reuseFrom`、`RConCase`/`RConstCase`の`sc`など)で、`usedFunctionNamesL`を呼ぶ。

古い包括的なケースのせいで、このギャップは気づかれなかった。まだ教えていない種類のノードについて黙って`empty`を返す関数は、型検査器から見ると、本当に報告すべきものがない関数と区別できない。包括的なケースをなくせば、対応するケースがないまま`RCExp`に追加された将来のコンストラクタは、到達可能性の黙った見落としではなく、コンパイル時のカバレッジエラーになる。

**検証の方法**: 修正を一時的に元に戻し(`usedFunctionNamesL`を`const empty`に戻した)、再ビルドして確認した。黙って誤った答えを出すのではなく、本物のCのコンパイルエラーが再現する。`constclosure_N`のstaticの初期化子の中で`error: '...' undeclared here (not in a function)`となる。刈り取られた関数自身のCの定義(前方宣言も)が、生成された`.c`に完全に存在しないからである。

これがリンク段階の "undefined reference" ではなくコンパイル段階の失敗になるのは、staticの初期化子におけるアドレス取得を、Cコンパイラ自身が検査するためである。通常の呼び出し箇所の参照のように、リンカに先送りされることはない。修正を元に戻すと、再びビルドが通ってテストも通る。

修正を外したビルドは、このギャップを直接動かすプログラムに限らず、rc2の*すべての*プログラムを壊す。`{__mainExpression:0}`自身のエントリポイントの継続が、インターフェースとは関係なく、まさにこの仕組みで畳み込まれるからである(上の「適用範囲の広さ」を参照)。

### #2: `boxedConstExpr`の`ConstDef`の重複除去キャッシュが`I`と`I64`を衝突させた

この変更によって初めて表に出た、関連する既存のバグがある(この変更が持ち込んだものではない)。`Emit.Util.boxedConstExpr`は、`ConstDef`の重複除去キャッシュを、生の`Constant`をキーにして引いていた。そのため、同じ値の`I x`と`I64 x`が、別々のキャッシュエントリとして扱われた。`genConstant`は`I`と`I64`を同一視しており(`isReuseConsumingOp`のドキュメントコメントが`cPrimType`について述べているのと同じ同一視)、両者は同じCの名前で出力される。そのため、それぞれが独立にステージングして同じ`idris2rc2_constant_Int64_...`という名前を作り、Cの再定義になった。

これが今まで起きなかったのは、到達する条件が狭いからである。`litRep`がすでにカバーしているnative-eligibleなリテラルが、それでも`boxedConstExpr`に渡されるのは、畳み込まれた`RCConstCon`のフィールドが`constConFieldExpr`の`RCConst`のケースを通るときだけである。`inlineExprFor`の`RCConst`のアームを通る場合は、native-eligibleなリテラルをインラインで出力するので、起きない。そして、これまでは、インターフェース辞書が完全に畳み込まれることがなかった。辞書を`RCConstCon`に畳み込むようになって、この経路が実際に使われ始めた。`rc2/tests/refc-suite/integers`の`Cast`/`Neg`の辞書で確認した。

**修正**: 新しい`constDefKey : Constant -> Constant`が、`ConstDef`に対するすべての`lookup`/`insert`の前に、`I x`を`I64 (cast x)`に正規化する。ほかのすべての`Constant`は変更しない。

## 防御的な強化: `idris2rc2_trampoline`の`REFCOUNT_MAX`ガード

これは、実際に起きているバグの修正ではない。`idris2rc2_trampoline`へのすべての呼び出し箇所をたどって、渡されるのは、新しい関数呼び出しの結果、`mkClosure`したばかりのオブジェクト、すでに`idris2rc2_isUnique`を通ったオブジェクトのどれかだけであることを確認した。現在のコードでは、これらが不死のクロージャであることはありえない。

それでも、対称性と将来への備えとして追加した。`idris2rc2_trampoline`自身の参照カウントのデクリメントは、アトミックなデクリメントの前に`c->header.refCount != IDRIS2RC2_REFCOUNT_MAX`を調べるようになった。`idris2rc2_drop`がすでに持っているガードと同じもので、いつか不死のクロージャを渡してくる呼び出し側が現れたときに備えている。

## スコープと制限

最初のパスが畳み込んだのは、辞書自身の*構築*のコストだけで、この文書が扱っている、呼び出しごとの確保1回分である。辞書を*経由する*ディスパッチ(実際のメソッド呼び出し`idris2rc2_applyClosure`)は、Boxedの間接呼び出しのままだった。

### 畳み込み済みクロージャの飽和適用は直接呼び出しになった

このギャップの半分は、実は少しも難しくなかった。`RCConstPartial n missing []`は、**捕捉した値を持たない**真の葉である。したがってその`missing`は、呼び出し先の残りのアリティ全体であり、ちょうどその数の引数を与える適用には、先送りされるものが何も残らない。これは単なる直接呼び出しである。`foldConst`自身の`RApp`のケースが、これを書き換える。

```idris
RApp fc lazy (RCConstPartial n missing []) args   -- length args == missing
  ==> RAppName fc lazy n args
```

これによって、箇所ごとに取り除かれるのは次のものである。

- `idris2rc2_applyClosure`(アリティの検査、引数のコピー、`support/rc2/runtime.c`自身の関数ポインタのテーブルを通したディスパッチ)。
- `constclosure_N`のstaticの読み出し。
- ほかに参照するものがなくなれば、static自体(`Compiler.RC2.DeadCode`)。

これらのどれよりも大きいのは、*加わる*ものである。**名前付きの**呼び出しになるため、`Compiler.RC2.SpecClosure`、`Compiler.RC2.LateInline`、`Compiler.RC2.DualABI`のすべてが、その中を見通せるようになる。`RApp`は、これらのどれから見ても不透明である。

idris2-lspのビルド全体で計測した。16,400個の`apply`ノードのうち、4,842個が定数クロージャを対象にしていて、そのうち3,881個がそれを飽和させていた。`apply`は16,400から12,519に、`call`は49,530から53,409になった。不足適用(`length args < missing`。残りの961個)は、引き続き本物のクロージャを必要とし、変わらない。過剰適用は、`RC.idr`自身の`collectAppChain`からは生じない。`collectAppChain`は飽和した地点を越えて連鎖をまとめることがないからである。しかし特殊化が過剰適用を作ることがある。後述の「畳み込み済みクロージャの過剰適用」を参照。

### まだ残っていること

実行時に読み出した辞書フィールドを経由するディスパッチ(本物の`RCLoc`に対する`idris2rc2_applyClosure`)は、依然としてBoxedの間接呼び出しである。idris2-lsp自身の`apply`ノードでは11,558個にあたる。これを解消するには、クロージャの定数だけでなく、辞書の*値*が分かった時点で、呼び出し箇所を特殊化する必要がある。`TODO.md`の "Performance: interface-dictionary method dispatch stays boxed even when the concrete instance is known" を参照すること。

## 後続の作業(コミット`0e7c755`): エイリアスの伝播と、一般的な呼び出し引数のケース

上の最初のパス(コミット`a01eaa2`)は、インターフェース辞書、つまり`RCon`/`RCConstCon`の中にある`RCConstPartial`のフィールドを対象にして、その範囲で検証していた。この機能をエンドツーエンドで再検証していると、2回目の確認で、完全性に関する実際のギャップが1つと、すでに動いていたもののテストされていなかった一般化が1つ見つかった。

### ギャップ: 畳み込み済みクロージャの`let`による再束縛が伝播しなかった

`ConstFold`の`RLet`の値を分類するブロックには、`RCConstCon`用の対になるアームがすでにあった。`a`が定数に畳み込まれたあとで`let b = a`が続く場合、`a`自身の使用が解決されるだけでなく、`b`も同じ定数として`env`に入れ直さなければならない。

```idris2
RV _ cval@(RCConstCon {}) =>
    let body' = foldConst (insert var (Element cval ItIsConstCon2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

(`ConstFold.idr:316-320`)。`RCConstPartial`には、これに相当するアームがなかった。そのため、`let a = someTopLevelFn in let b = a in MkDict a b`のような連鎖では、`a`は正しく畳み込まれるのに、`b`のところで気づかないうちに伝播が止まっていた。`b`は、まったく同じ不死の値を指しているにもかかわらず、実行時の本物のローカルのままになり、`MkDict a b`の`b`フィールドは、`RCConstCon`の畳み込みの`allConstLocal`の検査に届かなかった。

生成されるコードは有効だったので、正当性のバグではなく、畳み込みの取りこぼしである。ただし、最初にコミットした`RCConstPartial`の完全性には、実際にギャップがあった。

修正は、`RCConstCon`のアームと構造がまったく同じで、2つ目の`RV`のケースを足すだけである。違うのは、一致させる定数の形と、ウィットネスのコンストラクタだけである。

```idris2
RV _ cval@(RCConstPartial {}) =>
    let body' = foldConst (insert var (Element cval ItIsConstPartial2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

(`ConstFold.idr:328-332`。`RCConstCon`のアームの直後にある。)この同じアームは、素の`let a = someTopLevelFn`も記録する。`foldConst`の`RUnderApp fc n missing []`の節が、この値をすでに`RV fc (RCConstPartial n missing [])`に畳み込んでいるので、これもここに行き着く。

**検証の方法。** 本当に*残る*、`let b = a`(ローカルからローカルへの単なるエイリアス)をrc2自身のIRに載せるのが難しく、修正そのものは難しくなかった。Idris2自身のフロントエンドは、まさにこの形を、Lifted IRに届く前に先回りして畳み込んでしまう。`--directive dumplifted`で手作業で確認したところ、`let a = greetFn; b = a in ...`と直接書いても、どの関数の中に書いても、`Compiler.LambdaLift`の出力には2つの別々の束縛として届かない。

`Test115ConstFoldClosure/ConstFoldClosure.idr`は、代わりに`%noinline`を付けた素通しのヘルパーを使って、これを再現している(`mkAlias : (String -> String) -> (String -> String); mkAlias f = f`)。`%noinline`は、*Lifted* IRではこれを本物の呼び出しのまま残す。`--dumplifted`で確認したところ、`Main.main`自身の定義には`%let b = Main.mkAlias(!a) in ...`が残っており、本物の2つ目の束縛である。

その後`Compiler.RC2.InlineCExp`が、`mkAlias`の本体(引数をそのまま返すだけ)を呼び出し箇所に展開する。これはrc2自身の、独立した、Liftedレベルのインライナーで、上流の`%noinline`フラグを尊重しない。展開により、`ConstFold`が動く前に、`b`自身の値がちょうど`RV fc (RCLoc a)`になる。これが`env`を通って`RV fc (RCConstPartial ...)`に解決され、新しいアームにまさに行き当たる。

構造として確認した。アームがなければ、テスト自身の`MkDict a b`の構築は、生成された`.c`の中で本物の`RCon`のまま残る(`Main_main`の中に、本物の`idris2rc2_newConstructor(2, 1)`の呼び出しがあり、フィールドの1つは実行時のローカルからコピーされる)。アームがあれば、`dict`は1つの不死の`RCConstCon`に畳み込まれ、その2つのフィールドは、*同じ*`constclosure_N`のstaticを参照する。そして`Main_main`には、コンストラクタを確保する呼び出しがまったく残らない。

### 一般化: この畳み込みはコンストラクタのフィールドに限らない

上の設計の節は、`RCConstPartial`の畳み込みを、もっぱら、コンストラクタのフィールドに対する`RCon`自身の`allConstLocal`の検査(インターフェース辞書や、`{__mainExpression:0}`の継続)の話として組み立てている。しかし、畳み込みそのものは、実際には、その位置に固有のものではない。

`RUnderApp _ n missing []`から`RCConstPartial`への変換は、`foldConst`自身の`RUnderApp`の節の中で(`RLet`の値の分類は、その結果を`env`に記録する)、束縛された変数を使う特定の*利用側*を考える前に、一様に、1度だけ行われる。その束縛をあとから読むものは、コンストラクタのフィールドでも、普通の関数呼び出しの引数でも、何であっても、`resolveLocal`が解決した結果(`RCConstPartial`を含む)として読む。

`Test115ConstFoldClosure/ConstFoldClosure.idr`は、そもそもこの作業に関心を持つきっかけになったケースについて、これを確認している。コンストラクタのフィールドではなく、普通の関数呼び出しに渡す、引数を何も埋めていないクロージャである。`TODO.md`がかつて "Dropped: closure generation for statically-known higher-order function arguments" として追跡していた、`map double [1,2,3,4,5]`の形である(後述の「完全な解決」を参照)。

このテストの`useIt : List Int -> List Int; useIt xs = map double xs`は、`double`のクロージャ引数を、1つの不死の`constclosure_N`のstaticにコンパイルし、`useIt`自身のコンパイル済みの本体に直接埋め込む。生成されたCを調べて、そのための`idris2rc2_mkClosure`の呼び出しが、どこにも**1つも**ないことを確認した。`main`の3か所の呼び出し箇所(`useIt [1,2,3]`、`useIt [4,5,6]`、`useIt [7,8,9]`)から`useIt`を呼んでも、畳み込みが起きるのは、実行のたびではなく、コンパイル時の*1回*だけであることが確認できる。3つの呼び出しはすべて、同一の`constclosure_N`のstaticを参照し、自身の呼び出し箇所でも`useIt`の中でも、`double`のための新しいクロージャを確保するものはない。

### `TODO.md`にあった旧項目 "Dropped: closure generation..." の完全な解決

`TODO.md`には、かつて "Dropped: closure generation for statically-known higher-order function arguments" という節があった。`double`が静的に分かっているトップレベル関数であるにもかかわらず、`map double [1,2,3,4,5]`の形のコードが、呼び出しのたびに新しいクロージャの確保に対価を払う理由を調べたものである。2つの修正の方向を検討して、どちらも見送っていた。

1. **クロージャをキャッシュする/不死にする**。当時は、`idris2rc2_tailcallApplyClosure`の一意でない分岐が、`REFCOUNT_MAX`のガードなしに、参照カウントを無条件にデクリメントしているので、不死のクロージャを渡すのは安全でないという認識から、見送られた。今回の調査で、実際のソースに照らして確認し直したところ、その分岐はすでに、完全にガードされた`idris2rc2_drop`を呼んでおり、実際には、安全でなかったことは一度もなかった。(ガードのない本物のデクリメントは、別の関数`idris2rc2_trampoline`にあった。これには、対称性と将来への備えとして、コミット`a01eaa2`で、同じ防御的なガードを入れた。「防御的な強化」を参照。)
2. **静的に分かっている引数ごとに、呼び出し先を特殊化する**(汎用の高階ヘルパーを、異なる関数引数ごとに1回ずつ複製する)。方向1とは関係なく、見送った。`map`/`filter`/`foldl`のような形で、プログラム全体で広く使われる汎用ヘルパーを、多くの異なる関数で呼ぶと、そのたびにほぼ重複した特殊化コピーが作られ、呼び出しごとの確保を、生成コードのサイズの際限のない増加と引き換えにすることになる。この理由は、以下のどの内容によっても変わらない。単に、不要になっただけである。

方向1の障害は、古い認識だったことが分かった。この文書自身の`RCConstPartial`の畳み込みは、事実上、方向1を、呼び出し箇所ごとに手で起動するのではなく、名前付きの関数に対する、引数を何も埋めていないクロージャが現れるたびに自動的に適用するものである。これが、きっかけになった問題を完全に解決することを、今回、実験で確認した。

- `map double [1,2,3,4,5]`の形そのものが、1つの不死の`constclosure_N`のstaticに畳み込まれ、そのための`idris2rc2_mkClosure`の呼び出しは、どこにも残らない(上の`Test115ConstFoldClosure/ConstFoldClosure.idr`)。
- 畳み込みが起きるのは、実行のたびではなく、コンパイル時の*1回*だけである。内部で`map double xs`を呼ぶヘルパーに対する、3つの別々の呼び出し箇所は、すべて同一のstaticを参照する(上の`Test115ConstFoldClosure/ConstFoldClosure.idr`)。
- これをエンドツーエンドで再検証したときに見つかった完全性のギャップ1つ(`let`による再束縛が、1ホップより先に伝播しない)も、今は修正されている(上の`Test115ConstFoldClosure/ConstFoldClosure.idr`)。

方向2(呼び出し箇所ごとの特殊化)は、それとは独立の、今も有効なコードサイズの理由から、引き続き見送ったままで正しい。必要な方向ではなかったというだけである。方向1がすでに、目標を別の、より良い方法で達成している。既存のクロージャ表現に対する確保の省略であって、コードを複製する変換ではない。汎用ヘルパーを何種類の関数で呼んでも、生成コードのサイズには一切コストがかからない。

## ファイル

- `rc2/src/Compiler/RC2/RCExp.idr`: `RCLocal`の新しい`RCConstPartial`のケース、`IsConstPartialLocal`、`IsAnyConstLocal`の5つ目のコンストラクタ、および`Eq`/`Ord`/`Show`への追加。
- `rc2/src/Compiler/RC2/ConstFold.idr`: `RUnderApp fc n missing []`に対する`foldConst`の節(`RV fc (RCConstPartial ..)`に畳み込む)と、`RLet`の値を分類するアーム`RV _ (RCConstPartial {})`(その定数を`env`に入れる。加えて、畳み込み済みのクロージャ定数を、さらなる`let`による再束縛へ伝播させる。コミット`0e7c755`)と、`isConstLocalProof`の新しいケース。
- `rc2/src/Compiler/RC2/Emit/Util.idr`: `boxedConstPartialExpr`、`boxedConstExpr`の`constDefKey`の修正、および`constConFieldExpr`/`inlineExprFor`/`repOfLocal`/`varName`に追加した`RCConstPartial`のケース。
- `rc2/src/Compiler/RC2/DeadCode.idr`: `usedFunctionNamesL`、および`usedFunctionNamesR`の網羅的な書き直し。
- `rc2/src/Compiler/RC2/RC.idr`: `annotate`の`splitBorrows`/`dropIfLastUse`/`isBoxedOperand`/`(RV fc v)`のケース。`RCConstPartial`を不死として扱うように拡張した。
- `rc2/src/Compiler/RC2/Util.idr`: `localRepIn`の`RCConstPartial`のケース(常に`RBoxed`)。
- `rc2/support/rc2/runtime.c`: `idris2rc2_trampoline`の防御的な`REFCOUNT_MAX`のガード。
- `rc2/support/rc2/idris2rc2_datatypes.h`: `IDRIS2RC2_Closure`の本当のレイアウト(参照しただけで、変更していない)と、`IDRIS2RC2_STOCKVAL`/`IDRIS2RC2_REFCOUNT_MAX`(そのまま再利用した)。
- `rc2/tests/Test115ConstFoldClosure/ConstFoldClosure.idr`: この畳み込みの回帰テストを統合したスイート。関連する節は次のとおり。
  - §1(旧`Test69ConstFoldClosureDict`): 構造の回帰テスト。3メソッドの`Greeter Dog`のインスタンス辞書が、3つの`RCConstPartial`フィールドを持つ1つの`RCConstCon`に畳み込まれる。`--directive dumprcexpr`で確認し、辞書を構築する`idris2rc2_mkClosure`の呼び出しが生成された`.c`にないことをgrepで確認した。
  - §2(旧`Test71ConstFoldClosureDeadCodeSurvival`): `DeadCode`の修正に特化したテスト。畳み込み済みの辞書フィールド経由でしか到達できないメソッド(`secretG`)と、そのメソッドだけが呼ぶ2ホップ目のヘルパーの、どちらも`pruneDeadDefs`を生き延びなければならない。
  - §3(旧`Test72ConstFoldClosureAliasFold`、コミット`0e7c755`): `RCConstPartial`の、対になるアームの修正。`%noinline`を介した、畳み込み済みクロージャの`let`によるエイリアスが、それでも`MkDict a b`を1つの不死の`RCConstCon`に畳み込む。
  - §4(旧`Test73ConstFoldClosureCallArg`、コミット`0e7c755`): 一般的な呼び出し引数のケース(`map double [1,2,3,4,5]`の形)。クロージャ引数が、3つの別々の呼び出し箇所で同一に共有される1つの不死のstaticに畳み込まれる。生成されたCを調べて、`idris2rc2_mkClosure`の呼び出しが1つも要らないことを確認した。
- `rc2/tests/Test115ConstFoldClosure/ConstFoldClosureCallthrough.idr`: 結果として得られた不死のクロージャを経由するディスパッチを500回繰り返したときの、正しさとvalgrindでのクリーンさを確認する(`Test172Closures/ClosureInPlaceGrow`自身の厳密さにならった)。統合したスイートに入れず、独立したテストのままにした。valgrind下での長いループは、統合したスイートにふさわしくないためである。

## 畳み込み済みクロージャの過剰適用

`foldConst`が定数クロージャの`apply`を呼び出しに変えるのは、クロージャに足りない引数をちょうど受け取るときだけで、それより少ないときは`partial`に変える。それより多く受け取るのは、クロージャがカリー化されたラムダの最初の段であるときである。`Data.SortedMap.{insertFrom:1}`(パラメータはキー1つ)の定数クロージャで特殊化された`foldl`は、それを要素とアキュムレータに一度に適用する。そのため、Cは`idris2rc2_applyClosureN(&constclosure_N, {x, acc}, 2)`になっていた。これは持ち上げられた関数を呼び、それが返すクロージャを作って、そのクロージャを適用する。

その時点で`ArityRaise`は、`insertFrom:1`を、両方を受け取る関数の素のラッパー(`f params = partial g m params`)にしていた。`applyFoldApplied`(`ArityRaise.idr`)は、このようなラッパーを知っている。これが、`length ys`がクロージャに足りない数に`m`を足したものに等しい`apply <素のラッパーの定数クロージャ> ys`も、呼び出し`g ys`に畳み込むようになった。クロージャは何も保持しない不死のstaticなので、dropするものはない。`ys`は、`apply`に移っていたのと同じように呼び出しに移る。`let c = <closure>`の形は以前から畳み込まれており、クロージャが保持していたもののdropを調整していた。

`Test157ApplyConstClosure`は、これを`Data.SortedMap.fromList`で確認する。プログラムのIRにある定数クロージャの`apply`ノードは、`--directive noapplyfold`のときより少なく(1個に対して0個)、出力(RefCとの比較)とvalgrindの結果は同じである。

## 素のラッパーを対象とするクロージャ

素のラッパーを対象とするクロージャのうち、作られた場所で適用されないものは、そのまま残されていた。`rc2_specConst_Libraries_Data_Tap_traverse_0_9364 f xs`は、`ArityRaise`のあと(worldが持ち上げられた)`partial rc2_raised_..._7 missing=1 [f, xs]`になり、その呼び出し側は`partial W missing=1 [f]`を作って格納していた。そのクロージャを`xs`に適用すると`W`が呼ばれ、`W`は持ち上げられた関数のクロージャを確保し、そのクロージャにworldが適用されていた。

`W params = partial R m params`のとき、`k`個の引数に適用した`partial W k caps`は`partial R m (caps ++ arguments)`であり、同じ`k`個の引数に適用した`partial R (k + m) caps`は、同じクロージャである。そこで`applyFoldApplied`は、素のラッパーを対象とするすべてのクロージャを、ラップされている関数を対象とし`k + m`が足りないクロージャに付け替えるようになった(`ArityRaise.idr`の`wrapperClosure`。`FunDedup.renameNamesG`を通す)。対象は`partial`と定数クロージャである(`RCConstPartial W k`は`RCConstPartial R (k + m)`になる)。ラッパーのラッパーは最後までたどる。捕捉した値は同じで順序も保つので、クロージャが所有するものに足されるものも、取り除かれるものもない。どの`partial`、定数クロージャ、呼び出し、`delay`からも名前を参照されなくなったラッパーは、デッドコード除去で取り除かれる。

定数コンストラクタの中にある定数クロージャには届かない(`fwd-alias.md`を参照)。`delay`はクロージャではなく遅延セルなので、手を付けない。`applyFoldApplied`は`Sink`のあとにもう一度動く。`Sink`が、ちょうど足りない`k`個の引数の`apply`の隣に移したクロージャは、その時点ですでに`R`を対象とするクロージャになっていて、`k + m`が足りない。そのため、その`apply`はもう呼び出しに畳み込まれない。

`rc2-norepl`のIRでは、素のラッパーが220個あり、そのうち137個が`partial`(729か所)から、61個が定数クロージャ(343か所)から名前を参照されていた。変更後に残るのは49個で、どの`partial`からも参照されず、定数クロージャの253か所(定数コンストラクタの中)から参照される。定義の数は13,160から12,990になる。

`Test163WrapperClosure`: `step`のラッパーを対象とするクロージャ。IRにあるその数は`--directive noapplyfold`のときより少なく、出力は同じである。

## 定数を捕捉するクロージャ(`RCConstPartial`)

捕捉した値がすべて定数(リテラル、`RCEmptyCon`、`RCConstCon`、または捕捉した値の有無を問わず別の`RCConstPartial`)である`partial f missing caps`は、それ自体が定数である。`ConstFold`はこれを`RCConstPartial f missing caps`にし、`Emit.Util`(`boxedConstPartialExpr`)は、異なる値ごとに1回、不死の`IDRIS2RC2_ConstClosureArgs<n>`(`IDRIS2RC2_Closure`のレイアウト。`arity = filled + missing`、`filled = length caps`、捕捉した値は`args`に入る)をステージングする。IRのダンプでは`#f/missing~closure(caps)`と表示される。捕捉を持たないクロージャは、捕捉した値のない(`caps = []`)同じコンストラクタであり、上の各節が扱う形である。

コード生成は以前から、定数を対象とする`RUnderApp`に出会ったとき、そのようなクロージャをstaticにしていた(`staticClosure`、`static-closures.md`)。したがって、ここでの利点は確保ではなくIRにある。`Emit`より前のパスにとって、クロージャが定数の値になる。定数を捕捉するクロージャのコンストラクタである辞書は`RCConstCon`に畳み込まれ、それに対する`case`とフィールドの`apply`は解決され、クロージャは値として比較・重複除去される。

- その`apply`は、捕捉を持たない形の場合と同じように、捕捉した値を先頭にして解決される。`length ys == missing`なら呼び出し`f (caps ++ ys)`になり、引数がそれより少なければ`caps ++ ys`を捕捉した`partial`になる(次の回の畳み込みがそれを見れば、これもまた定数になる)。クロージャに足りない数より多い引数の適用は、`KnownPartial`によって、飽和させる呼び出しと残りの`apply`に分割される。
- 捕捉した値の中に定数コンストラクタ(インターフェース辞書)があると、そのクロージャは`RUnderApp`のまま残る。`SpecClosure`は、その箇所で呼び出し先を辞書について特殊化する(`underAppSites`、`Test131SpecConstConCapture`)が、`RCConstPartial`の中からではそれができないためである。
- 捕捉した値の名前を付け替えたり、作り直したりすることはない。`FunDedup.renameLocalN`が変えるのは関数と足りない数だけである(そのため`FwdAlias`と`ArityRaise`のラッパーの畳み込みがここに届く)。捕捉した値の中の定数は、定数コンストラクタに対する`FwdAlias`と同じように、自身の関数を生かし続ける。
- 適用しても、これが変わることはない。不死なので`idris2rc2_isUnique`は偽である。最後の引数に届かない適用はこれをコピーし、届く適用は捕捉した値を`dup`して関数を呼ぶ。
- `partial`の関数と捕捉した値を見ていたパスは、この形も見る。`SpecClosure`(`lookupKnown`)、`ArityRaise`(持ち上げるクロージャの末尾)、`LateInline`(呼び出し先を展開する価値を生むクロージャ引数と、そのようなパラメータの呼び出し)、`PushApply`、`CmpMerge`、`FunDedup`(等価性)である。

これとあわせて、フィールドを持たないタグ付きコンストラクタ(`Line`、`Explicit`)は、`ConstFold`が`con`として出会ったとき、タグ付き整数の`RCEmptyCon`になる。`RC.idr`の`bindOne`がオペランドに対してそうしていたのと同じである。それまでは、フィールドのないヒープのセルであり、それを保持するすべてのコンストラクタの畳み込みを妨げていた。これにより、`Libraries.Text.PrettyPrint.Prettyprinter.Doc.line`のような辞書が畳み込まれるようになる。

`rc2-norepl`のIR(定数を捕捉するクロージャのコンストラクタであるCAF)では、変更前は12個のCAFと271か所の呼び出し箇所があり、変更後は7個と31か所になった。メモ化されたCAFは276から263に、`partial`ノードは5,264から5,179になり、定数を捕捉する定数クロージャが87個現れる。タグ付きの引数なしの`con`ノード(793個)はなくなった。

`Test164ConstPartial`: 定数を捕捉するクロージャのレコードとリスト(`add4`を段階的に適用してできる、定数を保持するラムダ)。Cには`constpartial_N`のstaticがあり(`--directive noconstfold`のときは1つもない)、出力は同じである。
