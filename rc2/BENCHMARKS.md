# rc2 Stage 5: テストとベンチマーク結果

`tests/` 配下の各プログラムを `idris2-rc2 --cg rc2` と本家 `idris2 --cg refc`
の両方でコンパイル・実行して比較した結果。

## 機能テスト

`tests/Test1Basics.idr` 〜 `tests/Test7CastMatrix.idr` を `--cg rc2` でコンパイル・
実行し、全て期待通りの結果を確認済み(Test1〜6は本家 `idris2 --cg refc` の出力と
バイト完全一致、Test7は環境のRefCランタイム自体の既知バグにより手動検証)。

| ファイル | 内容 |
|---|---|
| `Test1Basics.idr` | 階乗(Integer)・末尾再帰ループ・IORef・文字列・List map/filter |
| `Test2Recursion.idr` | 相互再帰(isEven/isOdd)・非末尾再帰(素朴なfib) |
| `Test3Data.idr` | Double/Int混在ADT(Shape)・レコード(Point)・Maybe/List |
| `Test4Closures.idr` | クロージャ・高階関数・部分適用 |
| `Test5FFIStrings.idr` | 直接FFI(`strlen`)・RefCタグ流用FFI(`fastPack`/`fastConcat`/`pack`/`unpack`) |
| `Test6NativeInts.idr` | Int8/16/32/64・Bits8/16/32/64全8種の算術チェイン(境界値ラップアラウンド含む) |
| `Test7CastMatrix.idr` | Double/Char/String絡みのCastプリミティブ全組合せ |

## 発見・修正したバグ

テスト拡充中に、ネイティブ型推論(`Compiler.RC2.Types`)まわりで複数の重大な不具合を
発見し修正した(現在のコードは修正済み):

1. **`Cast Integer Int` のメモリ破壊バグ**: 出力型のみがネイティブ対象で入力型が
   GMP `Integer`(常にボックス)の場合に誤ってネイティブアンボックス化を試み、
   ヒープポインタをそのまま `int64_t` に再解釈していた。`opResultRep (Cast i o)`
   が `o` のみ判定し `i` を見ていなかったのが原因。
2. **合成letを透過できない不具合**: `d * 2` のようにリテラル引数が合成let
   (ANF正規化で導入される一時変数)でラップされる演算で、ネイティブ化判定が
   その合成letを素通りできず、ネイティブ化の機会を逃していた。
3. **ネイティブ演算の結果に使われるBoxed引数のリーク**(`rc2/tests/Test6NativeInts.idr`
   で発見): `Compiler.RC2.RC`の所有権解析(`annotate`)は、ネイティブ結果になる
   演算(`ROp`)の引数でも通常のBoxed引数と同じ規則(初回使用ならowned、以降は
   dup)で借用/所有を決定するが、対応する`Emit.idr`側の`emitNativeValue`の`ROp`
   ケースは、消費した(=もう`owned`に残っていない)Boxed引数を一切dropしていな
   かった。関数引数がネイティブ演算の中で読まれるだけで一度もBoxedの値として
   再利用されない場合(このセッションのテストプログラム全体で頻出するパターン)、
   毎回1参照分がリークする不具合。修正時、最初に単純に`emitRC`のBoxed版ROpケース
   と同じ位置に drop 呼び出しを追加したところ、64bit型(`Int64`/`Bits64`、ヒープ
   確保される表現)で **use-after-free** を引き起こす退行を作り込んでしまった
   (`emitNativeValue`はインライン式の文字列だけを返し、実際にその式を使う文を
   emitするのは呼び出し元なので、dropの発行タイミングが実際の読み取りより前に
   来てしまっていた)。最終的な修正: Boxed引数が1つでも絡む場合のみ、演算結果を
   先に一時変数へ代入する文をこの場でemitしてから drop する(=読み取りが必ず
   dropより前に実行されることを保証)方式に変更。8/16/32/64bit・符号あり/なし
   全組み合わせで本家RefCの出力とバイト完全一致することを確認し、
   `BenchChain.idr`の`poly`関数(下記ベンチマーク)でも参照カウント操作が正しく
   バランスするようになったことを確認済み。

## ベンチマーク

`tests/BenchLoop.idr` / `BenchFib.idr` / `BenchChain.idr` を使用。

### 末尾再帰ループ・非末尾再帰

| ベンチマーク | rc2 | RefC |
|---|---|---|
| `BenchLoop.idr`(`sumTo`、300万回) | 0.16s | 0.18s |
| `BenchFib.idr`(素朴なfib(30)) | 0.18s | 0.21s |
| `BenchChain.idr`(`loopPoly`、300万回) | 0.53s | 0.65s |

(2026-08-13再測定、各3回実行の代表値。)`sumTo`/`loopPoly`はどちらも `acc n = ...`
の`0`ケースへの**パターンマッチ**であり、`<`/`==`等の比較演算子(下記の比較/分岐
融合の対象)は一切経由しない -- この2つの計測値の変化は測定誤差の範囲内で、比較
融合の効果ではない。一方 `fib` は `if n < 2 then ...` で真の比較演算を使っており、
以前の版で「ほぼ同等」としていたRefCとの差が、下記の比較/分岐融合(RCmpCase)の
追加により明確にrc2優位へ変化した。いずれのベンチマークも、関数呼び出し・末尾
再帰は依然として「常にBoxed」の呼び出し規約のまま(クロージャ生成+トランポリン)
であり、ループ内の値が1反復ごとに呼び出し境界(=ボックス化境界)をまたぐため、
呼び出しオーバーヘッド自体は変わっていない。

### 比較/分岐融合(RCmpCase)

`LT`/`GT`/`EQ`/`LTE`/`GTE`(ネイティブ対応型のみ)が、直後で
Idris2自身のBool表現(False=0/True=1)への二分岐に直接消費される場合、比較結果を
一切値として作らず、素のC比較式をそのまま`if`条件へ埋め込む最適化
(`Compiler.RC2.RCExp`の`RCmpCase`、`Compiler.RC2.RC`の`tryFuseCompare`)を追加した。

Idris2の`<`/`==`等は常に`Prelude.EqOrd`インターフェース経由でディスパッチされる
ため、ユーザーコード側から見た呼び出し境界(インターフェースメソッド自体の引数・
戻り値)は今回も変更していない(=依然としてBoxed) -- 効果が出るのは、その
インターフェース実装関数**自身の内部**で比較結果を消費する部分。`fib`が使う
`Prelude.EqOrd.(<)`の`Int`実装(`Prelude_EqOrd__lt_Ord_Int`)を例に、生成Cコードの
実際の変化:

```c
/* 融合前 */
IDRIS2RC2_Value *cmpResult = idris2rc2_lt_Int64(var_0, var_1);
idris2rc2_drop(var_0);
idris2rc2_drop(var_1);
int64_t tag = idris2rc2_extractInt(cmpResult);
if (tag == 0) { idris2rc2_drop(cmpResult); ret = idris2rc2_mkBits8(0); }
else          { idris2rc2_drop(cmpResult); ret = idris2rc2_mkBits8(1); }

/* 融合後 */
int cmp = (idris2rc2_to_i64(var_0) < idris2rc2_to_i64(var_1));
idris2rc2_drop(var_0);
idris2rc2_drop(var_1);
if (cmp) { ret = idris2rc2_mkBits8(1); }
else     { ret = idris2rc2_mkBits8(0); }
```

| 指標(呼び出し1回あたり、実行される側の分岐のみ) | 融合前 | 融合後 |
|---|---|---|
| ランタイム関数呼び出し(`idris2rc2_*`) | 6回(`lt_Int64`, `drop`×2, `extractInt`, `drop`(中間値), `mkBits8`) | 3回(`drop`×2, `mkBits8`) |

**ランタイム呼び出し回数を半減**(6回→3回)。ただし正直な注記として: rc2の
`idris2rc2_mkBool`は常に`idris2rc2_mkInt8`(タグ付きポインタ、`Int8`は
`Types.alwaysUnboxed`)であり、融合前でも比較結果のBool自体は実は**ヒープ確保
されていなかった**(mallocではなく、ポインタへのビット詰め込みのみ)。したがって
今回の削減の実体は「ヒープ確保の回避」ではなく、「タグ付きポインタへの詰め込み
→取り出しの往復とランタイム関数呼び出し1回分の除去」である。またインターフェース
実装関数自身の**戻り値**(`mkBits8`)は、比較演算をユーザーコードから直接呼ぶ
場合とは異なり、呼び出し規約がBoxedのままである以上、依然として境界を越える
たびに再ボックス化が必要 -- デュアルABI(未実装)を実装しない限り、この境界は
消せない。

### 算術チェイン(`BenchChain.idr` の `poly` 関数、7段の連続算術演算)

生成Cコードを直接比較(`Main_poly` 関数のみ):

| 指標 | rc2 | RefC |
|---|---|---|
| ヒープ確保(malloc相当) | 3回(引数`x`を消費する最後の演算1回分のボックス化2個 + 戻り値1個) | 8回(演算ごとに1回) |
| `dup`(参照カウント増加) | 3回(引数`x`が複数回読まれる箇所ごとに1回) | 6回 |
| `drop`(参照カウント減少) | 4回(同上、各読み取り後に1回) | 16回 |
| **メモリ管理操作 合計** | **10回** | **30回** |

**3倍のメモリ管理操作削減**を確認(生成Cコードを直接カウントして検証。上記「発見・
修正したバグ」の3番目に記載した引数リークバグの修正前は誤って dup/drop 0回・
合計3回、10倍削減と記録していたが、これは実際には毎回引数`x`の参照がリークして
いたことの裏返しであり、修正後の正しい値に更新した)。関数内ローカルのネイティブ
型推論そのものは意図通り機能しており、演算の**中間結果**(`a`〜`g`)は依然として
一切ヒープ確保・参照カウント操作なしに素の`int64_t`のまま計算されている -- 残る
`dup`/`drop`はすべて、関数の境界を越えてやってくるBoxedな引数`x`自体の所有権管理
分であり、これは呼び出し規約自体をBoxedのまま変更していない(デュアルABI未実装の)
現状では原理的に避けられないコストである。

### 結論

アンボックス化そのものは狙い通り強力に効いている(算術チェインでヒープ確保回数を
8回→3回に削減、メモリ管理操作の合計でも3倍の削減)。比較/分岐融合(RCmpCase)の
追加により、再帰・ループが支配的なプログラムでもRefCとの実行時間差が実測で
明確にrc2優位側へ動いた(`BenchFib.idr`)。ただし呼び出し規約(クロージャ/
トランポリン)自体は変更していないため、呼び出し境界を越えるたびに生じる
ボックス化/再ボックス化のコストは変わらず残っている(比較融合もこの境界の
「内側」でのみ効く、`fib`の例を参照)。デュアルABI・末尾再帰ループ化(未実装、
将来課題)を実装すれば、算術チェインの削減効果と比較融合の効果の両方が、呼び出し
境界をまたいでもより広く反映されると見込まれる。

## 再現方法

```sh
cd idris2-rc-cg/rc2
source ../env.sh

# rc2でコンパイル
nix-shell -p gcc gmp --run \
  './build/exec/idris2-rc2 --cg rc2 tests/BenchChain.idr -o /tmp/bench_rc2'

# RefC(本家idris2)でコンパイル
nix-shell -p idris2 gcc gmp --run \
  'idris2 --cg refc tests/BenchChain.idr -o /tmp/bench_refc'

time /tmp/bench_rc2
time /tmp/bench_refc
```
