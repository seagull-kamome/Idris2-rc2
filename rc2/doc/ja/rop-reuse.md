# Boxed算術のインプレース再利用(`ROp`の`Integer`/`Int64`/`Bits64`/`Double`演算)

(原文: `doc/rop-reuse.md`。内容が乖離した場合は原文を正とする。)

`ROp`がBoxed(GMPの`mpz_t`を使う)`Integer`の算術に用いている、ランタイムレベルの再利用の仕組みについて、実装上の注意点をまとめる。この仕組みは後に、Boxedの`Int64`/`Bits64`/`Double`にも拡張された(これらはGMPではなく固定サイズのスカラーをペイロードに持つ。後述の「ランタイム契約の変更(拡張): `Int64`/`Bits64`/`Double`」を参照)。将来の担当者(将来の自分を含む)が、設計を一から導き直さずに全体の事情を把握できるように書いている。

これは、`TODO.md`にあった旧項目 "Performance: `ROp`'s Boxed arithmetic never reuses a dying/unique operand's own heap allocation" を完了させるものである。この文書が全体を通して意図的に対比に使っている、コンストラクタのインプレース再利用パスについては、`doc/reuse-analysis.md`も参照すること。

## 問題(`TODO.md`に書かれていたこと)

`RCon`自身の`annotate`のケース(`Compiler.RC2.RC`)は、すでに`ROp`より厳密に安価な所有権規約を使っている。`wrapDups fc (splitBorrows natives owned args) (RCon fc n ci tag args Nothing)`であり、`postDrop`がまったくない。

- `living`な引数(呼び出しのあとも使われる引数)は、コンストラクタを構築する前に`dup`される。
- `dying`な引数(その呼び出しが最後の使用になる引数)は、そのまま渡されて所有権が移り、呼び出し側のdropは一切生成されない。

`Compiler.RC2.Reuse`が、dyingで一意に参照されているコンストラクタ自身のヒープセルを、`free()`と`malloc()`をやり直す代わりに転用できるのは、この所有権の形を利用しているからである。

一方`ROp`は、これまで、Boxedのオペランドごとに、呼び出し後の明示的な`idris2rc2_drop`(`boxedOperands`から導出した`postDrop`)を必ず出力していた。そのオペランドが呼び出しの時点でdyingで一意に参照されているかどうかは関係なかった。`rc2/support/rc2/numeric.c`/`numeric.h`にあるBoxedの数値プリミティブ(特にGMPを使う`Integer`の算術)は、オペランド自身の`mpz_t`のヒープ領域をそのまま再利用できる場合でも、必ず`idris2rc2_mkInteger()`で新しい結果を確保していた。

## 設計上の鍵: IRの変更がまったく要らなかった理由

`Compiler.RC2.Reuse`は、専用の`RReuseOffer`/`RReleaseReuse`ノードを持つ、独立したIRパスとして存在する。コンストラクタ再利用の「オファー」と「クレーム」が、IRの**2つの異なる場所**で起きるからである。オファーは`case`式でdyingするスクルーティニーであり、クレームは、その`case`のalt本体のどれかで、あとから同じ形のコンストラクタを組み立てる箇所である。

2つを結びつけるには前方探索が必要になる(`Reuse.idr`の`tryConsume`/`tryClaim`)。この探索は、逐次実行を表すノードをたどり、ネストしたcaseに入り込み、すべての分岐を個別に解決する。これは、定義ごとに、エミットの前に1回行う、本格的な木の書き換えである。

`ROp`には、橋渡しすべきこのような隔たりがない。Boxedオペランドの消費と、新しいBoxed結果の生成は、**同じC文**の中で起きる。呼ぶのは1つのランタイム関数(`idris2rc2_add_Integer(x, y)`など)である。「オファーのあとでクレームが来る」という形を探す必要がそもそもなく、オファーがそのままクレームであり、プログラム上の同じ地点で起きる。したがって、この機能に必要なIRの変更は**ゼロ**だった。

- `RCExp.idr`の`ROp`ノード(`postDrop : List RCLocal`フィールドを含む)は、まったく変わっていない。
- `Compiler.RC2.RC`の`annotate`パス(Phase 2の所有権注釈)も、まったく変わっていない。その既存の`ROp`のケースは`wrapDups fc (splitBorrowsV natives owned args) (ROp fc lazy op args (boxedOperands natives (toList args)))`で、呼び出しのあとも必要なオペランド(livingまたはborrowed)には、呼び出しの前に`dup`を挿入する。dyingのオペランドは、dupせずそのまま渡す。これは、再利用を載せるのに*すでに*ちょうどよい所有権移転の形になっていた。おかしかったのは、その所有権がそのあとどうなるかだけである。コンパイラが無条件にdropを出力していたため、再利用の機会を毎回捨てていた。
- `Compiler.RC2.Reuse`(コンストラクタ再利用だけを扱うパス)も、まったく変わっておらず、手を入れてもいない。`ROp`とは何の関係もなく、今もそのままである。

実装全体は2つのファイルに収まる。1つはランタイム契約(`rc2/support/rc2/numeric.h`)である。もう1つは、コンパイラ側の小さなスキップ(`Compiler.RC2.Emit.Util`/`Compiler.RC2.Emit`)で、ランタイムのプリミティブがその責務を引き取った演算について、冗長になったdrop呼び出しの出力をやめる。

## ランタイム契約の変更(`rc2/support/rc2/numeric.h`)

Boxedの`Integer`のランタイムプリミティブ10個の契約を変更した。`add`、`sub`、`mul`、`mod`、`negate`、`and`(`BAnd`)、`or`(`BOr`)、`xor`(`BXOr`)、`shiftl`、`shiftr`で、いずれも`idris2rc2_<name>_Integer`である。

変更前は読み取り専用で、呼び出し側があとで2つのオペランドを別々にdropしていた。変更後は、それぞれがBoxedのオペランドを*消費*する。`idris2rc2_isUnique(x)`で確認し(`runtime.h`がすでに定義している、参照カウントが1かどうかというランタイムの検査で、コンストラクタ再利用とクロージャのインプレース成長がすでに依拠している)、一意であれば、そのオペランド自身の`mpz_t`の領域を、宛先としてその場で再利用する。一意でなければ、従来どおり`idris2rc2_mkInteger()`で新しく確保する。宛先に選ばれなかったほうのオペランドは、呼び出し側ではなく、プリミティブ自身がdropする。

作業の中心は2つの共有マクロである。`IDRIS2RC2_INTEGER_BINOP`(`add`/`sub`/`mul`/`mod`/`and`/`or`/`xor`で使う)は、両方のオペランドを調べる。

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

宛先を選ぶ三項演算子は、意図的にxを先にしている。2つのオペランドが同時に一意である場合、どちらが選ばれても、両方ともどのみち消費されるので問題はない。したがってタイブレークは任意でよく、一貫していればよい。

どちらのソースを宛先に再利用しても安全であり、これは、ここで使う`mpz_*`関数が何であっても変わらない。GMP自身が文書化している契約により、`mpz_*`関数は、宛先がどちらのソースオペランドとエイリアスしていても動作するからである。このマクロは、`mpz_add`/`mpz_sub`などがたまたま持つ性質に頼っているのではない。マクロが生成するすべての関数に一様に当てはまる、GMPが文書化した保証に頼っている。

`IDRIS2RC2_INTEGER_SHIFTOP`(`shiftl`/`shiftr`)は、`x`(シフトされる値)だけを調べ、`y`(シフト量)は調べない。

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

ここで`y`が再利用の候補になることはない。シフト量は、シフトの結果とは*種類*の違う値であり、その大きさは、結果を保持するGMPのリム領域の置き場所としては意味を持たない。しかも実際には、小さくてキャッシュされた不死の`Integer`であるのが常で、これに対する`idris2rc2_isUnique`はつねに偽になる。調べても決して成立しないので、マクロは調べていない。

`negate_Integer`は、同じパターンを単項に適用した、手書きの小さな版である(`mpz_neg`)。このファミリーで唯一の単項演算なので、マクロでは生成していない。

`idris2rc2_div_Integer`は、このヘッダ内の1行ではなく、`numeric.c`にある、複数の文からなる本格的なユークリッド除算のアルゴリズムであり、意図的に対象外にした。後述の「スコープ」を参照すること。

**実装前の安全確認**: `rc2/support/rc2/*.c`/`*.h`をgrepし、これら10個の関数について、生成された`ROp`を下ろすコード以外の呼び出し元がないことを確認した。そのため、ほかの呼び出し元の期待を壊さないための`_consume`付きの新しい名前を用意せずに、契約をその場で変更できた。

## ランタイム契約の変更(拡張): `Int64`/`Bits64`/`Double`

後述の「スコープ」の節には、`Double`/`Int64`/`Bits64`の再利用を「当然の流れだが、まだ試していない後続作業」と書いていた。この拡張は実施済みで、その項目は完了している。

仕組みは、上の`Integer`の場合よりも単純になる。この3つの型は、`{ IDRIS2RC2_Header header; <int64_t/uint64_t/double> v; }`という固定サイズのスカラーをペイロードに持ち、専用の更新関数を要するGMPの`mpz_t`ではないからである。これらの「インプレース再利用」は、構造体自身の`v`フィールドを直接上書きして、同じポインタを返すだけで済む。GMPのように、リムをその場で書き換える手順を呼ぶ必要はない。

### `IDRIS2RC2_INTTYPES`を分割する必要があった理由

この変更の前、`rc2/support/rc2/numeric.h`は、固定幅整数の8つの型(`Int8/16/32/64`、`Bits8/16/32/64`)すべてに対して、X-macroの`IDRIS2RC2_INTTYPES(F)`1つで`Add`/`Sub`/`Mul`/`ShiftL`/`ShiftR`/`BAnd`/`BOr`/`BXOr`を一様に生成していた。再利用を伴う消費型の演算が入ってくると、この一様な扱いは正しくなくなる。

`Int8/16/32`と`Bits8/16/32`は`Types.alwaysUnboxed`であり(`doc/native-type-inference.md`を参照)、Cのレベルでは常にタグ付きポインタで、実際のヒープ確保になることはない(`datatypes.h`の`idris2rc2_is_unboxed`のビット検査で両者を区別する)。こうしたタグ付きの値に`idris2rc2_isUnique`(`->header.refCount`を素で読む)を呼ぶと、偽のポインタを通して読むことになる。これは単に誤った結果を返すだけでなく、未定義動作である。

修正は、X-macroを2つに分けることだった。

- `IDRIS2RC2_INTTYPES_TAGGED(F)`: 常にアンボックスの6つの型(`Int8/16/32`、`Bits8/16/32`)。挙動は変えず、元の`IDRIS2RC2_DEFOP`マクロから生成する。これらに対して`isUnique`の検査が行われることはない。
- `IDRIS2RC2_INTTYPES_REUSABLE(F)`: `Int64`/`Bits64`だけ。固定幅整数の型のうち、値が小整数キャッシュ`[0,100)`を超えると、本当にヒープに確保される2つである。

新しいマクロ`IDRIS2RC2_DEFOP_REUSE(OPNAME, TY, CTY, GET, MK, OP)`は、この再利用可能な2つの型に対して、再利用を伴って消費する版を生成する。上の`IDRIS2RC2_INTEGER_BINOP`とまったく同じ形で、`a`、次に`b`に`idris2rc2_isUnique`を適用し、どちらも一意でなければ新しく確保する。ただし、GMPの関数を呼んで`dst->v`のmpz_tに書き込む代わりに、`((IDRIS2RC2_##TY *)a)->v = result`と直接変更する。

`Double`は、小整数キャッシュの対象にならない。`idris2rc2_mkDouble`は必ず新しく確保するので、そもそもタグ付きと再利用可能の分割が要らない。そのため、`add`/`sub`/`mul`/`div`用に専用の`IDRIS2RC2_DOUBLE_BINOP(OPNAME, OP)`マクロを用意した。

### 今回の`Div`/`Mod`と`Neg`

`Int64`のユークリッド除算のdiv/modと`Bits64`の通常のdiv/modは、このヘッダの中では1行で書ける単純なものである。`Integer`自身の`idris2rc2_div_Integer`は、複数の文からなる本格的なGMPのアルゴリズムであり、今も対象外のままである(「スコープ」を参照)。それと違い、`Int64`/`Bits64`の`Div`/`Mod`を除外する理由は、今回はなかった。そのため、ほかの演算とともに、どちらも再利用を伴って消費する形に変換した。

`Neg`は、`Int64`/`Double`について変換した(手書きの単項版で、`negate_Integer`と同じフィールド上書きのパターンである)。`Bits64`には`negate`が最初からなく、これは従来の挙動と同じである。符号なしの型には`negate`を用意しない。

### コンパイラ側: `isReuseConsumingOp`に対応するケースを追加

`Compiler.RC2.Emit.Util`の`isReuseConsumingOp`に、`Int64Type`/`Bits64Type`/`DoubleType`のケースを追加した。それぞれの型が実際に持つ演算だけを扱う。

- `Bits64Type`はビット演算を持つが、`Neg`は持たない(この型に`negate`はない)。
- `DoubleType`は`Add`/`Sub`/`Mul`/`Div`/`Neg`を持つが、`Mod`とビット演算は持たない(`Double`にはどちらもない)。

型ごとに使える演算の集合は、Idris2自身のものと一致させている。

## 実際に見つかったバグ: `IntType`と`Int64Type`がCの名前を共有している

この拡張で最も重要な点なので、脚注にせず、独立した節で述べる。

`Emit.Util.cPrimType`は、`IntType`(Idris2の通常のマシン幅の`Int`)と`Int64Type`の**両方**を、同一のC関数名の接尾辞`"Int64"`に対応づける。`Add IntType`も`Add Int64Type`も、まったく同じ`idris2rc2_add_Int64`の呼び出しに下ろされる。ランタイム関数は1つだけで、それを2つの別々の`PrimType`が共有している。

この実装の最初の版は、`isReuseConsumingOp`に`Int64Type`のケースだけを追加し、`IntType`をまったく見落としていた。`numeric.h`の中には`IntType`が単独では現れないので、ひと目で見ると、それが自然で完全な集合に見えたのである。

ところが`numeric.h`の`idris2rc2_add_Int64`(とその仲間)は、今ではどの呼び出し元に対しても無条件に、内部でオペランドを消費してdropする。呼び出しの元になったIRレベルの`PrimType`がどれであるかは関係ない。一方、`Compiler.RC2.Emit`の`ROp`のケースは、`isReuseConsumingOp`が認識しない演算には、これまでどおり、呼び出し後の明示的なdropを出力していた。`IntType`が抜けていたので、これは*通常の`IntType`の演算すべて*にあたる。ランタイムがすでにオペランドをdropしているのに、コンパイラが出力したコードがそれをもう一度dropした。

これは、最適化の取りこぼしにとどまらない、本物の**二重drop / use-after-freeのバグ**である。共有された(別名のある)ランタイム関数の契約を変更するときは、コンパイラ側の判定が、そのCの名前に対応する*すべての*`PrimType`を認識する必要がある。見かけ上の「本来の持ち主」だけを認識していては足りない。

これは、`verify.sh`を全件回した回帰実行で見つかった。すでに存在していて、それまでは通っていた4つのテスト(`Test110Loop/LoopContinuePostDrop.idr`、`Test110Loop/LoopInvariantParam.idr`、`Test3Data`、`Test110Loop/SelfTailLoop.idr`)が、誤った出力を返し始めた。クラッシュではなく、use-after-freeによる値の破損であり、`valgrind`でも "definitely lost" は0バイトのままだった。解放されたメモリが再利用されたか、まだマップされたままだったかのどちらかで、実際にリークしたわけではないからである。

この種のバグを検出するのに`valgrind`のリーク検出だけに頼ることには、実際にギャップがある。二重解放やuse-after-freeが、リークとして現れるとは限らない。

修正として、`isReuseConsumingOp`のすべての`Int64Type`のケースの隣に、同じ内容の`IntType`のケースを追加した。さらに、`isReuseConsumingOp`自身にドキュメントコメントを付け、今後どの演算を追加するときも、この2つの`PrimType`を常に歩調をそろえて扱わなければならない理由を説明した。修正後、`verify.sh --regen-expected`を全件回すと、89/89が通る状態に戻った。

## コンパイラ側の変更: `isReuseConsumingOp`と`Emit.idr`のスキップ

`Compiler.RC2.Emit.Util`に、新しい純粋関数を1つ追加した。

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

`True`を返すのは、上の10個のランタイム関数に1対1で対応する10個の演算に限る。それ以外は、`Div IntegerType`(先送りした。「スコープ」を参照)と`Integer`以外のすべての演算を含めて、`False`である。

`Compiler.RC2.Emit`の`emitRC (ROp fc _ op args postDrop)`のケース(Boxedの`ROp`を下ろすケース)は、通常の呼び出し後の後始末の前に、`isReuseConsumingOp op`を調べるようになった。通常は、プリミティブの呼び出しを出力したあとに`removeVars`を2回呼ぶ。

- 1回目は、`postDrop`にある永続的なBoxedのローカル用である。
- 2回目は、`boxOpArg`がNativeのオペランド用に作り出した、一時的なNativeからBoxedへの変換結果用である。

`isReuseConsumingOp op`が`True`なら、この2回の`removeVars`をどちらも完全にスキップする。ランタイムのプリミティブが、渡されたすべてのオペランドの処分を引き受けるからである。永続的なローカルでも、一時的な値でも同じである。

(実際には、この10個の演算で`boxOpArg`が一時的な値を作ることはない。`Integer`は決してnative-eligibleにならないので(`doc/native-type-inference.md`の`nativeEligible`を参照)、`boxOpArg`がBoxedに変換すべきNativeの`Integer`オペランドが、そもそも存在しないためである。それでも2回の呼び出しの両方を無条件にスキップするのは、一様に扱うためで、実際の挙動が変わらない、より狭い2つ目の条件を足さないためである。)

`isReuseConsumingOp op`が`False`なら、挙動はまったく変わらない。以前の明示的なdropの出力が、この変更の前と同じように実行される。

## 複数回出現する場合の安全性(`x + x`のような自己参照式)

`ROp.postDrop`自身のドキュメントコメントに、この場合がすでに書かれている。同じBoxedのローカルが1つの演算の中で2回読まれるとき、「2回読まれるオペランドは2回現れる」(an operand read twice ... appears twice)。変更していない既存の`wrapDups`/`splitBorrows`の仕組みが、2回目の論理的な使用を表すために、2つの出現のうち1つに対して`dup`をすでに挿入している。つまり、2つの出現がランタイム呼び出しに届く時点で、そのローカルの参照カウントはすでに2以上である。

そのため、どちらの出現に`idris2rc2_isUnique`を適用しても、正しく偽になる。`x + x`で誤った再利用が起きることはない。どちらの出現も一意に見えないので、プリミティブは、この変更の前と同じく、新しく確保する側にフォールバックする。

プリミティブは、2つの引数の位置を、それぞれ独立にdropする。2つが同じポインタ値を持っていても同様である。これは、以前のコンパイラが出力していたdrop(`postDrop`に2つのエントリがある)の挙動と正確に一致する。同じポインタに対する2回の独立したdrop呼び出しで、2つの論理的な使用は、直前の`dup`によってすでに2つの参照に分かれているので正しい。それがコンパイラの出力コードからプリミティブの中に移っただけである。この形のために特別扱いは、どこにも必要なかった。

## 並行実行における安全性

`idris2rc2_isUnique`は、すでに`idris2rc2_tailcallApplyClosure`(クロージャのインプレース成長)とコンストラクタ再利用が、同じ不変条件のもとで使っている。参照カウントが1だという検査そのものが、並行実行での安全性を与えているわけではない。安全にしているのは、rc2自身のコンパイル時の生存証明である。この呼び出しがそのオペランドの最後の使用であることが静的に分かっているので、競合しうるほかの参照は存在しない。それゆえ、ほかのスレッドが同じ参照カウントを同時に更新することなく、現在のスレッドが検査の結果に基づいて動いても安全である。

この`ROp`の拡張は、既存のこの不変条件とまったく同じものに依拠しており、並行実行のための新しいプリミティブを導入しておらず、並行実行に関するコードには何の変更も必要なかった(`doc/concurrency.md`を参照)。

## スコープ: 意図的に除外したもの

- **`Div IntegerType`**(`idris2rc2_div_Integer`)。`numeric.c`にある実装は、上の10個の演算のようなマクロの1行の実体化ではなく、複数の文からなる本格的なユークリッド除算のアルゴリズムである。同じ方法で拡張するのはより手間がかかるため、この変更には含めず、意図的に先送りした。
- ~~**`Double`/`Int64`/`Bits64`の再利用。**~~ 完了した。上の「ランタイム契約の変更(拡張): `Int64`/`Bits64`/`Double`」を参照。(この項目が後続作業として自分で完了したことを、この文書の経緯をたどる読者が分かるように、削除せず取り消し線で残してある。)
- **この拡張をテストしているときに見つかった、参照実装の`negate`のタイプミス。** `Int64`/`Bits64`/`Double`の拡張のためのテスト(現在は`Test49IntegerOpReuse.idr`に統合している)を書いているときに、固定した参照実装の`idris2 --cg refc` 0.8.0にインストールされている`mathFunctions.h`が、`idris2_nagate_Int8/16/32/64`と`idris2_nagate_Double`を、"nagate" という綴りの誤りのままマクロとして定義していることが分かった。同じ参照実装自身のコード生成は、正しい綴りの`idris2_negate_<...>`の呼び出しを出力する。このため、固定幅整数型や`Double`に`negate`を使うIdris2のプログラムは、このバイナリに対しては*リンク*に失敗する。

  これは参照実装のバイナリの欠陥であり、rc2の欠陥ではない(`rc2/support/rc2/numeric.h`自身の`idris2rc2_negate_Int64`/`negate_Double`は綴りが正しく、影響を受けない)。そのため、`Test49IntegerOpReuse.idr`の固定幅の拡張関数は、`negate`をまったく動かしていない。同じファイルの元からある、`Integer`型の`bigFactorial`の`negate`の使用が、再利用を伴って消費する`Neg`の一般的なパターンをすでにカバーしている。`Integer`の`idris2_negate_Integer`はマクロではなく実際の関数なので、このタイプミスの影響を受けない。詳細は`TODO.md`の "Pinned reference `idris2 --cg refc` 0.8.0 misspells `negate` for fixed-width/`Double` types" の項を参照すること。
- **`boxOpArg`の一時的な値の再利用は、除外ではなく、すでに含まれている。** 上で述べたとおり、`Emit.idr`のスキップは`postDrop`と`boxOpArg`の一時的な値の両方を一様に対象にしている。`Integer`は、`boxOpArg`がBoxedに変換すべきNativeのオペランドをそもそも生まないので、より狭い条件を切り出す必要がなかった。この一様なスキップを、将来の読者が見落としと取り違えないように、ここで明記しておく。

## 実施した検証

- 事前に`rc2/support/rc2/*.c`/`*.h`をgrepし、対象の10個の関数に、生成された`ROp`を下ろすコード以外の呼び出し元がないことを確認した。これにより、契約をその場で変更しても安全である。
- 新しい回帰テスト`rc2/tests/Test49IntegerOpReuse.idr`を追加した。`bigFactorial`は、末尾再帰のアキュムレータで、小整数キャッシュ`[0,100)`と64ビットの範囲の両方を超えるため、本物のGMPのヒープ確保が起きる。`bigBitOps`は、`Data.Bits`の`Bits Integer`インスタンスを通じて`Mod`/`BAnd`/`BOr`/`BXOr`/`ShiftL`/`ShiftR`を動かす。このテストスイートで、これらの`Integer`演算を小整数キャッシュを超える大きさで動かしたのは、これが初めてである。`verify.sh`の`LEAK_SENSITIVE_TESTS`に登録した。
- `verify.sh --regen-expected`を全件実行して、87/87が通った(Test48とTest49が増えたので、85から増えた)。Test49は、固定した参照実装の`idris2 --cg refc`との差分がなく、`bigFactorial`のadd/sub/mulだけでなく、書き換えたすべてのプリミティブの機能的な正しさが確認できた。
- `refc-suite/run.sh`: 19/19通った。
- `Test49IntegerOpReuse`に`valgrind --leak-check=full`を実行して、"definitely lost" は0バイトだった。深い自己末尾再帰がGMPのバッファを繰り返し再利用・dropしているにもかかわらずである。
- 生成されたCを手で確認した(`rc2/tests/build/Test49IntegerOpReuse_rc2.c`)。`Main_bigFactorial`のホットループが`idris2rc2_sub_Integer`/`idris2rc2_mul_Integer`を呼んだあとに、`idris2rc2_drop`の呼び出しがまったく続かないことを確認した(以前は、Boxedの`ROp`の呼び出しのあとに、必ず明示的なdropが続いていた)。`bigBitOps`の`and_Integer`/`or_Integer`/`xor_Integer`/`shiftl_Integer`/`shiftr_Integer`/`mod_Integer`の呼び出しと、`negate`のテスト行の`sub_Integer`(`negate`として使われている)の呼び出しについても、後続のdropがないことを同様に確認した。

  一方、既存で変更していない関数`Prelude_Types_prim__integerToNat`は、比較である`idris2rc2_lte_Integer`を使っている(この変更の対象外で、`isReuseConsumingOp`には含まれない)。こちらは、以前の明示的な`idris2rc2_drop`の呼び出しを、変わらず出力していることを確認した。スコープが正確で、挙動が変わったのは対象の10個の演算だけであることを示している。
- 再利用そのものは、実行時の確保回数を測る実験ではなく、コードを直接読んで確認した。その実験も検討したが、不要と判断した。構造上の証拠だけで、仕組みは完全に確定するからである。`IDRIS2RC2_INTEGER_BINOP`の宛先を選ぶ三項演算子が、どちらのオペランドの領域が宛先になるかを直接決めており、生成されたCは、所有権解析が保証する参照カウントのとおりにプリミティブが呼ばれていることを示している。

## 実施した検証(拡張: `Int64`/`Bits64`/`Double`)

- `rc2/tests/Test49IntegerOpReuse.idr`に、回帰テストを追加した(ファイルの末尾に統合した)。`sumInt64`/`sumBits64`/`sumDouble`は、小整数キャッシュを超える自己末尾再帰のアキュムレータのループである。`bitOpsInt64`/`bitOpsBits64`は、`Data.Bits`を使う直線的なコード(`.&.`/`.|.`/`xor`/`shiftL`/`shiftR`/`div`/`mod`)である。
- `sumInt64`/`sumBits64`/`sumDouble`が実際に動かしているのは、Boxedの再利用を伴う消費型プリミティブよりも、主に`Compiler.RC2.Loop`自身のnative-shadowループの昇格だと分かった。ループ本体全体が、アンボックスの`int64_t`/`double`のCローカルだけになる。`rc2/tests/build/Test49IntegerOpReuse_rc2.c`の`idris2rc2_worker_Main_sumInt64_0`を見て確認した。その本体は純粋にnativeな算術で、Boxedの呼び出しがまったくない。
- 実際にBoxedの再利用を伴う消費型の経路を動かしているのは`bitOpsInt64`/`bitOpsBits64`で、特に`div`/`mod`がそうである。Idris2の`Prelude.Num`の`Integral`インターフェースのディスパッチを通るため、これらは`+`/`-`/`*`やビット演算のようには、nativeな演算子としてインライン化されない。

  `idris2rc2_worker_Prelude_Num_div_Integral_Int64_7`の生成された本体は、`idris2rc2_div_Int64(var_0, opBox_66)`を直接呼んでおり、後続の`idris2rc2_drop`の呼び出しはない(手で確認した)。これは、消費型プリミティブの契約とコンパイラ側のスキップが、`Int64`についてエンドツーエンドで正しくつながっていることの証拠である。Cの名前が同一の`IntType`についても同様に言える。`idris2rc2_mod_Bits64`/`div_Bits64`についても、同じパターンを個別に確認した。どちらも`rc2/tests/build/Test49IntegerOpReuse_rc2.c`の877行と937行に、後続のdropなしで存在する。
- `Neg`は、上で述べた固定した参照実装の`negate`のタイプミス(`TODO.md`にも記載している)のため、固定幅の拡張のテストでは、意図的にまったく動かしていない。
- `verify.sh --regen-expected`を全件実行して、89/89が通った(87に、新しい固定幅の拡張のテストが加わった)。これは、`IntType`/`Int64Type`の二重dropの修正の再確認でもある。回帰した4つのテストが通る状態に戻したのが、この修正だからである。
- `refc-suite/run.sh`: 19/19通った。
- `Test49IntegerOpReuse`(固定幅の拡張のテスト)に`valgrind --leak-check=full`を実行して、"definitely lost" は0バイトだった。

## ファイル

- `rc2/support/rc2/numeric.h`: `IDRIS2RC2_INTEGER_BINOP`、`IDRIS2RC2_INTEGER_SHIFTOP`、`idris2rc2_negate_Integer`、およびこの2つのマクロから作った10個の実体化。拡張では、`IDRIS2RC2_INTTYPES_TAGGED`/`IDRIS2RC2_INTTYPES_REUSABLE`(従来の1つだった`IDRIS2RC2_INTTYPES`の分割)、`IDRIS2RC2_DEFOP_REUSE`、`IDRIS2RC2_DOUBLE_BINOP`、手書きの`Int64`/`Double`用`negate`も加わった。
- `rc2/src/Compiler/RC2/Emit/Util.idr`: `isReuseConsumingOp`。拡張による`Int64Type`/`Bits64Type`/`DoubleType`のケースと、二重dropのバグの修正で追加した、対応する`IntType`のケースを含む。
- `rc2/src/Compiler/RC2/Emit.idr`: `emitRC (ROp ...)`の、`isReuseConsumingOp`で制御される2回の`removeVars`のスキップ。
- `rc2/tests/Test49IntegerOpReuse.idr`: `Integer`の仕組みと、同じファイルの末尾に統合した`Int64`/`Bits64`/`Double`の拡張の、両方の回帰テスト。
- 変更していないことを明示するもの: `rc2/src/Compiler/RC2/RCExp.idr`(`ROp`自身の形)、`rc2/src/Compiler/RC2/RC.idr`(`annotate`の`ROp`のケース)、`rc2/src/Compiler/RC2/Reuse.idr`(コンストラクタ再利用専用で、無関係)。「何を変える必要がなかったか」が、この文書の要点であるため、ここで明記している。
