# ボックス化算術のインプレース再利用(`ROp` の `Integer`/`Int64`/`Bits64`/`Double` 演算)

(原文: `doc/rop-reuse.md`。内容が乖離した場合は原文を正とする。)

`ROp` のボックス化(GMP `mpz_t` 裏打ち)`Integer` 算術が今使う
ランタイムレベルの再利用機構の実装ノート。後にボックス化
`Int64`/`Bits64`/`Double`(固定サイズのスカラーペイロード、GMP
裏打ちではない -- 下記 "ランタイム契約の変更、拡張" を参照)へ
拡張された。将来のセッション(あるいは将来の自分)が設計を再導出
せずに完全な文脈を取り戻せるよう書かれている。`TODO.md` の旧
"Performance: `ROp`'s Boxed arithmetic never reuses a dying/unique
operand's own heap allocation" セクションを解消する(短い版と
これが従うクロージャの先例は `KNOWN-BUGS.md` の対応する "Retired:"
エントリを参照)。この文書が全体を通して意図的に対比する
コンストラクタのインプレース再利用パスについては
`doc/reuse-analysis.md` も参照。

## 問題(`TODO.md` が言っていたこと)

`RCon` 自身の `annotate` ケース(`Compiler.RC2.RC`)は既に `ROp`
より厳密に安いという所有権規約を使う:
`wrapDups fc (splitBorrows natives owned args) (RCon fc n ci tag args Nothing)`
-- `postDrop` が一切ない。`living` な引数はコンストラクタが構築
される前に `dup` される; `dying` な引数はそのまま渡され、所有権が
移り、呼び出し箇所の drop は一切生成されない。それはまさに、
`Compiler.RC2.Reuse` が、`free()` して再び `malloc()` する代わりに、
dying で一意参照されるコンストラクタ自身のヒープセルを転用する
ために利用する所有権の形状である。

対照的に `ROp` は、そのオペランドが呼び出しのまさにその場で
dying かつ一意参照されているかどうかにかかわらず、すべての
ボックス化オペランドに対して常に明示的な呼び出し後
`idris2rc2_drop`(`boxedOperands` 由来の `postDrop`)を出力して
いた。`rc2/support/rc2/numeric.c`/`numeric.h` のすべてのボックス化
数値プリミティブ(特に GMP 裏打ちの `Integer` 算術)は、
オペランド自身の `mpz_t` ヒープ割り当てが無料でインプレース再利用
できたときでさえ、常に `idris2rc2_mkInteger()` 経由で真新しい結果を
割り当てていた。

## 鍵となる設計上の洞察: なぜこれは IR 変更ゼロで済んだか

`Compiler.RC2.Reuse` が専用の IR パスとして、独自の
`RReuseOffer`/`RReleaseReuse` ノードとともに存在するのは、
コンストラクタ再利用の「オファー」と「クレーム」が IR の
**2 つの異なる場所**で起きるからである: オファーは `case` 式で
dying するスクルーティニー; クレームは、その `case` の alt 本体の
1 つで後に再構築される同形のコンストラクタ。両者を結ぶには、
シーケンスノードを歩き、ネストした case に再帰し、各ブランチを
独立に解決する前方探索(`Reuse.idr` の `tryConsume`/`tryClaim`)が
必要 -- 実際のツリー書き換え作業で、定義ごとに 1 回、出力に先立って
行われる。

`ROp` には橋渡しすべきそのようなギャップがない。ボックス化
オペランドの消費と新しいボックス化結果の生成は**同じ C 文**で
起きる -- 1 つのランタイム関数呼び出し
(`idris2rc2_add_Integer(x, y)` など)。探すべき「オファー、その後
クレーム」の形状は一切ない; オファー*が*クレームであり、同じ
プログラム地点である。結果として、この機能全体は **IR 変更ゼロ**
で済んだ:

- `RCExp.idr` の `ROp` ノード(その `postDrop : List RCLocal`
  フィールドを含む)は完全に無変更。
- `Compiler.RC2.RC` の `annotate` パス(Phase 2 所有権注釈)は
  完全に無変更。その既存の `ROp` ケース --
  `wrapDups fc (splitBorrowsV natives owned args) (ROp fc lazy op args (boxedOperands natives (toList args)))`
  -- は、その後もまだ必要な任意のオペランド(living または borrowed)
  のために呼び出し前に `dup` を挿入し、dying なオペランドを素で
  (dup なしで)渡す。これは*既に*再利用が土台にするのにちょうど
  正しい所有権移転の形状だった; 唯一おかしかったのは、その後
  その所有権に何が起きたか -- 無条件のコンパイラ出力 drop で、
  毎回再利用の機会を捨てていた。
- `Compiler.RC2.Reuse`(コンストラクタ再利用専用パス)は完全に
  無変更・手つかず。`ROp` とは何の関係もなく、今もない。

実装全体は 2 ファイルに閉じている: ランタイム契約
(`rc2/support/rc2/numeric.h`)と、その責任を引き継いだランタイム
プリミティブを持つ演算に対して今や冗長な drop 呼び出しの出力を
やめる、コンパイラ側の小さなスキップ
(`Compiler.RC2.Emit.Util`/`Compiler.RC2.Emit`)。

## ランタイム契約の変更(`rc2/support/rc2/numeric.h`)

10 個のボックス化 `Integer` ランタイムプリミティブが契約を変えた:
`add`、`sub`、`mul`、`mod`、`negate`、`and`(`BAnd`)、`or`
(`BOr`)、`xor`(`BXOr`)、`shiftl`、`shiftr` -- すべて
`idris2rc2_<name>_Integer`。以前: 読み取り専用で、呼び出し側が
その後両オペランドを別々に drop した。以後: 各々が今や自身の
ボックス化オペランドを*消費する* -- `idris2rc2_isUnique(x)`(
`runtime.h` が既に定義し、コンストラクタ再利用やクロージャの
インプレース拡張が既に依拠する同じランタイム refcount-is-1
チェック)を検査し、一意なら、そのオペランド自身の `mpz_t`
ストレージを宛先としてインプレース再利用する; そうでなければ、
以前とまったく同じく `idris2rc2_mkInteger()` で新しい割り当てに
フォールバックする。宛先として選ばれ*なかった*方のオペランドは、
今や呼び出し側ではなくプリミティブ自身によって drop される。

2 つの共有マクロが仕事をする。`IDRIS2RC2_INTEGER_BINOP`
(`add`/`sub`/`mul`/`mod`/`and`/`or`/`xor` が使う)は両オペランド
を検査する:

```c
#define IDRIS2RC2_INTEGER_BINOP(OPNAME, MPZFN)                                     \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { \
    IDRIS2RC2_Integer *dst = idris2rc2_isUnique(x) ? (IDRIS2RC2_Integer *)x        \
                            : idris2rc2_isUnique(y) ? (IDRIS2RC2_Integer *)y       \
                            : idris2rc2_mkInteger();                               \
    MPZFN(dst->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v);       \
    if ((IDRIS2RC2_Value *)dst != x) idris2rc2_drop(x);                           \
    if ((IDRIS2RC2_Value *)dst != y) idris2rc2_drop(y);                           \
    return (IDRIS2RC2_Value *)dst;                                                \
  }
```

dst 選択の三項演算子は意図的に x 優先である: 同時に一意な 2 つの
オペランドのどちらが勝つかは重要でない(どちらもいずれにせよ
消費される寸前)ので、タイブレークは任意であり、単に一貫していれば
よい。どちらのソースを `dst` として再利用しても、ここでどの
`mpz_*` 関数が使われようと安全である。GMP 自身の文書化された契約
が、その `mpz_*` 関数は宛先がどちらのソースオペランドにエイリアス
することも許容する、というものだからである -- このマクロは
`mpz_add`/`mpz_sub`/等の偶発的な性質に依拠しているのではなく、
マクロ生成されたファミリー全体で一様に成り立つ文書化された GMP
保証に依拠している。

`IDRIS2RC2_INTEGER_SHIFTOP`(`shiftl`/`shiftr`)は `x`、つまり
シフトされる値だけを検査する -- `y`、シフト量は検査しない:

```c
#define IDRIS2RC2_INTEGER_SHIFTOP(OPNAME, MPZFN)                                   \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { \
    IDRIS2RC2_Integer *dst = idris2rc2_isUnique(x) ? (IDRIS2RC2_Integer *)x : idris2rc2_mkInteger(); \
    MPZFN(dst->v, ((IDRIS2RC2_Integer *)x)->v, (mp_bitcnt_t)mpz_get_ui(((IDRIS2RC2_Integer *)y)->v)); \
    if ((IDRIS2RC2_Value *)dst != x) idris2rc2_drop(x);                           \
    idris2rc2_drop(y);                                                            \
    return (IDRIS2RC2_Value *)dst;                                                \
  }
```

`y` はここで再利用候補にならない: シフト回数はシフトされた結果とは
違う*種類*の値であり(その大きさは結果の GMP-limb ストレージの
ホストとして無意味)、実際上それは常に小さなキャッシュされた
不滅の `Integer` であり、それに対して `idris2rc2_isUnique` は
いずれにせよ常に false -- 検査しても決して発火しないので、マクロは
気にしない。

`negate_Integer` は同じパターンの小さな手書きの単項版
(`mpz_neg`)で、ファミリー唯一の単項メンバーなのでマクロ生成
されていない。

`idris2rc2_div_Integer` -- このヘッダの 1 行ではなく `numeric.c`
の本物の複数文ユークリッド除算アルゴリズム -- は意図的にスコープ
外にされた; 下記 "スコープ" を参照。

**実装前の安全性チェック**: `rc2/support/rc2/*.c`/`*.h` を grep
して、これら 10 関数のいずれも生成された `ROp` lowering コード
以外の呼び出し側を持たないことを確認したので、他の呼び出し側の
期待を壊さないための新しい `_consume` 接尾辞名なしに、その契約を
インプレースで変えられた。

## ランタイム契約の変更、拡張: `Int64`/`Bits64`/`Double`

下記 "スコープ" セクションは以前 `Double`/`Int64`/`Bits64` 再利用を
「自然だがまだ試みていない追随」として挙げていた。これは今や
行われ、それを解消した。機構は上記の `Integer` ケースより構造的に
単純である。これら 3 型は固定サイズのスカラーペイロード --
`{ IDRIS2RC2_Header header; <int64_t/uint64_t/double> v; }` -- で
あり、独自の変更関数を必要とする GMP `mpz_t` ではないからである。
これらの「インプレース再利用」は、構造体自身の `v` フィールドを
直接上書きして同じポインタを返すだけである; 呼ぶべき GMP 風の
limb をインプレース変更するステップはない。

### `IDRIS2RC2_INTTYPES` の分割: なぜそれが必要だったか

この変更の前、`rc2/support/rc2/numeric.h` は
`Add`/`Sub`/`Mul`/`ShiftL`/`ShiftR`/`BAnd`/`BOr`/`BXOr` を、1 つの
X マクロ `IDRIS2RC2_INTTYPES(F)` 経由で 8 つの固定幅 int 型
(`Int8/16/32/64`、`Bits8/16/32/64`)すべてに一様に生成していた。
その一様な扱いは、再利用消費演算が絡むともはや正しくない:
`Int8/16/32` と `Bits8/16/32` は `Types.alwaysUnboxed` である
(`doc/native-type-inference.md` を参照)-- C レベルでは常に
タグ付きポインタで、決して本物のヒープ割り当てではない
(`datatypes.h` の `idris2rc2_is_unboxed` ビットチェックが両者を
区別する)。これらのタグ付き値の 1 つに対して `idris2rc2_isUnique`
(生の `->header.refCount` 読み取り)を呼ぶと、偽のポインタを通して
読むことになる -- 単に誤りなのではなく未定義動作である。

修正は 1 つの X マクロを 2 つに分けることだった:

- `IDRIS2RC2_INTTYPES_TAGGED(F)` -- 6 つの常に unboxed な型
  (`Int8/16/32`、`Bits8/16/32`)、振る舞い無変更、今も元の
  `IDRIS2RC2_DEFOP` マクロから構築される。これらに `isUnique`
  チェックは決して起きない。
- `IDRIS2RC2_INTTYPES_REUSABLE(F)` -- `Int64`/`Bits64` のみ、値が
  小整数キャッシュ `[0,100)` を越えたら本当にヒープ割り当てされる
  2 つの固定幅 int 型。

新しいマクロ `IDRIS2RC2_DEFOP_REUSE(OPNAME, TY, CTY, GET, MK, OP)`
が再利用可能ペアの再利用消費版を生成する。上記
`IDRIS2RC2_INTEGER_BINOP` とまったく同じ「`a` について
`idris2rc2_isUnique` を検査し、次に `b`、さもなくば新しく割り当てる」
形状に従うが、GMP 関数を `dst->v` mpz_t へ呼ぶ代わりに
`((IDRIS2RC2_##TY *)a)->v = result` を直接変更する。

`Double` はそもそも小整数キャッシュされない -- `idris2rc2_mkDouble`
は常に新しく割り当てる -- のでそもそも tagged/reusable 分割を
必要とせず、`add`/`sub`/`mul`/`div` 用の独自の
`IDRIS2RC2_DOUBLE_BINOP(OPNAME, OP)` マクロを得た。

### `Div`/`Mod` と `Neg`、今回

`Int64` のユークリッド div/mod と `Bits64` の素の div/mod は、
`Integer` 自身の `idris2rc2_div_Integer`(本物の複数文 GMP
アルゴリズム、今も除外 -- "スコープ" を参照)と違い、このヘッダの
自明な 1 行である。今回 `Int64`/`Bits64` の `Div`/`Mod` を除外する
理由はなかったので、両方とも残りと並んで再利用消費形状に変換された。

`Neg` は `Int64`/`Double` について変換された(手書きの単項版、
`negate_Integer` と同じフィールド上書きパターン)。`Bits64` には
`negate` が一切ない。既存の振る舞いに一致 -- 符号なし型には
`negate` がない。

### コンパイラ側: `isReuseConsumingOp` が対応するケースを得る

`Compiler.RC2.Emit.Util` の `isReuseConsumingOp` は
`Int64Type`/`Bits64Type`/`DoubleType` のケースを得た。各々、その型
が実際に持つ演算だけをちょうどカバーする: `Bits64Type` はビット
演算を得るが `Neg` はなし(その型に `negate` はない);
`DoubleType` は `Add`/`Sub`/`Mul`/`Div`/`Neg` を得るが
`Mod`/ビット演算はなし(`Double` にはどちらもない)-- Idris2
自身の型ごとの利用可能演算の集合に一致する。

## 見つかった本物のバグ: `IntType` と `Int64Type` が C 名を共有する

これはこの拡張から持ち帰るべき最も重要なことであり、脚注ではなく
独自のセクションに値する。

`Emit.Util.cPrimType` は `IntType`(Idris2 の素のマシン幅 `Int`)
**と** `Int64Type` の**両方**を、同一の C 関数名接尾辞 `"Int64"`
にマッピングする。`Add IntType` と `Add Int64Type` は両方とも
まったく同じ `idris2rc2_add_Int64` への呼び出しに lowering される
-- ランタイム関数は 1 つだけで、2 つの異なる `PrimType` に共有
される。

この実装の最初のパスは `Int64Type` のケースだけを
`isReuseConsumingOp` に追加し、`IntType` を完全に見落とした --
一見それが明白/完全な集合に見えた。`IntType` は `numeric.h` の
どこにも独立して現れないからである。しかし `numeric.h` の
`idris2rc2_add_Int64`(とその兄弟)は今や、IR レベルの呼び出しが
どの `PrimType` に由来するかにかかわらず、*すべての*呼び出し側に
対して、内部で無条件に自身のオペランドを消費・drop する。一方
`Compiler.RC2.Emit` の `ROp` ケースは `isReuseConsumingOp` が
認識しない任意の演算に対してその古い明示的な呼び出し後 drop を
今も出力していた -- `IntType` が欠けているので、それは*すべての
素の `IntType` 演算*を意味した。ランタイムは既にオペランドを
drop した; コンパイラ出力コードがそれをもう一度 drop した。これは
単に見逃した最適化ではなく本物の**二重 drop / use-after-free
バグ**である -- 共有/エイリアスされたランタイム関数名の契約変更
には、その同じ C 名にマッピングされる*すべての* `PrimType` を
コンパイラ側ゲートが認識する必要があり、「本物の」所有者に見える
1 つだけではない。

これはフル `verify.sh` 回帰実行で捕捉された: 4 つの既存の、
以前は通っていたテスト -- `Test16LoopContinuePostDrop`、
`Test19LoopInvariantParam`、`Test3Data`、`Test9SelfTailLoop` -- が
誤った出力を生成し始めた。クラッシュではない: use-after-free
からの破損した値で、解放されたメモリが実際にリークするのではなく
再利用/まだマップされていたので、valgrind の下でも
"definitely lost" 0 バイトのまま。これは、このクラスのバグを
捕捉するのに valgrind のリーク検出だけに依拠することの本物の
ギャップとして言及する価値がある -- 二重 free/UAF は常にリーク
として現れるとは限らない。

`isReuseConsumingOp` のすべての `Int64Type` ケースと並んで同一の
`IntType` ケース集合を追加し、将来追加される任意の演算に対して
2 つの `PrimType` を常に歩調を合わせて保たなければならない理由を
説明する doc コメントを `isReuseConsumingOp` 自身に付けて修正。
修正後、フル `verify.sh --regen-expected` は 89/89 passing に戻った。

## コンパイラ側の変更: `isReuseConsumingOp` と `Emit.idr` のスキップ

`Compiler.RC2.Emit.Util` は 1 つの新しい純粋関数を得た:

```idris
isReuseConsumingOp : PrimFn arity -> Bool
isReuseConsumingOp (Add IntegerType)  = True
isReuseConsumingOp (Sub IntegerType)  = True
isReuseConsumingOp (Mul IntegerType)  = True
isReuseConsumingOp (Mod IntegerType)  = True
isReuseConsumingOp (Neg IntegerType)  = True
isReuseConsumingOp (BAnd IntegerType) = True
isReuseConsumingOp (BOr IntegerType)  = True
isReuseConsumingOp (BXOr IntegerType) = True
isReuseConsumingOp (ShiftL IntegerType) = True
isReuseConsumingOp (ShiftR IntegerType) = True
isReuseConsumingOp _ = False
```

上記 10 個のランタイム関数に 1:1 で一致する、ちょうど 10 個の
演算に `True`; それ以外すべて(遅延された `Div IntegerType`、
"スコープ" を参照、およびすべての非 `Integer` 演算を含む)に
`False`。

`Compiler.RC2.Emit` の `emitRC (ROp fc _ op args postDrop)` ケース
(ボックス化 `ROp` lowering ケース)は今、通常の呼び出し後
クリーンアップの前に `isReuseConsumingOp op` を検査する: 通常は
プリミティブ呼び出しを出力した後に 2 つの `removeVars` 呼び出しを
する -- 1 つは `postDrop` の永続的ボックス化ローカルのため、1 つは
`boxOpArg` が Native オペランドのために作らなければならなかった
一時的な native-to-Boxed 一時のため。`isReuseConsumingOp op` が
`True` なら、両方の `removeVars` 呼び出しが完全にスキップされる:
ランタイムプリミティブが今や、永続的ローカルであれ一時的なもので
あれ、渡されたすべてのオペランドの処分を所有する。(実際上
`boxOpArg` はこれら 10 演算の 1 つに対して一時的なものを実際には
決して生成しない。`Integer` は決して native 適格でない --
`doc/native-type-inference.md` の `nativeEligible` を参照 -- ので、
そもそも `boxOpArg` がボックス化する Native-`Integer` オペランド
がない。スキップはいずれにせよ、観測される振る舞いで実際には
決して違わない 2 つ目のより狭い条件を追加するのではなく、
統一性のために両呼び出しにわたって無条件である。)
`isReuseConsumingOp op` が `False` なら、振る舞いは完全に無変更:
古い明示的 drop 出力は、この変更前とまったく同じく今も走る。

## 複数出現の安全性(`x + x` 風の自己参照式)

`ROp.postDrop` 自身の doc コメントが既にこのケースを指摘する:
同じボックス化ローカルが 1 つの演算内で二度読まれるとき、
「二度読まれるオペランド ... は二度現れる」。既存の無変更の
`wrapDups`/`splitBorrows` 機構が既に、2 つ目の論理的使用を表す
ために 2 つの出現の一方に `dup` を挿入する -- つまり両出現が
ランタイム呼び出しに達する時点でローカルの refcount は既に
少なくとも 2 であり、どちらの出現に対する `idris2rc2_isUnique` も
正しく false を返す。`x + x` に対して誤った再利用は起こり得ない:
どちらの出現も一意に見えないので、プリミティブはこの変更前と
まったく同じく新しい割り当てにフォールバックする。

プリミティブはその後、たまたま同じポインタ値を保持するか
どうかにかかわらず、2 つのパラメータ位置の各々を独立に drop する
-- これは古い `postDrop` の 2 エントリのコンパイラ出力 drop の
振る舞いが既に行っていたこと(同じポインタに対する 2 つの別々の
drop 呼び出し。先行する `dup` によって 2 つの論理的使用が既に
2 つの参照に分けられていたので正しい)にちょうど一致し、単に
コンパイラ出力コードからプリミティブに移されただけである。この
形状のためにどこにも特別扱いは必要なかった。

## 並行性の安全性

`idris2rc2_isUnique` は既に `idris2rc2_tailcallApplyClosure`
(クロージャのインプレース拡張)とコンストラクタ再利用に使われて
おり、両方とも同じ不変条件の下にある: refcount-is-1 チェック自体
が並行性の下でこれを安全にするものではない -- rc2 自身の
コンパイル時活性証明(この特定の呼び出しはオペランドの最後の使用
だと静的に分かっているので、レースする他の参照は存在し得ない)が、
別のスレッドが同じ refcount を並行に変更することなく現在のスレッド
がそのチェックに基づいて行動して安全である理由である。この `ROp`
拡張はまったく同じ既存の不変条件に依拠し、新しい並行性
プリミティブを一切導入せず、並行性関連コードへの変更を必要と
しなかった(`doc/concurrency.md` を参照)。

## スコープ: 意図的に除外されたもの

- **`Div IntegerType`**(`idris2rc2_div_Integer`)。`numeric.c` に
  おけるその実装は、上記 10 演算のような 1 行マクロ具現化ではなく
  本物の複数文ユークリッド除算アルゴリズムである -- 同じやり方で
  拡張するのはより込み入っており、この変更に折り込まず意図的に
  遅延された。
- ~~**`Double`/`Int64`/`Bits64` 再利用。**~~ 完了 -- 上記
  "ランタイム契約の変更、拡張: `Int64`/`Bits64`/`Double`" を参照。
  (削除ではなく取り消し線を残してあるので、この文書の履歴を追う
  読者は、この項目が自らを解消した追随作業だったと分かる。)
- **ピン留めされた参照の `negate` タイポ、この拡張のテスト中に
  発見。** `Int64`/`Bits64`/`Double` 拡張自身のテスト(今は
  `Test49IntegerOpReuse.idr` に統合)を書いている間、ピン留め
  された参照 `idris2 --cg refc` 0.8.0 自身のインストール済み
  `mathFunctions.h` が `idris2_nagate_Int8/16/32/64` と
  `idris2_nagate_Double` -- 綴り間違い("nagate")-- をマクロとして
  定義する一方、同じピン留め参照自身のコード生成は正しく綴られた
  `idris2_negate_<...>` への呼び出しを出力すると判明した。結果
  として、固定幅 int または `Double` 型で `negate` を使う任意の
  Idris2 プログラムは、その 1 つのピン留めバイナリに対して
  *リンク*に失敗する。これは rc2 ではなくピン留め参照バイナリの
  欠陥である(`rc2/support/rc2/numeric.h` 自身の
  `idris2rc2_negate_Int64`/`negate_Double` は正しく綴られており
  影響なし)ので、`Test49IntegerOpReuse.idr` の固定幅拡張関数は
  単に `negate` を一切行使しない -- 同じファイルの元の `Integer`
  型の `bigFactorial` の `negate` 使用が既に一般的な再利用消費
  `Neg` パターンをカバーしており、`Integer` の
  `idris2_negate_Integer` はマクロではなく本物の関数なので、この
  タイポの影響を受けない。完全な解説は `TODO.md` の
  "Pinned reference `idris2 --cg refc` 0.8.0 misspells `negate`
  for fixed-width/`Double` types" エントリを参照。
- **`boxOpArg` の一時的なもの再利用は既に含まれており、除外されて
  いない。** 上述の通り、`Emit.idr` のスキップは `postDrop` と
  `boxOpArg` の一時的なものを一様にカバーする; より狭い条件を
  切り出す必要はなかった。`Integer` はそもそも `boxOpArg` が
  ボックス化する Native オペランドを決して生成しないからである。
  将来の読者が一様なスキップを見落としと誤解しないよう、ここで
  明示的に言及する。

## 実施した検証

- 事前に `rc2/support/rc2/*.c`/`*.h` を grep し、10 個の対象関数の
  いずれも生成された `ROp` lowering コード以外の呼び出し側を
  持たないことを確認 -- その契約をインプレースで変えて安全。
- 新しい回帰テスト: `rc2/tests/Test49IntegerOpReuse.idr` --
  `bigFactorial`(小整数キャッシュ `[0,100)` と 64 ビット範囲の
  両方を越える自己末尾再帰アキュムレータ、なので本物の GMP
  ヒープ割り当て)に加えて `bigBitOps`(`Data.Bits` の
  `Bits Integer` インスタンス経由で
  `Mod`/`BAnd`/`BOr`/`BXOr`/`ShiftL`/`ShiftR` を行使 -- このテスト
  スイートのどこでもこれらの `Integer` 演算のいずれかが小整数
  キャッシュの大きさを越えて行使されたのは初めて)。`verify.sh`
  の `LEAK_SENSITIVE_TESTS` に登録。
- フル `verify.sh --regen-expected`: 87/87 pass(85 から増加、
  +Test48 と +Test49 -- Test49 はピン留め参照
  `idris2 --cg refc` に対してクリーンに diff し、`bigFactorial` の
  add/sub/mul だけでなく、書き換えられたすべてのプリミティブの
  機能的正しさを確認)。
- `refc-suite/run.sh`: 19/19 pass。
- `Test49IntegerOpReuse` に対する `valgrind --leak-check=full`:
  深い自己末尾再帰が GMP バッファを繰り返し再利用/drop するにも
  かかわらず definitely lost 0 バイト。
- 生成 C を手で検査
  (`rc2/tests/build/Test49IntegerOpReuse_rc2.c`):
  `Main_bigFactorial` のホットループが
  `idris2rc2_sub_Integer`/`idris2rc2_mul_Integer` を、その後に
  `idris2rc2_drop` 呼び出しが*一切ない*状態で呼ぶことを確認
  (以前はすべてのボックス化 `ROp` 呼び出しの後に必ず明示的な
  drop が続いた)-- そして `bigBitOps`/`negate` テスト行の
  `and_Integer`/`or_Integer`/`xor_Integer`/`shiftl_Integer`/
  `shiftr_Integer`/`mod_Integer`/`sub_Integer`-as-`negate` 呼び出し
  についても同じく末尾 drop がないことを確認。一方
  `Prelude_Types_prim__integerToNat`(比較 `idris2rc2_lte_Integer`
  を使う既存の手つかずの関数 -- この変更のスコープ外、
  `isReuseConsumingOp` にない)は今も古い明示的 `idris2rc2_drop`
  呼び出しを無変更で出力することを確認し、スコープが精密であること
  を示した: 対象の 10 演算だけが振る舞いを変えた。
- 再利用自体は、ライブの割り当て数計測実験ではなく直接のコード
  読みで確認した -- その実験は検討され不要と判断された。構造的
  証拠が既に機構を完全に固定しているからである:
  `IDRIS2RC2_INTEGER_BINOP` の dst 選択三項演算子がどのオペランド
  のストレージが宛先になるかを直接決定し、生成 C が、所有権解析が
  保証するちょうどその refcount でプリミティブが呼ばれることを
  確認する。

## 実施した検証(拡張: `Int64`/`Bits64`/`Double`)

- 回帰テストのカバレッジを `rc2/tests/Test49IntegerOpReuse.idr` に
  追加(そのファイルの末尾に統合)--
  `sumInt64`/`sumBits64`/`sumDouble`(小整数キャッシュを越える
  自己末尾再帰アキュムレータループ)に加えて
  `bitOpsInt64`/`bitOpsBits64`(直線的な `Data.Bits` 使用:
  `.&.`/`.|.`/`xor`/`shiftL`/`shiftR`/`div`/`mod`)。
- `sumInt64`/`sumBits64`/`sumDouble` は、ボックス化再利用消費
  プリミティブではなく `Compiler.RC2.Loop` 自身の native-shadow
  ループ昇格をほとんど行使すると判明した: ループ本体全体が素の
  unboxed `int64_t`/`double` の C ローカルになる。
  `rc2/tests/build/Test49IntegerOpReuse_rc2.c` の
  `idris2rc2_worker_Main_sumInt64_0` を検査して確認、その本体は
  ボックス化呼び出しが一切ない純粋な native 算術である。
- `bitOpsInt64`/`bitOpsBits64` が、実際上ボックス化再利用消費経路
  を実際に行使するもので、特に `div`/`mod` 経由: Idris2 の
  `Prelude.Num` の `Integral` インタフェースディスパッチは、
  これらが `+`/`-`/`*`/ビット演算のように native 演算子として
  インライン化されないことを意味する。
  `idris2rc2_worker_Prelude_Num_div_Integral_Int64_7` の生成された
  本体は、末尾の `idris2rc2_drop` 呼び出しなしで
  `idris2rc2_div_Int64(var_0, opBox_66)` を直接呼ぶ(手で確認)--
  消費プリミティブ契約とコンパイラ側スキップが、`Int64`、そして
  延長して `IntType`(同一の C 名)について、両方ともエンド
  ツーエンドで正しく配線されている証拠。同じパターンが
  `idris2rc2_mod_Bits64`/`div_Bits64` について独立に確認され、
  両方とも `rc2/tests/build/Test49IntegerOpReuse_rc2.c` の 877 行
  と 937 行に末尾 drop なしで存在する。
- `Neg` は、上記および `TODO.md` に記述されたピン留め参照の
  `negate` タイポのため、固定幅拡張カバレッジで意図的に一切
  行使しなかった。
- フル `verify.sh --regen-expected`: 89/89 pass(87 + 新しい
  固定幅拡張カバレッジ; これは `IntType`/`Int64Type` 二重 drop
  修正も再確認する。回帰した 4 つのテストを passing に戻したのが
  それだからである)。
- `refc-suite/run.sh`: 19/19 pass。
- `Test49IntegerOpReuse`(固定幅拡張カバレッジ)に対する
  `valgrind --leak-check=full`: definitely lost 0 バイト。

## ファイル

- `rc2/support/rc2/numeric.h` -- `IDRIS2RC2_INTEGER_BINOP`、
  `IDRIS2RC2_INTEGER_SHIFTOP`、`idris2rc2_negate_Integer`、および
  2 つのマクロから構築される 10 個の具現化。また(拡張):
  `IDRIS2RC2_INTTYPES_TAGGED`/`IDRIS2RC2_INTTYPES_REUSABLE`(旧
  単一 `IDRIS2RC2_INTTYPES` の分割)、`IDRIS2RC2_DEFOP_REUSE`、
  `IDRIS2RC2_DOUBLE_BINOP`、そして手書きの `Int64`/`Double`
  `negate`。
- `rc2/src/Compiler/RC2/Emit/Util.idr` -- `isReuseConsumingOp`、
  (拡張)`Int64Type`/`Bits64Type`/`DoubleType` のケースと、
  二重 drop バグ修正で追加された対応する `IntType` ケースを含む。
- `rc2/src/Compiler/RC2/Emit.idr` -- `emitRC (ROp ...)` の
  `isReuseConsumingOp` でゲートされた両 `removeVars` 呼び出しの
  スキップ。
- `rc2/tests/Test49IntegerOpReuse.idr` -- `Integer` 機構と(同じ
  ファイルの末尾に統合された)`Int64`/`Bits64`/`Double` 拡張の
  両方の回帰テスト。
- 明示的に手つかず: `rc2/src/Compiler/RC2/RCExp.idr`(`ROp` 自身の
  形状)、`rc2/src/Compiler/RC2/RC.idr`(`annotate` の `ROp`
  ケース)、`rc2/src/Compiler/RC2/Reuse.idr`(コンストラクタ再利用
  専用、無関係)-- ここで明示的に言及するのは、「何が変わる必要が
  なかったか」がこの文書の要点そのものだからである。
