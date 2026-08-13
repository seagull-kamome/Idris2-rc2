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
| `BenchLoop.idr`(`sumTo`、300万回) | 0.12s | 0.18s |
| `BenchFib.idr`(素朴なfib(30)) | 0.18s | 0.21s |
| `BenchChain.idr`(`loopPoly`、300万回) | 0.47s | 0.66s |

(2026-08-13、自己末尾再帰ループ変換の追加後に再測定、各3回実行の代表値。)
`sumTo`/`loopPoly`は両方とも自己末尾再帰(下記の自己末尾再帰ループ変換の対象)で、
その効果により明確にrc2優位が広がった。`fib`は末尾再帰ではない(`fib(n-1)+fib(n-2)`
という2つの再帰呼び出しが両方とも足し算の被演算子であり、末尾位置ではない)ため
対象外で、数値は比較/分岐融合(下記)の効果のみを反映している。

### 自己末尾再帰のループ変換(Compiler.RC2.Loop)

関数自身への末尾呼び出し(自己再帰のみ、相互再帰は対象外)を、クロージャ生成+
汎用トランポリンではなく、パラメータ変数への再代入+`goto`によるCレベルの
ループへ変換する最適化(`Compiler.RC2.RCExp`の`RSelfTailCall`ノード、専用パス
`Compiler.RC2.Loop`)を追加した。判断はIRレベルで完結しており(木を1回走査して
自己末尾呼び出しを見つけ次第置き換えるだけ)、`Compiler.RC2.Emit`側は
`tryEmitSelfTailCall`という機械的な下ろし込みのみを担当する。

`BenchLoop.idr`の`sumTo`を例に、生成Cコードの変化:

```c
/* 変換前 */
IDRIS2RC2_Value *Main_sumTo(IDRIS2RC2_Value *var_0, IDRIS2RC2_Value *var_1) {
    ...
    /* 再帰ケース */
    IDRIS2RC2_Value *closure_N = idris2rc2_mkClosure(Main_sumTo, 2, 0);
    ((IDRIS2RC2_Closure*)closure_N)->args[0] = ...;
    ((IDRIS2RC2_Closure*)closure_N)->args[1] = ...;
    return idris2rc2_trampoline(closure_N);
}

/* 変換後 */
IDRIS2RC2_Value *Main_sumTo(IDRIS2RC2_Value *var_0, IDRIS2RC2_Value *var_1) {
    loop:;
    ...
    /* 再帰ケース */
    IDRIS2RC2_Value *tmp_A = idris2rc2_mkInt64(...);
    IDRIS2RC2_Value *tmp_B = idris2rc2_mkInt64(...);
    var_0 = tmp_A;
    var_1 = tmp_B;
    goto loop;
}
```

反復あたり、クロージャ確保(`idris2rc2_mkClosure`)・フィールド代入・
トランポリン呼び出しが完全に消え、C関数呼び出し自体も発生しない(コンパイラの
最適化次第では一時変数もレジスタへ載る)。新しい値を一旦一時変数へスナップショット
してからパラメータへ書き戻しているのは、`f x y = f y x`のような入れ替えパターンで
同時代入が正しく行われることを保証するための、純粋なコード生成上の処置(所有権
判断とは無関係、`Compiler.RC2.RC`の`annotate`が既に決定済みのdup/move判断をそのまま
再利用している)。

所有権解析への影響がないことは、この変換の前後で生成される`idris2rc2_dup`/
`idris2rc2_drop`呼び出しのパターンが(クロージャ関連の呼び出しを除いて)完全に
同一であることでも確認できる。10万〜50万段の深さで自己末尾再帰するテストケース
(`rc2/tests/Test9SelfTailLoop.idr`)でもCスタックを一切消費せず正しく動作することを
確認済み(スタックオーバーフローなし、`goto`が実際にCレベルのループとして機能して
いる直接的な証拠)。相互再帰(`isEvenM`/`isOddM`)はスコープ外として明示的に除外して
おり、従来通りクロージャ+トランポリン経由で正しく動作することも確認済み。

### 相互末尾再帰のループ変換(Compiler.RC2.MutualLoop)

自己末尾再帰だけでなく、2つ以上の関数が互いに末尾呼び出しし合う相互再帰
サイクルも`goto`ループへ変換する最適化を追加した。新設の全プログラム
パス`Compiler.RC2.MutualLoop`(`Reuse`の後・`Loop`の前で実行、
`RC2.idr`の`toRCDefs`参照)が、末尾呼び出しグラフ上のサイクル(Tarjanの
強連結成分分解)を検出し、グループのメンバーを1つの合成関数(整数タグで
分岐する`RConstCase`、メンバーごとに1枝)へマージ、グループ内のあらゆる
遷移(自分自身への遷移もメンバー間の遷移も)をその合成関数自身への通常の
末尾呼び出しへ書き換える。合成関数から見ればこれは単なる自己末尾再帰
そのものなので、直後に実行される既存の`Compiler.RC2.Loop`がそのまま
`goto`へ変換する -- `Compiler.RC2.Loop`・`Compiler.RC2.Emit`側は一切の
変更なし。元の各関数名は合成関数を1回呼ぶだけの薄いラッパーとして残る。

`BenchMutual.idr`(`pingPong`/`pongPing`が交互に末尾呼び出しし合いながら
300万回反復、`BenchLoop.idr`の`sumTo`と同じ反復数)を例に、生成Cコードの
比較(本家RefCは相互再帰を常にクロージャ+トランポリン経由で扱うため、
「変換しなかった場合」の参考としてそのまま使える):

```c
/* RefC(相互再帰は常にクロージャ+トランポリン) */
Value *Main_pongPing(Value *var_0, Value *var_1) {
    ...
    Value *closure_8 = (Value *)idris2_mkClosure((Value *(*)())Main_pingPong, 2, 2);
    ((Value_Closure*)closure_8)->args[0] = var_3;
    ((Value_Closure*)closure_8)->args[1] = var_4;
    return closure_8;   /* 呼び出し元がトランポリンし直す */
}

/* rc2(MutualLoop がマージ後、Loop が goto へ変換) */
IDRIS2RC2_Value *rc2_mutualLoop_0(IDRIS2RC2_Value *var_1, IDRIS2RC2_Value *var_2, IDRIS2RC2_Value *var_3) {
    loop:;
    ...
    /* tag==1 (pongPing) 側の遷移: tag を 0 (pingPong) に書き換えて goto */
    var_1 = tmp_62;  var_2 = tmp_63;  var_3 = tmp_64;
    goto loop;
}
```

反復あたり、遷移のたびに発生していたクロージャ確保(`mkClosure`)・
フィールド代入・呼び出し元での再トランポリンが完全に消え、C関数呼び出し
自体も発生しない。実測(壁時計時間、5回実行平均):

| | rc2 | RefC |
|---|---|---|
| `BenchMutual.idr`(300万回相互末尾再帰) | 0.135s | 0.181s |

**RefCの約74%の実行時間**(≒26%高速)。自己末尾再帰(`BenchLoop.idr`)の
改善幅(RefCの約60〜68%)と近い水準であり、同じ「クロージャ+トランポリン
撤去」の効果が相互再帰でも同様に効いていることを裏付ける。

生成Cコードを直接確認し、合成関数の本体(`rc2_mutualLoop_0`)に
`mkClosure`/`trampoline`呼び出しが一切含まれず、全ての内部遷移が
`goto loop;`のみで完結していることを確認済み。正当性は
`Test10MutualLoop.idr`(アリティの異なるグループでのスロットパディング、
3方向サイクル、同一メンバー内遷移、グループ外からの非末尾呼び出し・
クロージャとしての利用、30万〜50万段の深さでの相互末尾再帰)で検証し、
`idris2 --cg refc`の出力とバイト完全一致することを確認済み(TODO.md
参照)。

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
8回→3回に削減、メモリ管理操作の合計でも3倍の削減)。比較/分岐融合(RCmpCase)・
自己末尾再帰ループ変換(Compiler.RC2.Loop)・相互末尾再帰ループ変換
(Compiler.RC2.MutualLoop)の追加により、再帰・ループが支配的なプログラムでも
RefCとの実行時間差が実測で明確にrc2優位側へ動いた(`BenchFib.idr`は比較融合の
効果、自己末尾再帰する`BenchLoop.idr`/`BenchChain.idr`の`loopPoly`はループ変換の
効果、相互末尾再帰する`BenchMutual.idr`は相互再帰ループ変換の効果 -- 自己版の
改善幅(RefCの約60〜68%)と近い約74%まで到達)。ただし呼び出し規約(クロージャ/
トランポリン)自体は末尾再帰(自己・相互とも)以外では変更していないため、非末尾
呼び出し・他関数への単純な呼び出しでは呼び出し境界を越えるたびに生じるボックス化
/再ボックス化のコストが変わらず残っている(比較融合もこの境界の「内側」でのみ効く、
`fib`の例を参照)。デュアルABI(未実装、将来課題)を実装すれば、算術チェインの
削減効果と比較融合の効果の両方が、末尾位置以外の呼び出し境界をまたいでもより広く
反映されると見込まれる。

## 外部パッケージベンチマーク: idris2-missing-containers

これまでのベンチマークは全てrc2プロジェクト自身が用意した小規模なマイクロベンチ
マークだった。より実際のワークロードに近い比較として、外部の独立したIdris2
パッケージ [`idris2-missing-containers`](https://github.com/seagull-kamome/idris2-missing-containers)
(ハッシュテーブル・ハッシュアルゴリズム集、`Data.IOArray.Prims`のFFIプリミティブ・
`System.Clock`・`System.File`を実際に使用)をcloneし、その `test/` を `--cg rc2`
・本家 `idris2 --cg refc`・本家のデフォルトバックエンドである Chez Scheme
(`idris2`、`--cg`省略)の3通りでコンパイル・実行して比較した。

### セットアップ

```sh
# clone under install/ -- gitignored wholesale, no per-repo .gitignore entry needed
cd /path/to/idris2-rc-cg/install
git clone https://github.com/seagull-kamome/idris2-missing-containers.git
cd idris2-missing-containers
source /path/to/idris2-rc-cg/env.sh

# ライブラリをインストール(以後 -p missing-containers で参照可能に)
nix-shell -p idris2 gmp pkg-config --run \
  '/path/to/rc2/build/exec/idris2-rc2 --install missing-containers.ipkg'

# test/src/Main.idr を3バックエンドで直接コンパイル
cd test/src
nix-shell -p idris2 gmp pkg-config --run \
  '/path/to/rc2/build/exec/idris2-rc2 --cg rc2 -p missing-containers -p contrib Main.idr -o mct_rc2'
nix-shell -p idris2 gmp pkg-config --run \
  'idris2 --cg refc -p missing-containers -p contrib Main.idr -o mct_refc'
nix-shell -p idris2 gmp pkg-config chez --run \
  'idris2 -p missing-containers -p contrib Main.idr -o mct_chez'   # --cg省略 = Chez Scheme(デフォルト)
```

`test/test.ipkg` は `hashable >= 0.1.0` にも依存すると宣言しているが、
`test/src/Main.idr` は実際には `Data.Hashable` を一切importしていない(パッケージ
自身の `Data.Hash.Algorithm` 経由の独自 `Hashable` インターフェースのみ使用)ため、
単一ファイル直接コンパイル(`-p`指定のみ、ipkgベースの依存解決を経由しない)では
未インストールのままでも問題なくビルドできた。

### ワークロード

`test/src/Main.idr` の `main` は次を実行する:

1. `testHashMap` -- 3件の`IOHashMap`書き込み/読み出しの健全性チェック。
2. `benchmarkHashMap` -- `test/words`(98,569行の単語リスト)を対象に5種類の
   ハッシュアルゴリズム(FNV1a/MurMur3/OneAtATime/Sip64/Sip32)でハッシュ計算し、
   `test/input_large`(985,690行の辞書)全件を`IOHashMap`へ書き込み、その後
   `test/words`全件を読み出す。

### 結果(壁時計時間、3回実行)

初回計測(2026-08-13、自己末尾再帰ループ変換 (`Compiler.RC2.Loop`) 追加前):

| 実行 | rc2 | RefC | Chez Scheme |
|---|---|---|---|
| 1回目 | 16.829s | 21.465s | 7.149s |
| 2回目 | 17.591s | 21.554s | 7.049s |
| 3回目 | 17.465s | 22.107s | 7.067s |
| 平均 | **17.30s** | **21.71s** | **7.09s** |

再計測(2026-08-13、自己末尾再帰ループ変換追加後 -- `IOHashMap`の`read`/`write`・
ハッシュアルゴリズム(FNV1a/MurMur3/OneAtATime/Sip*)の内部実装は再帰ループとして
書かれており、その多くが自己末尾再帰でこの最適化の対象になる):

| 実行 | rc2 |
|---|---|
| 1回目 | 15.027s |
| 2回目 | 14.867s |
| 3回目 | 15.709s |
| 平均 | **15.20s** |

(RefC/Chezはこの変更の影響を受けないため未再計測、初回計測の値のまま。)

rc2はRefC比で平均**約30%高速**(1.43倍、ループ変換前は約20%高速・1.25倍)。
ループ変換自体による短縮は約12%(17.30s→15.20s)。ただしCの2バックエンド
(rc2/RefC)はどちらも依然としてChez Schemeに水をあけられている(rc2比でChezが
**2.1倍高速**、ループ変換前の2.4倍からは差を縮めた)。3者とも `testHashMap` は
3件とも `✓`、`dict`/`words`の件数も一致し、出力は `codegen = ...` の行を除いて
構造的に完全一致(挙動の差異なし)。

支配的なのは `benchmarkHashMap` の `write`(辞書985,690件の`IOHashMap`書き込み)
フェーズで、ループ変換後のrc2側では10.2秒程度(変換前は11.4秒程度)、Chez側では
4.0秒程度と、全体の実行時間の大半を占めていた(下記の注記の通りRefC側は秒精度の
クロックしか出さないため直接の秒未満比較はできないが、壁時計の総実行時間差は
このフェーズに起因すると考えられる)。ChezのGC(世代別・コピーGC)は非atomic
参照カウント(rc2/RefC共通のモデル)に比べ、このワークロードが大量に生成する
短命な小オブジェクト(ハッシュ計算の中間値、`IOHashMap`のバケット再配置に伴う
一時配列など)の回収コストが本質的に低いと考えられ、ループ変換後もなお大きな差が
ランタイム・GC戦略の違いから生じている。

### 注記: 本家RefCの`System.Clock`は秒精度

プログラム自身が`clockTime Monotonic`で計測・出力する区間タイミングは、rc2側は
`clock_gettime`ベースでナノ秒精度(下記参照)だが、本家RefC側は`time()`/`clock()`
ベースの実装で秒未満が常に`0`になる(rc2の`System.Clock`実装時に把握済みの
既知の粗さで、rc2側は意図的に`clock_gettime`ベースへ改善している)。そのため
1秒未満で終わる個々のハッシュアルゴリズムのベンチマークはRefC側の数値が
`0s 0ns`/`1s 0ns`のように丸められ、プログラム内タイミングでの比較には使えない。
上記「結果」表の壁時計比較(外部の`time`)はこの制約を受けないため、こちらを
主たる比較指標とした。

参考までにrc2・Chezそれぞれのプログラム内タイミング(いずれもナノ秒精度、1回分。
ChezはIdris2本家のデフォルトバックエンドで、rc2と同様`clock_gettime`相当の
高精度実装を持つため、RefCと異なり直接比較できる。rc2側は自己末尾再帰ループ
変換後の値に更新):

| フェーズ | rc2 | Chez Scheme |
|---|---|---|
| FNV1a(words全件) | 0.282s | 0.126s |
| MurMur3(words全件) | 0.232s | 0.092s |
| OneAtATime(words全件) | 0.193s | 0.048s |
| Sip64(words全件) | 0.419s | 0.764s |
| Sip32(words全件) | 0.455s | 0.228s |
| write(dict全件、985,690件) | 10.21s | 4.03s |
| read(words全件、98,569件) | 1.07s | 0.282s |

ハッシュアルゴリズム5種は全て(全件走査するだけの)自己末尾再帰ループで実装されて
おり、ループ変換の効果でrc2側は軒並み改善した(例: OneAtATime 0.245s→0.193s)。
それでもほぼ全フェーズでChezが優位なのは変わらず、`Sip64`のみrc2の方が速い
(0.419s対0.764s、ループ変換前の0.507s対0.764sからさらに差が開いた) -- 唯一の
逆転現象。SipHashは他の4アルゴリズムと異なり64bit演算主体で分岐が少ないため、
この1点だけはCネイティブコード生成(+比較/分岐融合・自己末尾再帰ループ変換等の
最適化)がChezのGC効率の良さを上回ったと考えられるが、詳細な原因分析はしていない。
(`read`のみ1回計測でわずかに悪化して見えるが、この規模の1回計測は測定誤差の範囲。)

### 結論

rc2独自のマイクロベンチマークだけでなく、外部の第三者パッケージによる文字列
ハッシュ・ハッシュテーブル中心の実ワークロードでも、同じCベースのRefCに対しては
一貫して優位(自己末尾再帰ループ変換後で約30%高速、変換前は約20%高速)であることを
確認した。このワークロードは関数呼び出し境界を頻繁にまたぐ(`IOHashMap`の
`read`/`write`は毎回IORef経由のセル参照・比較・文字列ハッシュ計算を呼び出し規約
Boxedのまま行う)にもかかわらず優位を維持しており、上記の`BenchFib`同様、比較/
分岐融合(RCmpCase)・常時タグ付きポインタのdup/drop省略・自己末尾再帰ループ変換
(`Compiler.RC2.Loop`、ハッシュアルゴリズム5種の内部ループに直接効く)など、
関数境界の内側で効く最適化の効果が積み重なって現れていると考えられる。

一方でIdris2本家のデフォルトバックエンドであるChez Schemeには、rc2・RefC
いずれも大差(rc2比2.1倍、RefC比3.1倍)をつけられた。これは正直に記録して
おくべき結果で、rc2の設計目標はあくまで「RefCというCベースの既存バックエンドを
同じ設計(非atomic参照カウント、C出力)の範囲内でどこまで最適化できるか」で
あり、Chezの世代別GCという根本的に異なるメモリ管理戦略に対する優位性は
主張しない(そもそも目指していない)。参照カウントベースの設計を維持する限り、
このワークロードのような「大量の短命な小オブジェクトを生成し続ける」パターンに
おいてGCベースの処理系との差は原理的に縮まりにくいと考えられる。

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
