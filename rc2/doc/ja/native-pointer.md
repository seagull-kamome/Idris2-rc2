# ネイティブの`Ptr` / `AnyPtr`(設計)

(原文: `doc/native-pointer.md`。内容が乖離した場合は原文を正とする。)

状態: 実装済み(2026-10-20)。「結果」を参照する。`c-struct-support.md`の "Investigated: native (unboxed) `Ptr`/`CFPtr`" 節に代わるものであり、そこで挙げられた反論には以下で答える。

## 問題

`Ptr t`、`AnyPtr`(`CFPtr`)と構造体へのポインタ(`CFStruct`)は、常にボックス化される。`packCFType`は値ごとに`IDRIS2RC2_Pointer`を1つ確保し、`dup`/`drop`のたびにその参照カウントに触れる。このラッパは何も守っていない。解体の処理はペイロードを決して解放しない(`memory.c`、`TAG_POINTER`)ので、参照カウントはどの資源も追跡していない。`getField`、`setField`と、ポインタを返す各`%foreign`は、この確保のコストを払う。

## 決定事項

### 1. ボックス化された値の中での表現: `Bits64`と同じく即値

`[0, 2^63)`の範囲にあるポインタ`raw`は、ワード`raw << 1 | 1`で表す。それ以外はヒープ上のボックス(既存の`Bits64`のボックス)にする。`dup`/`drop`は`idris2rc2_is_unboxed`によってこれを読み飛ばす。どのアドレスも表現できるので、奇数のアドレスや最上位ビットが立ったアドレスも意味を失わない。通常のユーザー空間のアドレス(x86-64、aarch64)は常に即値になる。`IDRIS2RC2_Pointer`と`TAG_POINTER`はなくなる。

### 2. ネイティブ表現: 不透明な構造体へのポインタ

```c
typedef struct IDRIS2RC2_Raw IDRIS2RC2_Raw;   /* never defined */
```

ネイティブのポインタは整数ではなく`IDRIS2RC2_Raw *`である。
- 整数を経由した往復(`(void *)(uintptr_t)x`)はprovenanceを失う。ワーカーの引数、戻り値、ループ変数をまたぐたびに、エイリアス解析が弱くなる。
- `void *`は任意のポインタと暗黙に相互変換されるので、`IDRIS2RC2_Value *`と混ぜても黙って受け入れられる。`IDRIS2RC2_Raw *`と`IDRIS2RC2_Value *`は互換性がなく、生成されるCは`-Werror=incompatible-pointer-types`付きでビルドされる。
- オブジェクトへのポインタは引き続き`void *`と暗黙に相互変換されるので、任意のCのポインタ型を取る`%foreign`の引数にキャストは要らない。
- 型が不完全なので、生成コードのどこからも参照外しできない。

ボックス化されたワードとの相互変換(`mkPtr` / `toPtr`。`uintptr_t`を経由する)は、ポインタをボックス化またはアンボックス化する箇所でだけ行う。

### 3. `Rep`に専用のネイティブ型を持たせる

`RNative`/`RInlineNative`/`RRet`の型は上流の`PrimType`で表されているが、`PrimType`にはポインタの場合がない。これらをrc2独自の型で表すように変える。

```idris
data NativeTy = TPrim PrimType | TPtr
```

`nativeCType TPtr`は`IDRIS2RC2_Raw *`である。`TPtr`には算術がなく、等価比較とnullの検査だけがあり、`alwaysUnboxed`として扱う(dup/dropなし)。`cfTypeNative`は`CFPtr`と`CFStruct`を`TPtr`に対応させる。

### 4. 対象外: `GCPtr` / `GCAnyPtr`(`CFGCPtr`)

その`onCollect`コールバックは、ボックス化されたオブジェクトの参照カウントに依存する。そのためヒープ上の`IDRIS2RC2_GCPointer`のまま残す。内側の`p`は(1)と同じボックス化されたポインタのワードになり、`extractValue`は`toPtr`を通してそれを読む。

## 以前の反論への回答

| 反論 | 回答 |
|---|---|
| `Rep`にポインタの場合がなく、`Rep`に対するすべてのパターンマッチが変わる | `NativeTy`。最初に、挙動を変えないリファクタリングとして導入する |
| `CFGCPtr`は参照カウントを必要とする | 対象外とする(4) |
| 到達可能性の追跡が失われる | 失われるものはもともとなかった。ペイロードは決して解放されない。失われるのはIRでの可視性だけである |

## コスト

`RNative`/`RInlineNative`は9ファイルに約150回現れる(`Emit` 47、`DualABI` 28、`Loop` 19、`Emit/Util` 15、`LateInline` 13、`RC` 11、...)。ほとんどは「ネイティブかどうか」を尋ねるだけであり、変更が要るのは`PrimType`を読む箇所だけである。既存の`CExpr`宣言には変更が要らない。1178個を調べたが、変更されていない`$n`のポインタ引数に対してポインタ算術を行うものはなかった(唯一の`+`の連鎖、`Test118FFI/FFICExpr.idr:101`は整数である)。

## 手順

1. 測定する。termuiのDemoとrc2baseのテストで、`mkPointer`の確保回数と時間を測る。`uint64_t`を使うように手で編集したCと、`IDRIS2RC2_Raw *`を使うCを比べる。得られるものが小さければ、そこでやめる。
2. リファクタリング: `TPrim`だけを持つ`NativeTy`を導入する。出力は変わらない。
3. 表現: ランタイム、`packCFType` / `extractValue`、`onCollect`、`%export`のラッパで、ポインタを即値にする。IRの中ではまだボックス化されたままである。
4. `TPtr`を有効にする: `cfTypeNative`、FFIのワーカー、`RStructGet`/`RStructSet`、`-Werror=incompatible-pointer-types`。
5. テスト: 奇数のアドレス、最上位ビットが立ったアドレス、NULL、`GCPtr`の`onCollect`がちょうど1回呼ばれること。加えて`Test24CStructSupport`、Posixのテスト、TestCurl、termuiのテスト。

## 未決の点

- `%foreign`の呼び出しへ渡すだけのポインタのパラメータは、ネイティブになるか。それを決めるのは`paramEligibility`である。ならない場合、得られるものはFFIの境界に限られる。
- `LEAK_SENSITIVE_TESTS`は確保回数を数えるので、その期待値が変わる可能性がある。

## 結果 (2026-10-20)

実装した。ポインタは即値のボックス化されたワードである(決定1)。`mkPointer`、`IDRIS2RC2_Pointer`、`IDRIS2RC2_TAG_POINTER`はなくなった。`idris2rc2_mkPtr`はインライン関数で、その高速パスが即値であり、`idris2rc2_toPtr`がそれを読み戻す。`Test119FFINoRefc/NativePtr.idr`が、0、奇数のアドレス、最上位ビット、NULL、`onCollectAny`を検査する。

`BenchPtr.idr`(2億回の反復。各反復で`+ offset`によってポインタを作り、それを通して読む。ループ変数はネイティブで、ポインタはボックス化されたままFFIの呼び出しをまたぐ):

| | 時間 |
|---|---|
| 変更前(`mkPointer`。ポインタごとに確保と参照カウントが1つずつ) | 3.55 s |
| 即値、`mkPtr`は関数呼び出し(`mkBits64`) | 0.46 s |
| 即値、`mkPtr`はインライン | 0.26 s |
| 2つのFFI呼び出しのあいだでネイティブの`TPtr` | **0.084 s**(手書きのCと同じ) |

termuiのDemoには`mkPointer`の箇所が4つあるが、どれもループの中にはないので、得るものはない。得をするのは、反復ごとにポインタを作るコードである。

ネイティブ化: `Rep`の`RNative`/`RInlineNative`は`NativeTy`(`TPrim PrimType | TPtr`)を持つ。`cfTypeNativeTy`は`CFPtr`と`CFStruct`を`TPtr`に対応させるので、`%foreign`呼び出しのポインタ引数と戻り値はネイティブになる(`ffiWorkerTable`)。本体がFFIの結果をネイティブの位置で読む場合(`callArgNativeReads`)、`nativePromotionFor`は`let`で束縛されたその結果を`Native Ptr`にする。IRではこれは`Native Ptr`と表示される。Cでは`IDRIS2RC2_Raw *`として宣言され、ボックス化されたワードとは`mkPtr`/`toPtr`で相互に変換され、呼び出しの箇所で`void *`に変換される。`CFGCPtr`はボックス化されたままである。

関数のパラメータもネイティブになる(`Compiler.RC2.Loop`の`ptrCalleeTable`、`ptrParams`)。すべての使用が、`%foreign`宣言の`TPtr`の位置、または別の関数のポインタのパラメータ(一定回数のラウンドで見つける)の位置への呼び出し引数であるパラメータは、その関数のワーカーで`Native Ptr`になる。変換はボックス化されたラッパが行う。`Rewrite.stripOwnership`は、ワーカー呼び出しの`postDrop`から昇格したローカルも取り除くようになった。`postDrop`は、昇格より前に構造体返却(`doc/struct-return.md`)が埋める。これを取り除かないと、不透明な`IDRIS2RC2_Raw *`に対する古い`idris2rc2_drop`が残り、Cコンパイラがそれを拒否した。

ループ変数もネイティブになる。`Compiler.RC2.Loop`は、生のポインタとしてだけ読まれるループのパラメータ(`Loop.ptrParams`)を、`PrimType`のパラメータと同じように`Native Ptr`でシャドウする。`nativePromotionFor`は、そのようなスロットへのcontinueの引数をネイティブの読み取りとして数える。この解析は`Loop.callArgNativeReadsFor`で、`Loop`と`DualABI`が共有し、`NativeTy`の位置を記録した`CalleeTable`の上で動く。`BenchPtrWalk.idr`(反復ごとにポインタを進める): 0.41 sから0.116 sになった。

`Compiler.RC2.MutualLoop`は、`callArgOrOpNativeTy`が各パラメータに与えるネイティブ型(いまは`NativeTy`)でスロットを共有する。そのため、互いに末尾呼び出しする関数をマージしたグループは、ポインタを`Native Ptr`のスロットで運ぶ(`BenchPtrMutual.idr`、2億ステップで0.125 s)。あるメンバーが使わないスロットにはnullポインタを入れる。`rcVarToNativeC`はスカラーに対して`RCNull`を`0`として出力するが、`IDRIS2RC2_Raw *`はそれを受け付けないからである。

関数のすべての末尾の葉がネイティブであれば、戻り値もネイティブになる。末尾の葉とは、ネイティブのローカルかオペランド、またはネイティブの戻り値を持つ`%foreign`宣言への、素の飽和した末尾呼び出しである(`DualABI.tailValueRepsWith`、`returnEligibility`)。Stage 4は、まさにそのような末尾呼び出しを、ネイティブの戻り値を持つワーカー呼び出しに書き換える。そのため、そうした呼び出しで終わる関数(`BenchPtrFn.idr`の`at`)は、ボックス化せずに`Native Int`や`Native Ptr`を返す(3.25 sから0.99 s)。これはポインタだけでなくスカラーにも当てはまる。以前のStage 2は、すべての呼び出しを`Nothing`とみなしていた。ほかの関数への通常の末尾呼び出しは、ボックス化された戻り値のままである(`doc/dual-abi.md`のスタック成長の境界)。

## `%foreign`呼び出しをまたぐスカラー

同じ呼び出し引数の解析は、`%foreign`宣言のスカラーの位置も読む(`Loop.foreignCallee`は、ポインタだけでなく各引数について`cfTypeNativeTy`を与える)。そのような引数としてだけ使われるループ変数、相互ループのスロット、関数のパラメータは、ポインタと同じく、呼び出しをまたいでネイティブのスカラーになる。以前は、ネイティブにする要因は`ROp`のオペランドだけだった。`BenchForeignScalar.idr`(変数が`%foreign`呼び出しに渡されるだけの2つのループ): 5.57 sから0.85 sになった。`Test119FFINoRefc/ForeignScalar.idr`は、即値の範囲を超える値も含めて、`Int`、`Bits8`、`Bits64`、`Char`を検査する。`Char`は従来どおりに渡され、呼び出しの箇所で狭められる(`nativeCharArgExpr`)。`Integer`と`String`にはネイティブ型がないので、対象外である。
