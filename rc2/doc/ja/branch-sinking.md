# 枝ローカルなsinking(`Compiler.RC2.Sink`)

(原文: `doc/branch-sinking.md`。内容が乖離した場合は原文を正とする。)

## このパスの役割と、ループ変換とは別パスである理由

`let var = value in <branch>`という形を考える。`let`の直後に`RConCase`/`RConstCase`/`RCmpCase`が続き、`var`がその分岐の枝のうち*1つ*でしか読まれない。このとき、`value`の計算をその1つの枝の内側へ移す。ほかの枝は`var`の存在そのものを知らなくなり、`var`についての`drop [var, ...]`があれば、不要になるので取り除く。

このパスを見つけたきっかけは、`tests/Test110Loop/LoopInvariantParam.idr`のダンプを読んだことだった。このテストには、かつての`Test21BoxedInvariantNotHoisted.idr`が吸収されている。これは`rc2/doc/loop-conversion.md`の「ループ不変式のホイスト」節で、意図的にホイストしないネガティブケースとして扱っている。ダンプには`let v5 = MkCtx tag extra in (ループ自身の脱出チェック) then v5 else (v5 を使わない) ...`という形が現れる。`v5`はループの脱出側の枝でしか読まれない。それにもかかわらず、ループが続く反復のたびに`v5`を構築し、使わずにすぐdropしていた。

**`Compiler.RC2.Loop`に統合しなかったのは意図的である。** ホイストと違って、この書き換えは`value`がループ不変かどうかを問わない。`v5`のフィールドがループを回るたびに変わる値であっても、同じ移動は正しい。移動によって`value`の計算回数が減るだけだからである(必要とする1つの枝に、そこへ到達したときにだけ計算するようになる)。動機となったパターン(`let X = ... in case/cmp ...`で、`X`を読む枝と読まない枝がある)は、ループとは完全に無関係である。`tests/Test22BranchSinking.idr`は、ループが一切ない通常の非再帰関数でこのパターンを検査している。

**sinkingとホイストは、向きが逆で、守備範囲が互いに補い合う。** `Compiler.RC2.Loop`のループ不変式のホイスト(`rc2/doc/loop-conversion.md`を参照)は、計算をループの*外*へ出して、反復ごとではなく呼び出しごとに1回だけ実行する。このパスは、計算を必要とする1つの枝の*中*へ入れて、その枝に実際に到達したときにだけ実行する。回数はさらに少なくなる。実際には、両者が同じ候補を奪い合うことはない。ホイストが見るのは、ループ本体の、分岐より前にある無条件の先頭部分だけである。sinkingが働くのは、`let`の直後に分岐が続く場合だけである。2つの分岐のあいだにある`let`で、後ろの分岐の枝の1つだけが使うものは、先にsinkされる(このパスは`Compiler.RC2.Loop`の後に走る。後述の「パイプライン上の位置」を参照)。沈められる値がたまたまループ不変だったかどうかは、判定に関係しない。

## アルゴリズム

`Compiler.RC2.Sink.applySinkExp`は、木全体を最も内側から外側へ向かって走査する。`RLet`自身をsinkできるか試す前に、その`body`を完全にsinkし終える。そのため、`let a = .. in let b = f a in <branch>`のような連鎖が、1回の走査で解決する。まず`b`が、それを使う1つの枝へ沈む。次に`a`が沈む。このとき`a`は、すでに沈んだ`let b = ...`を持つ同じ枝からしか到達できなくなっているので、その真後ろの同じ場所へ沈む。不動点まで繰り返す必要はない。これは`Compiler.RC2.Loop`の`hoistInvariantPrefix`と同じ理屈(その関数自身のdocコメントを参照)を、1段階上で使っている。向きだけが逆である(ループの外ではなく、分岐の中へ入る)。

### 何段でも深く沈める

sinkに成功したら、その結果をそのまま返さず、もう一度`applySinkExp`に通す。これが効くのは、`var`が沈んだ先の枝自身が、さらに別の分岐で始まっていて、`var`がその片側でしか読まれない場合である。最初のsinkのあと、`var`の`RLet`はその枝の先頭に来て、分岐ノードを包む形になる。これはまさに、`applySinkExp`の`RLet`ケースが探す形である。したがって、これを再び走査すれば、`trySinkInto`が2回目も働き、`var`はさらに一段深く沈む。これは、使用が1つの枝に限られる分岐がいくらネストしていても、同じ1回の走査で連鎖する。別途、不動点のドライバを用意する必要はない。成功するたびに、`var`の束縛が、有限の木のより小さい部分木へ厳密に移るので、再帰は必ず止まる。この性質の専用テストは、`tests/Test22BranchSinking.idr`の`deepSinkable`である。`ctx`は、*2つ*のネストしたフラグがどちらも`True`のときにだけ読まれ、1回の`Compiler.RC2.Sink`の実行で両方の分岐を通って沈む。

### `value`が候補になるかの判定(`sinkEligible`)

候補になるのは、素の`ROp`/`RCon`/`RAppName`である(先頭にある`RDup`/`RDrop`/`RFree`/`RReleaseReuse`のラッパを剥がしたあとの形で判定する。剥がすラッパの種類は、類似の理由で`Compiler.RC2.Loop.isInvariantExpr`が剥がすものと同じである)。除外条件も、当てはまるものは、その関数と同じ理由で同じにする。これは導出し直さず、意図的に同期させている。

- `ROp`/`RAppName`の`lazy`フィールドは`Nothing`でなければならない。遅延された演算は、評価の*タイミング*自体が観測可能だからである。
- `RCon`の`reuseFrom`は`Nothing`でなければならない。特定の`RReuseOffer`が持つ、枝ごとの実行時一意性チェックのプロトコルと絡み合っており、このパスが動かしてよいものではない。

**`RAppName`(名前付きの通常の呼び出し)は、`Compiler.RC2.Loop`のホイストでは意図的に除外しているが、ここでは候補になる。** ホイストでその除外が必要なのは、ホイスト固有の事情による。ホイストは、計算を無条件に、呼び出しごとに1回、ループの前へ移す。ループが1度も回らない経路では、本来その計算は一切行われなかったはずである(`rc2/doc/loop-conversion.md`の「ループ不変式のホイスト」節を参照)。これに対してsinkingは、`value`を実行する回数を減らすだけである(それを必要とする1つの枝に実際に到達したときだけにする)。もともと必ず実行された呼び出しは、移動後も必ず実行される。実際の使用箇所のすぐ近くに来て、そこへ到達したときにだけ実行されるようになるだけである。「実行されない」経路が「実行される」経路に変わることはない。パス全体がこの同じ安全性の論拠に立っている。`RApp`/`RUnderApp`(クロージャの適用/構築)は、明示的に対象外である。アロケーションやトランポリンなど、名前付きの直接呼び出しより仕組みが多く、ここでは解析していない。`RExtPrim`(`%World`を受け渡す本物の副作用)は、沈めても沈めなくても、候補にならない。

呼び出しを沈めるために、このパスはそれまで不要だった基盤を1つ追加した。`Sink.idr`は`SortedMap Int Rep`(`reps`)を、`applySinkExp`/`trySinkInto`/`trySinkIntoArms`に通して受け渡す。初期値は空である(トップレベルの引数は、すべて本当に`RBoxed`である。これは`localRepIn`の「IDがなければ`RBoxed`とみなす」という規約に沿っており、`Compiler.RC2.DualABI`の同名の関数をそのまま写した)。すべての`RLet`(その`Rep`の宣言)と`RLoop`(その`loopParams`)で拡張する。`Compiler.RC2.Loop.fillLoopContinuePostDrop`や`Compiler.RC2.DualABI.applyCallSiteRewriteBody`がすでに受け渡している形と同じである。これは`consumedOperands`のためだけにある。`ROp`は、どのオペランドがBoxedかを`postDrop`がすでに正確に列挙している。しかし`RAppName`にはそのようなフィールドがなく、呼び出しが走った時点で、引数は*すべて*無条件に消費される(所有権が呼び出し先へ移る)。そのため`consumedOperands`は、`addOperandDrops`に渡す前に、引数リスト全体から、`reps`が実際に`RBoxed`だと確認したものだけを選び出す必要がある。すでにネイティブな引数が`RDrop`の`vars`に現れてはならない。専用のテストは`tests/Test22BranchSinking.idr`の`callSinkable`である。`buildMsg tag n`の呼び出しは、その結果を読む1つの枝へ沈み、もう一方の枝には、代わりに明示的な`drop [tag, n]`が入る。

### 枝ごとの分類(`stripIfUnused`、`genuinelyUsedR`)

枝ごとに、`var`を次の3つに分類する。

- **Used**: その枝の本体のどこかで、本当に読まれている。
- **DropOnly**: その枝では読まれないが、`var`についての古い`drop [var, ...]`がある。`Compiler.RC2.RC`の`annotate`が、このパスの実行前に、そこでは使われないと判断したものである。
- **Absent**: まったく言及がない。

`genuinelyUsedR`は、`RCExp.idr`の`freeLocalsR`とは意図的に別物にしている。`RDrop`/`RFree`/`RReleaseReuse`の対象は、`genuinelyUsedR`では*何も*寄与しない。`freeLocalsR`はそれを使用として数える。それではすべてのsink候補が、どの枝でも使われているように見えてしまい、この目的にはまったく逆になる。

sinkingが働くのは、**Usedの枝がちょうど1つ**で、ほかのすべての枝がDropOnlyまたはAbsentの場合だけである。Usedが2つ以上の場合は、得るものがないので放置する。Usedが0の場合は、`var`が本当にデッドコードであり、その後始末はこのパスの仕事ではないので、放置する。

**`var`は、その分岐の判別オペランド(`isDecidingOperand`)であってはならない。** 判別オペランドとは、`RCmpCase`の比較の引数、または`RConCase`/`RConstCase`のスクルティニーである。スクルティニーは、どの枝が走るよりも*前*に評価されなければならない。`value`が分岐の判別対象そのものを計算するなら、`value`を特定の1つの枝へ沈めることは、構造上不可能である。これは開発中に捕まえた本物のバグである。`let v1 = v0 - 1 in case v1 of 0 => ...; _ => (v1 を使って v0 の fib を計算する)`(`tests/Test111Basics/Recursion.idr`の`fib`)を考える。各枝の本体だけを調べる検査では、これは「1つの枝(`_`)が使い、もう一方(`0`)は`v1`を二度と読まない」という形に見える。`v1`の束縛を`_`の枝に沈めると、`case v1 of ...`が、宣言される前の`v1`を参照することになり、未宣言識別子のコンパイルエラーになった。`trySinkInto`は、`trySinkIntoArms`を呼ぶ前に必ず`isDecidingOperand`を調べる。

### 書き換え本体と、正しくするまでに見つかった2つ目の本物のバグ

形の上でsinkが安全だと確認できたら、`value`(`var`/`rep`とともに)を、Usedの枝の先頭で再び`RLet`に束縛する。DropOnlyの枝では、その枝の`RDrop`の`vars`リストから`var`を取り除く(リストが空になるなら、ノードごと取り除く)。`removeVarDrop`が探すのは、先頭のラッパを剥がした位置だけではなく、枝の*全体*である。このパスは`Compiler.RC2.Reuse`と`Compiler.RC2.Loop`の両方の後に走るからである。`Compiler.RC2.ConAltNative`の`peelWrappers`は、どちらよりも前に走るので、もっと浅い位置にあると仮定できる。

**`value`が消費するオペランドにも、同じ扱いが必要である。これは、`value`を沈めなかったすべての枝について必要になる**(`consumedOperands`、`addOperandDrops`)。これは、このパスを作る過程で見つかった、`valgrind`で確認済みの2つ目の本物のバグである。`tests/Test110Loop/SelfTailLoop.idr`は、`Prelude.Types.getAt`を推移的に取り込む。この関数は、sinkingの前は`let v4 = op -Integer [v0, #1] postDrop=[v0] in case v1 of Cons ... => ...v4...; Nil => (v4 は未使用なので `drop [v4]`)`という形をしている。`postDrop=[v0]`は、`value`の計算自身が`v0`を解放することを意味する。この解放は、以前はループ本体の無条件の先頭部分の一部として、反復のたびに無条件に行われていた。`v4`の束縛を`Cons`の枝に沈めるときに、この点に対処しないと、`v0`が解放されるのは、その枝を実際に通った反復だけになる。`Nil`の枝では`v0`は読まれず(そこに`v4`への言及はなく、`v0`は`v4`を計算するときにしか到達できなかった)、解放もされない。これは本物のリークである。

`consumedOperands`は、`value`自身が読むときに消費するはずのBoxedオペランドを、すべて集める。対象は2種類ある。1つは`ROp`の`postDrop`リストである。もう1つは、`RCon`のフィールドのうち、先に`dup`されなかったものである(先頭の`RDup`がすでに追加の参照で守ったものを追跡する)。そのフィールドの最後の参照は、独立して残るのではなく、新しいコンストラクタへそのまま移る。`tests/Test110Loop/LoopInvariantParam.idr`に吸収された、かつての`Test21BoxedInvariantNotHoisted.idr`のケースは`dup v0; dup v1; con _ [v0, v1]`であり、両方のフィールドを先に`dup`するので、ここでは正しく何も寄与しない。`addOperandDrops`は、`value`を沈めなかったすべての枝の先頭に、これらに対する`drop`を付ける。これは、`value`自身の`postDrop`やフィールドの移動が、以前は毎回無条件に提供していた解放を、そのまま置き換えるものである。ただし、これらのどれかがその枝ですでに独立に読まれている場合には、sinkを行わないこと(`Nothing`)にして抜ける。この場合は二重dropの危険があるからである。そのようなことは、まず起こらない。ただ、防ぐコストは何もかからないので、守りを入れている。実際に発動することはないはずである。

### 無関係な`let`を越えるsinking

`trySinkInto`は、`var`の束縛と最終的な分岐のあいだにある、*無関係な*ローカル変数`y`の先頭の`RLet`も通り抜ける。`let x = .. in let y = (x を読まない) in <branch>`という形で、`y`はその場に残したまま、`x`を使う1つの枝の探索をその先へ続ける。このケースが発動するのは、`y`自身がsinkできなかった場合に限る。`y`がsinkできるなら、`applySinkExp`の最も内側からの走査が、`let y = .. in <branch>`をすでに書き換え済みである(`y`の束縛は枝の1つの内側へ移っている。前述の「アルゴリズム」を参照)。したがって、この`RLet`の形が残るのは、`y`が2つ以上の枝で読まれる場合か、`y`自身が`sinkEligible`でない場合だけである。`y`の値が`var`を読む場合は、`Nothing`で抜ける。その読み取りは、最終的にどの枝が走るかにかかわらず無条件に行われるので、`var`はどの枝より前に本当に必要になる。これは、`isDecidingOperand`が分岐のスクルティニーに適用するのとまったく同じ理屈である。専用のテストは`tests/Test22BranchSinking.idr`の`skipUnrelatedLet`である。`x`の束縛は、`y`の束縛を通り抜けて(`y`は両方の枝で読まれ、`x`は`y`の計算に現れない)、`x`を読む1つの枝の内側に着地する。

### `var`自身の死を越えて剥がさない

**このパス全体が生んだ最も重要なバグであり、`refc-suite/buffer`の`TestBuffer.idr`が捕まえた。単なるリークではなく、本物のミスコンパイルだった。** `trySinkInto`のラッパのケース(`RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer`)はすべて、剥がして先へ進む前に、*そのラッパの対象が`var`自身かどうか*を調べるようになった。`var`自身であれば、`Nothing`で抜ける。

`TestBuffer.idr`は、`do`記法で、`IO ()`を返す`Data.Buffer`の関数を連続して呼ぶ(`setByte buf 0 1; setBits8 buf 1 2; setBits16 buf 2 3; ...`)。それぞれの`()`の結果は、すぐに捨てられる。これは、`let v5 = call prim__setByte [...] in drop [v5]; let v6 = call prim__setBits8 [...] in drop [v6]; let v7 = ...; let v8 = ...`という形に下ろされ、そのずっと先に無関係な分岐がある。ここにある`RDrop [vN]`は、`vN`自身の、ただ1つの死である。分岐へ向かう途中で見過ごしてよい、無関係な所有権の帳尻合わせではない。

ラッパを剥がす節の*最初の*版(`trySinkInto reps var rep value (RDrop fc vs cont) = map (RDrop fc vs) (trySinkInto reps var rep value cont)`)は、`vs`を調べなかった。そのため、「途中にある無関係なdrop」と「`var`自身のdrop」を区別できなかった。探索は`v5`自身の死をそのまま通り抜け、`v6`/`v7`/`v8`の同じ連鎖も通り抜けて、遠くにある無関係な分岐まで進み、そこへ`v5`を沈めた。生成されたCは、宣言されていないスコープで`var_5`/`var_6`/... を参照した。これは未宣言識別子のコンパイルエラーであり、黙ったリークではない。`v5`は、実際の制御フローではそこまで届かないからである。

`tests/Test22BranchSinking.idr`に吸収された、かつての`Test23SinkPastSelfDrop.idr`のケースは、同じ形(結果を捨てる`IO ()`呼び出しの連鎖と、その後の、無関係な値を読む分岐)を直接再現する専用の回帰テストである。`Data.Buffer`には依存しない。

### 読み取りを、そのオペランドのdropを越えて沈めない

同じラッパの節は、ラッパが`value`自身の読むローカル変数(`readBy`)を解放する場合にも、`Nothing`で抜ける。解放とは、そのローカル変数に対する`drop`、`free`、`releaseReuse`、`reuseOffer`である。これは、worldアリティの引き上げ(2026-09-26)で形が変わったあとのidris2-lspに対して`rcexpr-lint`が見つけた。`searchType`に、`case`の前に置かれた`let v1 = (dup n; op -Integer [n, #1] postDrop= [n])`があり、枝の1つは、先へ呼び出す前に`n`を早めにdropしていた(`drop [n, t]`)。`v1`をその枝の`Right`の分岐へ沈めると、`dup n`が`drop [n, ...]`の後ろへ動き、解放後の使用になる。前節のように`var`だけを調べても、これは見えない。`var`は新しい束縛であり、それが読むオペランドは別のローカル変数だからである。

## パイプライン上の位置

このパスは、`Compiler.RC2.Loop`(自己末尾呼び出しの変換)の後、`Compiler.RC2.DualABI`の前に走る(`RC2.idr`の`toRCDefs`を参照)。`RLoop`/`RLoopContinue`ノードがすでに最終的な形になっている程度には遅い。そのおかげで、この1つのパスが、ループ本体の内側にも、ループを含まない通常の関数にも、同じように届く。一方、`DualABI`が木の形について考える必要が生じる前でもある。`genuinelyUsedR`/`removeVarDrop`が、どちらも`RLoop`/`RLoopContinue`のケースを持つのは、このためである。このコードベースのほかの木の走査はすべて、パイプライン上で`Compiler.RC2.Loop`より前にあるので、これらのケースが要らなかった。`--directive nosink`を指定すると、この段階だけが無効になる。ほかの任意の段階と同じ規約である(`RC2.idr`の`toRCDefs`のdocコメントを参照)。

## ファイル

- `rc2/src/Compiler/RC2/Sink.idr`: パス全体。
  - `genuinelyUsedR`/`removeVarDrop`/`stripIfUnused`: 枝の分類と書き換え。
  - `consumedOperands`/`addOperandDrops`: 上記の2つ目のバグの修正。
  - `sinkEligible`/`isDecidingOperand`: 適用条件のガード。
  - `trySinkInto`/`trySinkIntoArms`/`applySinkExp`/`applySink`: 書き換えと木全体の走査。
- `rc2/src/Compiler/RC2/RC2.idr`: `toRCDefs`のパイプラインへの組み込み。
- `rc2/src/Compiler/RC2/ConAltNative.idr`: `peelWrappers`。「先頭のラッパを剥がしてから分岐に入る」という、このパスのラッパを剥がすケースが写している慣用形である。
- `tests/Test110Loop/LoopInvariantParam.idr`に吸収された、かつての`Test21BoxedInvariantNotHoisted.idr`のケース: 動機となったケースである。自己末尾呼び出しのループの中にあり、`Compiler.RC2.Loop`のループ不変式のホイストとは、そのネガティブケースとして共有している。
- `tests/Test22BranchSinking.idr`: ループとは無関係な一般のケース。
  - sinkできる例が1つ。
  - sinkしてはならない例が1つ(`var`が両方の枝で読まれる)。
  - `deepSinkable`: 使用が1つの枝に限られる2つのネストした分岐を、1回の走査で通り抜けて沈める(前述の「何段でも深く沈める」を参照)。
  - `callSinkable`: 素の`RAppName`呼び出しを沈める(前述の「`value`が候補になるかの判定」を参照)。
  - `skipUnrelatedLet`: 無関係な`let`を越えて沈める(前述の「無関係な`let`を越えるsinking」を参照)。
  - かつて別ファイルだった`Test23SinkPastSelfDrop.idr`の専用の回帰テストも吸収している。これは、このパスが生んだ最も深刻なバグ(リークではなく本物のミスコンパイル。前述の「`var`自身の死を越えて剥がさない」を参照)のものである。`refc-suite/buffer`の`TestBuffer.idr`の形(結果をすぐ捨てる`IO ()`呼び出しの連鎖と、その後の、無関係な値を読む分岐)を、`Data.Buffer`に依存せず直接再現する。
- `tests/Test111Basics/Recursion.idr`/`tests/Test110Loop/SelfTailLoop.idr`/`refc-suite/buffer/TestBuffer.idr`: 既存のテストである(最初の2つは、推移的に取り込むPreludeの関数を通じて)。上記の4つの本物のバグのうち3つを捕まえた。最初の2つについては、専用の新しい回帰テストは要らない。既存のスイート全体の実行が、すでに両方の形を検査しているからである。3つ目、つまり`TestBuffer.idr`の形には、かつての`Test23SinkPastSelfDrop.idr`のケースを吸収した`Test22BranchSinking.idr`を専用の回帰テストとして用意した。ここで見つかった最も深刻なバグを、`refc-suite`が捕まえ続けることだけに頼るのは、間接的すぎると感じたからである。
