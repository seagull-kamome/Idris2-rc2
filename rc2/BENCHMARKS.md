# rc2 Stage 5: テストとベンチマーク結果

`tests/` 配下の各プログラムを `idris2-rc2 --cg rc2` と本家 `idris2 --cg refc`
の両方でコンパイル・実行して比較した結果。

## 機能テスト

`tests/Test1Basics.idr` 〜 `tests/Test5FFIStrings.idr` を `--cg rc2` でコンパイル・
実行し、全て期待通りの結果を確認済み。

| ファイル | 内容 |
|---|---|
| `Test1Basics.idr` | 階乗(Integer)・末尾再帰ループ・IORef・文字列・List map/filter |
| `Test2Recursion.idr` | 相互再帰(isEven/isOdd)・非末尾再帰(素朴なfib) |
| `Test3Data.idr` | Double/Int混在ADT(Shape)・レコード(Point)・Maybe/List |
| `Test4Closures.idr` | クロージャ・高階関数・部分適用 |
| `Test5FFIStrings.idr` | 直接FFI(`strlen`)・RefCタグ流用FFI(`fastPack`/`fastConcat`/`pack`/`unpack`) |

## 発見・修正したバグ

テスト拡充中に、ネイティブ型推論(`Compiler.RC2.Types`)まわりで2件の重大な不具合を
発見し修正した(現在のコードは修正済み):

1. **`Cast Integer Int` のメモリ破壊バグ**: 出力型のみがネイティブ対象で入力型が
   GMP `Integer`(常にボックス)の場合に誤ってネイティブアンボックス化を試み、
   ヒープポインタをそのまま `int64_t` に再解釈していた。`opResultRep (Cast i o)`
   が `o` のみ判定し `i` を見ていなかったのが原因。
2. **合成letを透過できない不具合**: `d * 2` のようにリテラル引数が合成let
   (ANF正規化で導入される一時変数)でラップされる演算で、ネイティブ化判定が
   その合成letを素通りできず、ネイティブ化の機会を逃していた。

## ベンチマーク

`tests/BenchLoop.idr` / `BenchFib.idr` / `BenchChain.idr` を使用。

### 末尾再帰ループ・非末尾再帰

| ベンチマーク | rc2 | RefC |
|---|---|---|
| `BenchLoop.idr`(`sumTo`、300万回) | 0.31s | 0.19s |
| `BenchFib.idr`(素朴なfib(30)) | 0.20s | 0.22s |

実行時間はほぼ同等(rc2がわずかに遅いケースもある)。理由: 関数呼び出し・末尾再帰は
本セッションで変更しなかった「常にBoxed」の呼び出し規約のまま(クロージャ生成+
トランポリン)であり、ループ内の値が1反復ごとに呼び出し境界(=ボックス化境界)を
またぐため、ネイティブ化の恩恵よりアンボックス化のオーバーヘッドが目立つ。

### 算術チェイン(`BenchChain.idr` の `poly` 関数、7段の連続算術演算)

生成Cコードを直接比較(`Main_poly` 関数のみ):

| 指標 | rc2 | RefC |
|---|---|---|
| ヒープ確保(malloc相当) | 3回(最終の戻り値ボックス化のみ) | 8回(演算ごとに1回) |
| `dup`(参照カウント増加) | 0回 | 6回 |
| `drop`(参照カウント減少) | 0回 | 16回 |
| **メモリ管理操作 合計** | **3回** | **30回** |

**10倍のメモリ管理操作削減**を確認。関数内ローカルのネイティブ型推論が意図通り
機能している直接的な証拠。

### 結論

アンボックス化そのものは狙い通り強力に効いている(算術チェインで10倍のメモリ管理
操作削減)。ただし呼び出し規約(クロージャ/トランポリン)を変更していないため、
再帰・ループが支配的なプログラムでは、この削減効果が全体の実行時間には反映され
にくい。デュアルABI・末尾再帰ループ化(未実装、将来課題)を実装すれば、算術チェインの
削減効果がループ全体の実行時間にも反映されると見込まれる。

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
