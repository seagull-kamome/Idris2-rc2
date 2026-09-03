# 枝ローカルなsinking (`Compiler.RC2.Sink`)

(原文: `doc/branch-sinking.md`。内容が乖離した場合は原文を正とする。)

## このパスが何をするか、そしてなぜループ変換とは別なのか

`let var = value in <branch>`(`let`の直後に来る`RConCase`/
`RConstCase`/`RCmpCase`)で、`var`がその分岐自身の枝のうち*1つ*でしか
読まれないものは、`value`自身の計算がその1つの枝の内側へ代わりに
移動するよう書き換えられる -- 他の全ての枝は`var`が存在すること自体
を一切知らなくなり、それらの自身の今や古くなった`drop [var, ...]`
(存在した場合)は除去される。

`tests/Test19LoopInvariantParam.idr`に統合された旧
`Test21BoxedInvariantNotHoisted.idr`自身のダンプ(意図的に
ホイストされない負のケース、`rc2/doc/loop-conversion.md`の「ループ
不変式のホイスティング」節参照)を読んでいて見つかった: `let v5 =
MkCtx tag extra in (ループ自身の脱出判定) then v5 else (v5を使わない)
...`は、ループを継続する毎回の反復で`v5`を再構築し -- そして未使用の
まま即座にdropする -- が、これはループ自身の脱出枝でしか読まれて
いないにも関わらずである。

**意図的に`Compiler.RC2.Loop`には統合しなかった。** ホイスティング
とは異なり、この書き換えは`value`がそもそもループ不変かどうかを一切
気にしない -- `v5`自身のフィールドは変化するループ搬送値でも構わず、
それでも同じ移動は正しい。なぜならこれは`value`が計算される回数を
*減らす*方向にしか働かないからである(「実際にそれを必要とする1つの
枝でのみ、到達した時にちょうど」まで減る)。動機となったパターン
(`let X = ... in case/cmp ...`、片方の枝は`X`を読み、もう片方は
読まない)は完全にループ非依存である。`tests/Test22BranchSinking.idr`
はこれを、ループがどこにも見当たらない通常の非再帰関数の中で演習
している。

**Sinking対Hoisting -- 逆方向で、補完的な適用範囲。**
`Compiler.RC2.Loop`自身のループ不変式のホイスティング
(`rc2/doc/loop-conversion.md`参照)は、計算をループの*外へ*動かし、
反復ごとに一度ではなく呼び出しごとに一度実行されるようにする。この
パスは計算をそれを必要とする1つの枝の*内側へ*動かし、その枝が実際に
到達された場合にのみ実行されるようにする -- さらに回数が少ない。
実際にはこの2つは同じ候補を奪い合わない: ホイスティングはループ本体
自身の無条件prefix(どの分岐よりも前)しか見ない。Sinkingは`let`の
直後に分岐が続く場合にのみ発火する。2つの分岐の*間*に座り、2番目の
分岐自身の枝のうち1つだけに使われる`let`は、まず沈められる(このパス
は`Compiler.RC2.Loop`の後に実行される、下記「パイプライン上の位置」
参照) -- 沈められる値がたまたまループ不変だったかどうかは、そこには
一切関係しない。

## アルゴリズム

`Compiler.RC2.Sink.applySinkExp`は木全体を最内側優先で歩く: ある
`RLet`自身の`body`は、`RLet`自身を沈めようとする*前に*完全に沈め
切られる。そのため`let a = .. in let b = f a in <branch>`という連鎖
は1パスで解決する -- まず`b`が自身の使用する1つの枝へ沈み、その後
`a`(今や同じ枝自身の、既に沈んだ`let b = ...`を通してのみ到達可能)
が、まさにその同じ場所のすぐ後ろへ沈む。不動点反復は不要であり、
これは`Compiler.RC2.Loop`自身の`hoistInvariantPrefix`の理由付け
(その関数自身のドキュメントコメント参照)を1段上で鏡写しにした
もの -- ただし方向は逆(ループの外へではなく、分岐の中へ)である。

### 任意の深さまで沈める、1段だけではなく

沈めが成功すると、その結果をそのまま返すのではなく、再び
`applySinkExp`へ通す。これは、`var`が沈む先の1つの枝自体が、`var`が
片側でしか読まれない別の分岐で始まっている場合に重要になる: 最初の
沈めの後、`var`自身の`RLet`は今やその枝の先頭に座り、分岐ノードを
ラップしている -- これはまさに`applySinkExp`自身の`RLet`ケースが
探している形なので、これを再度歩くことで`trySinkInto`が2回目に発火
でき、`var`をさらに1段深く着地させる。これは、同一の1パスの中で、
別個の不動点ドライバなしに、任意の数のネストした単一使用分岐を通して
連鎖する: 各成功が`var`自身の束縛を、有限な木の中の厳密により小さい
部分木へ厳密に移動させるので、再帰は常に停止する。
`tests/Test22BranchSinking.idr`自身の`deepSinkable`がこの専用テスト
である -- `ctx`は*2つの*ネストしたフラグが両方とも`True`の場合にのみ
読まれ、1回の`Compiler.RC2.Sink`実行で両方の分岐を通して沈む。

### `value`がそもそも候補かどうかの判定(`sinkEligible`)

裸の`ROp`/`RCon`/`RAppName`(`Compiler.RC2.Loop.isInvariantExpr`が
類似の理由で既に剥がしているのと同じ先頭の`RDup`/`RDrop`/`RFree`/
`RReleaseReuse`ラッパー形状を剥がした後)であり、同じ関数が使っている
のと同じ除外を、それが適用される場合には同じ理由で使う(意図的に
同期を保っており、再導出はしていない):

- `ROp`/`RAppName`自身の`lazy`フィールドは`Nothing`でなければ
  ならない -- 遅延演算の評価*タイミング*自体が観測可能だから。
- `RCon`自身の`reuseFrom`は`Nothing`でなければならない -- 特定の
  `RReuseOffer`自身の枝ごとのランタイム一意性チェックプロトコルと
  絡み合っており、このパスが移動させてよいものではないから。

**`RAppName`(通常の、名前付きの呼び出し)は、`Compiler.RC2.Loop`
自身のホイスティングが意図的にそれを除外しているにも関わらず、
ここでは適格である。** その除外は*ホイスティング*に固有のもの
である: 計算を、そうしなければ全く反復しないパスで完全にスキップ
していたかもしれないループより前に、無条件に、呼び出しごとに一度
実行されるよう動かすことだから(`rc2/doc/loop-conversion.md`自身の
「ループ不変式のホイスティング」節参照)。Sinkingは`value`が実行
される回数を*減らす*方向にしか働かない -- 「それを必要とする1つの
枝が実際に到達された場合にのみ」まで減る -- ので、いずれにせよ実行
されていたはずの呼び出しは、今や単にその1つの実際の使用箇所により
近く(そして到達した場合にのみ)実行されることが依然として保証されて
いる。ここでは「一度も実行されない」パスを「今や実行される」パスに
変えるものは何も無い。これはこのパス全体が既に依拠しているのと
同じ安全性の論拠である。`RApp`/`RUnderApp`(クロージャの適用/構築)
は明示的に対象外のままである -- 直接の名前付き呼び出しよりも多くの
機構(確保、トランポリン)が絡むため、ここでは解析していない。
`RExtPrim`(本物の`%World`を貫くエフェクト)は、沈められようと
なかろうと決して適格にならない。

呼び出しを沈めることには、このパス全体がこれまで必要としなかった
新しいインフラが1つ必要だった: `Sink.idr`は今や`SortedMap Int Rep`
(`reps`)を`applySinkExp`/`trySinkInto`/`trySinkIntoArms`を通して
糸通ししている -- 空で始まり(全てのトップレベル引数は真に
`RBoxed`であり、`localRepIn`自身の「見つからないidはデフォルトで
`RBoxed`」という規約に一致する。`Compiler.RC2.DualABI`自身の同名の
関数から直接鏡写しされている)、`RLet`(自身の宣言された`Rep`)と
`RLoop`(自身の`loopParams`)のたびに拡張される -- これは
`Compiler.RC2.Loop.fillLoopContinuePostDrop`/`Compiler.RC2.DualABI
.applyCallSiteRewriteBody`が既に糸通ししているのと同じ形である。
これは純粋に`consumedOperands`自身の利益のために存在する:
`postDrop`が自身のどのオペランドがBoxedかを既に列挙している`ROp`
とは異なり、`RAppName`にはそのようなフィールドが無い -- 自身の
引数は*全て*、呼び出しが実行された瞬間に無条件に消費される
(所有権が呼び出し先へ移譲される)ので、`consumedOperands`は、その
完全な引数リストを`addOperandDrops`へ渡す前に、`reps`が実際に
`RBoxed`だと確認しているものだけへ絞り込まなければならない --
既にネイティブな引数が`RDrop`自身の`vars`リストに現れることは決して
あってはならない。`tests/Test22BranchSinking.idr`自身の
`callSinkable`が専用のテストである: `buildMsg tag n`の呼び出しは
その結果を読む1つの枝へ沈み、もう一方の枝は代わりに明示的な
`drop [tag, n]`を得る。

### 各枝の分類(`stripIfUnused`、`genuinelyUsedR`)

各枝について、`var`は**Used**(その枝自身の本体のどこかで実際に
読まれる)、**DropOnly**(その枝はそれを読まないが、それに対する
古い`drop [var, ...]`を持つ -- `Compiler.RC2.RC`自身の`annotate`が、
このパスが実行されるより前に、そこでは未使用だと既に決めている)、
または**Absent**(それについて一切言及しない)のいずれかに分類
される。`genuinelyUsedR`は、`RCExp.idr`自身の`freeLocalsR`とは意図的
に区別されている: `RDrop`/`RFree`/`RReleaseReuse`自身の対象は、
これに対して*何も*寄与しない(`freeLocalsR`はそれを使用としてカウント
するが、それではあらゆる沈める候補がどこでも使われているように
見えてしまい、この目的にはまさに間違っている)。

Sinkingは、**ちょうど1つの枝がUsed**であり、他の全ての枝が
DropOnlyまたはAbsentである場合にのみ発火する。2つ以上がUsedの場合と
0個がUsedの場合はどちらも手つかずのまま残される(前者は得るものが
何も無い。後者は`var`が真にデッドコードであることを意味し、この
パスが片付けるべき問題ではない)。

**`var`は分岐自身の判定オペランドであってはならない**
(`isDecidingOperand`) -- `RCmpCase`自身の比較の引数、または
`RConCase`/`RConstCase`自身のスクルティニー。スクルティニーは
どの枝が実行される*前にも*評価されなければならないので、`value`が
まさに分岐の対象そのものを計算している場合、`value`を1つの特定の
枝へ沈めることは構造的に不可能である。これは開発中に捕まった本物の
バグだった: `let v1 = v0 - 1 in case v1 of 0 => ...; _ => (v0自身の
fibを計算するのにv1を使う)`(`tests/Test2Recursion.idr`自身の`fib`)
は、各枝自身の本体だけを走査する検査には、正確に「片方の枝がそれを
使う(`_`)、もう片方は使わない(`0`は二度と`v1`を読まない)」ように
見える -- `v1`自身の束縛を`_`枝へ沈めると、`v1`が一度も宣言される
前に`v1`を参照する`case v1 of ...`が生成され、未宣言識別子の
コンパイルエラーになった。`trySinkInto`は`trySinkIntoArms`を呼ぶ前に
`isDecidingOperand`を検査する。

### 書き換えそのもの、そしてそれを正しくするために必要だった第二の本物のバグ

沈めが形状的に安全だと確認されたら、`value`(自身の`var`/`rep`と
共に)は、Usedな1つの枝の先頭に`RLet`として再束縛される。全ての
DropOnlyな枝は、自身の`RDrop`の`vars`リストから`var`が取り除かれる
(それで空になればノード全体を除去する -- `removeVarDrop`は、先頭の
ラッパーを剥がすだけでなく*枝全体*を歩いてそれを見つける。これは
このパスが`Compiler.RC2.Reuse`と`Compiler.RC2.Loop`の両方の後に
実行されるためであり、どちらより前に実行されるためより浅い位置を
仮定できる`Compiler.RC2.ConAltNative`自身の`peelWrappers`とは異なる)。

**`value`自身が消費するオペランドにも、`value`が沈まない*全ての*枝
において同じ処理が必要である**(`consumedOperands`、
`addOperandDrops`)。これは、このパスを構築中に見つかった、
`valgrind`で確認された第二の本物のバグである:
`tests/Test9SelfTailLoop.idr`は`Prelude.Types.getAt`を推移的に取り込む
が、これは(沈める前は)`let v4 = op -Integer [v0, #1] postDrop=[v0]
in case v1 of Cons ... => ...v4...; Nil => (v4は未使用、なので`drop
[v4]`)`を持つ。`postDrop=[v0]`は、`value`自身の計算が`v0`を解放する
ものであることを意味する -- これまでは、その解放はループ自身の
無条件prefixの一部として、反復ごとに一度、無条件に起きていた。
`v4`の束縛をこの対処なしに`Cons`枝へ沈めると、`v0`が実際にその枝を
取る反復でのみ解放されるようになってしまう -- `Nil`では`v0`は一度も
読まれず(そこには`v4`について言及するものが何も無く、`v0`はそれを
計算することを*通して*しか到達可能でなかった)、解放もされない:
本物のリークである。`consumedOperands`は、`value`自身がそれを読む
際に消費していたはずの全てのBoxedオペランドを集める -- `ROp`自身の
`postDrop`リスト、または(先頭の`RDup`が既に追加の参照で保護した
どのidかを追跡しながら)先に`dup`されていない`RCon`のフィールド
(その唯一残る参照は独立して生き残るのではなく新しいコンストラクタ
へ直接移動する。`tests/Test19LoopInvariantParam.idr`に統合された旧
`Test21BoxedInvariantNotHoisted.idr`自身の
`dup v0; dup v1; con _ [v0, v1]`は両方のフィールドを先にdupするので、
正しくここには何も寄与しない)。`addOperandDrops`は、`value`が
沈まない全ての枝の先頭に、これらのための`drop`を付ける -- これは
`value`自身の`postDrop`/フィールド移動が毎回無条件に提供していた
解放を正確に置き換えるものである -- それらのうちの1つが既にそこで
独立に読まれているという、めったに起きないケースでは、沈めを完全に
取りやめる(`Nothing`)ことでフェイルセーフする(二重dropのリスクが
ある。ガードするコストはゼロで、実際には決して発火しないはずである)。

### 無関係な`let`越しに沈める

`trySinkInto`は、`var`自身の束縛と最終的な分岐の間に座る、何らかの
*無関係な*ローカル`y`のための先頭の`RLet`も透過する -- `let x = ..
in let y = (xを読まない) in <branch>` -- `y`をそのままの位置に残し、
それを通り越して`x`自身の使用する1つの枝を探索し続ける。このケース
は、それ自体では沈められなかったはずの`y`についてのみ発火する
(もし沈められたなら、`applySinkExp`自身の最内側優先の歩きが既に
`let y = .. in <branch>`をその分岐自体へ書き換え、`y`自身の束縛は
1つの枝の内側へ移動しているはず -- 上記「アルゴリズム」参照 -- なので
この`RLet`の形は、`y`が複数の枝で読まれる場合、またはそれ自体が
`sinkEligible`でない場合にのみ生き残る)。`y`自身の値が`var`を読む
場合は取りやめる(`Nothing`) -- その読み取りは、最終的にどの枝が
実行されるかに関わらず無条件に発生するので、`var`はどの枝より前に
真に必要とされている。これは`isDecidingOperand`が分岐自身の
スクルティニーに既に適用しているのと全く同じ理由付けである。
`tests/Test22BranchSinking.idr`自身の`skipUnrelatedLet`が専用のテスト
である: `x`自身の束縛は`y`自身のもの(`y`は両方の枝を読み、`x`は
`y`自身の計算には現れない)を通り越して届き、`x`を読む1つの枝の内側
に着地する。

### `var`自身の死を通り越して剥がさない

**このパス全体が生んだ中で単一の最も重要なバグであり、
`refc-suite/buffer`自身の`TestBuffer.idr`によって捕まった -- 単なる
リークではなく、本物のミスコンパイルである。** `trySinkInto`の
あらゆるラッパーケース(`RDup`/`RDrop`/`RFree`/`RReleaseReuse`/
`RReuseOffer`)は、今や、それを通り越して剥がす前に*自身の対象が
`var`自身であるかどうか*を検査し、そうであれば`Nothing`で取りやめる。

`TestBuffer.idr`は`do`記法で`IO ()`を返す一連の`Data.Buffer`関数
(`setByte buf 0 1; setBits8 buf 1 2; setBits16 buf 2 3; ...`)を呼び
出しており、それぞれ自身の`()`結果は即座に破棄される -- これは
`let v5 = call prim__setByte [...] in drop [v5]; let v6 = call
prim__setBits8 [...] in drop [v6]; let v7 = ...; let v8 = ...`という
形に下降し、その先で初めて無関係な分岐に到達する。ここでの各
`RDrop [vN]`は、`vN`自身の、単一の死であって、分岐へ向かう途中で
通り越すべき何か無関係な所有権帳簿ではない。ラッパー剥がし節の
*最初の*版(`trySinkInto reps var rep value (RDrop fc vs cont) = map
(RDrop fc vs) (trySinkInto reps var rep value cont)`、`vs`の検査
なし)は、「途中に座っている無関係なdrop」と「`var`自身のdrop」を
区別していなかった -- `v5`自身の死をそのまま通り抜けて探索を続け、
`v6`/`v7`/`v8`の同一の連鎖を通り抜け、遠く離れた無関係な分岐まで
たどり着き、そこに`v5`を沈めてしまった。生成されたCは`var_5`/
`var_6`/...を、それらが一度も宣言されていないスコープで参照して
おり -- これは静かなリークではなく未宣言識別子のコンパイルエラー
だった。なぜなら`v5`は実際の制御フローの中ではそこまで一度も到達
しないからである。`tests/Test22BranchSinking.idr`に統合された旧
`Test23SinkPastSelfDrop.idr`のケースは、
`Data.Buffer`とは独立した専用の回帰テストとして、全く同じ形
(結果が破棄される`IO ()`呼び出しの連鎖の後に、無関係な値を読む分岐
が続く)を直接再現する。

## パイプライン上の位置

`Compiler.RC2.Loop`(自己末尾呼び出し変換)の後、
`Compiler.RC2.DualABI`の前に実行される(`RC2.idr`自身の`toRCDefs`
参照) -- `RLoop`/`RLoopContinue`ノードが既に最終形になっている程度
には遅い(そのためこのパス単体が、ループ自身の本体の内側と、あらゆる
通常の非ループ関数の両方に一様に届く)が、`DualABI`が木自身の形状に
ついて推論する必要が生じるより前である。`genuinelyUsedR`/
`removeVarDrop`はどちらもまさにこの理由で`RLoop`/`RLoopContinue`
ケースを持つ -- このコードベース内の他の全ての木の歩行は
`Compiler.RC2.Loop`よりパイプライン上で前にあるので、一度もそれが
必要だったことがない。`--directive nosink`はこのステージだけを
無効化する。他の全てのオプションなステージと同じ規約による
(`RC2.idr`自身の`toRCDefs`のドキュメントコメント参照)。

## ファイル

- `rc2/src/Compiler/RC2/Sink.idr` -- パス全体:
  `genuinelyUsedR`/`removeVarDrop`/`stripIfUnused`(枝の分類と
  書き換え)、`consumedOperands`/`addOperandDrops`(上記の第二のバグ
  修正)、`sinkEligible`/`isDecidingOperand`(適格性のガード)、
  `trySinkInto`/`trySinkIntoArms`/`applySinkExp`/`applySink`(書き換え
  と木全体の歩行)。
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`自身のパイプライン配線。
- `rc2/src/Compiler/RC2/ConAltNative.idr` -- `peelWrappers`。このパス
  自身のラッパー剥がしケースが鏡写しにしている「先頭ラッパー、
  その後分岐」というイディオム。
- `tests/Test19LoopInvariantParam.idr`に統合された旧
  `Test21BoxedInvariantNotHoisted.idr`のケース -- 動機となったケース、
  自己末尾ループの内側(`Compiler.RC2.Loop`自身のループ不変式
  ホイスティングの負のケースとしても共有されている)。
- `tests/Test22BranchSinking.idr` -- 一般的な、ループ非依存のケース:
  1つの沈められる例、*沈んではいけない*1つの例(`var`が両方の枝で
  読まれる)、1パスで2つのネストした単一使用分岐を通して沈める
  `deepSinkable`(上記「任意の深さまで沈める、1段だけではなく」
  参照)、単純な`RAppName`呼び出しを沈める`callSinkable`(上記
  「`value`がそもそも候補かどうかの判定」参照)、無関係な`let`越しに
  沈める`skipUnrelatedLet`(上記「無関係な`let`越しに沈める」参照)。
  旧`Test23SinkPastSelfDrop.idr`もここに統合されており、このパスが
  生んだ中で最も深刻なバグ、リークではなく本物のミスコンパイルの
  専用回帰テスト(上記「`var`自身の死を通り越して剥がさない」参照)
  として、`refc-suite/buffer`自身の`TestBuffer.idr`の形(結果が即座に
  破棄される`IO ()`呼び出しの連鎖の後に、無関係な値を読む分岐が
  続く)を、`Data.Buffer`とは独立に直接再現する。
- `tests/Test2Recursion.idr`/`tests/Test9SelfTailLoop.idr`/
  `refc-suite/buffer/TestBuffer.idr` -- 既存のテスト(最初の2つは、
  それらが推移的に取り込むPrelude関数経由)であり、上記で文書化した
  4つの本物のバグのうち3つを捕まえた。最初の2つについては専用の
  新規回帰テストは不要だった。既存のフルスイート実行が既にその両方
  の形を演習しているため(3つ目の`TestBuffer.idr`自身の形について
  は、代わりに`Test22BranchSinking.idr`に統合された旧
  `Test23SinkPastSelfDrop.idr`が専用の回帰テストとして
  追加された。`refc-suite`だけに頼ってそれを捕まえ続けるのは、ここで
  見つかった単一の最も深刻なバグにしては間接的すぎると感じられた
  ため)。
