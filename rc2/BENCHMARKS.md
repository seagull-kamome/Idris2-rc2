# rc2 ベンチマーク結果

過去の計測記録は2026-11-09に破棄した(git履歴にはある)。以降の追記は先頭に新しい順で置く。

## 2026-11-10(夕): セルプール導入後(`991027e`)の再計測

計測時点: idris2-rc-cg `991027e`(PR #311 のマージ後)、idris2-missing-containers `60083f8`、gcc 16.2.0、Chez Scheme 10.4.1、4コア。
他の重い処理は同時に動かしていない。`rc2/tests/bench.sh --runs 5 --missing-containers`(壁時計5回平均)のほか、
Chez版と rc2版のコンパイラで`prelude`/`base`をクリーンビルドした時間(5回)、rc2版コンパイラをセルプール・`malloc`・
mimalloc で動かした比較(3回)を測った。
直前のエントリ(下)は、セルプール(#311)を入れる前、#308・#309 までを含む状態。

### 外部パッケージベンチマーク(idris2-missing-containers)

| backend | avg(s) | rc2との比 |
|---|---|---|
| **rc2** | **3.32** | 1.00 |
| Chez | 8.45 | 2.54倍遅い |
| RefC | 19.90 | 5.98倍遅い |

rc2はRefC比**約5.98倍**、Chez比**約2.54倍**高速。プール導入前のエントリ(3.56秒)から約7%短縮した。

### マイクロベンチマーク(rc2 / 本家`idris2 --cg refc` / `idris2 --cg chez`)

| ベンチマーク | rc2(s) | refc(s) | chez(s) | RefC比 | Chez比 | 前のエントリのrc2(s) |
|---|---|---|---|---|---|---|
| `BenchChain.idr` | 0.0010 | 0.5758 | 1.9384 | 575.8倍 | 1938.4倍 | 0.0010 |
| `BenchCallArgChain.idr` | 0.0040 | 1.4372 | 2.7576 | 359.3倍 | 689.4倍 | 0.0040 |
| `BenchTailFFI.idr` | 0.0040 | 1.2024 | 1.3894 | 300.6倍 | 347.3倍 | 0.0034 |
| `BenchLoopInvariantBoxed.idr` | 0.0010 | 0.2768 | 0.2274 | 276.8倍 | 227.4倍 | 0.0010 |
| `BenchLoopCallArg.idr` | 0.0020 | 0.4816 | 1.5320 | 240.8倍 | 766.0倍 | 0.0022 |
| `BenchLoop.idr` | 0.0010 | 0.1624 | 0.2140 | 162.4倍 | 214.0倍 | 0.0010 |
| `BenchKnownCon.idr` | 0.0270 | 3.4702 | 0.7824 | 128.5倍 | 29.0倍 | 0.0270 |
| `BenchPushCon.idr` | 0.0272 | 3.4782 | 0.8168 | 127.9倍 | 30.0倍 | 0.0270 |
| `BenchConstClosureApply.idr` | 0.0100 | 0.9656 | 0.2312 | 96.6倍 | 23.1倍 | 0.0100 |
| `BenchSpecConstCon.idr` | 0.0100 | 0.9450 | 0.2320 | 94.5倍 | 23.2倍 | 0.0100 |
| `BenchMutual.idr` | 0.0020 | 0.1588 | 0.2146 | 79.4倍 | 107.3倍 | 0.0020 |
| `BenchSpecConstConRec.idr` | 0.0100 | 0.7302 | 0.2300 | 73.0倍 | 23.0倍 | 0.0100 |
| `BenchArityRaise.idr` | 0.0582 | 3.3990 | 1.8442 | 58.4倍 | 31.7倍 | 0.0740 |
| `BenchClosureChain.idr` | 0.0122 | 0.7060 | 0.4586 | 57.9倍 | 37.6倍 | 0.0122 |
| `BenchFib.idr` | 0.0040 | 0.1864 | 0.1782 | 46.6倍 | 44.5倍 | 0.0040 |
| `BenchStructReturnNative.idr` | 0.0574 | 2.3952 | 1.7760 | 41.7倍 | 30.9倍 | 0.0564 |
| `BenchStructReturn.idr` | 0.0578 | 1.6202 | 1.7390 | 28.0倍 | 30.1倍 | 0.0568 |
| `BenchConAltNativeBoxed.idr` | 0.0134 | 0.2296 | 0.2912 | 17.1倍 | 21.7倍 | 0.0150 |
| `BenchBoxedCompare.idr` | 0.1678 | 2.0910 | 0.3988 | 12.5倍 | 2.4倍 | 0.1662 |
| `BenchIORef.idr` | 0.7902 | 8.8914 | 4.5014 | 11.3倍 | 5.7倍 | 0.8502 |
| `BenchConstConFold.idr` | 0.1388 | 1.2008 | 0.8628 | 8.7倍 | 6.2倍 | 0.1330 |
| `BenchStringAlloc.idr` | 8.1582 | 23.3456 | 27.2668 | 2.9倍 | 3.3倍 | 7.81 |
| `BenchListSort.idr` | 0.6946 | 異常終了(※) | 1.2316 | - | 1.8倍 | (新規) |
| `BenchListChurn.idr` | 1.9926 | 異常終了(※) | 2.9504 | - | 1.5倍 | (新規) |

- 24本すべてでrc2がChezに高速。Chez比の最小は`BenchListChurn`の1.5倍、次いで`BenchListSort`の1.8倍、`BenchBoxedCompare`の2.4倍。
- RefC比はRefCが動いた22本すべてでrc2が高速(最小は`BenchStringAlloc`の2.9倍)。
- ※ `BenchListChurn`と`BenchListSort`は、本家RefCのバイナリがセグメンテーション違反(終了コード139、深い非末尾再帰による
  スタックの溢れ)で落ちる。表の時間は落ちるまでの値で、比較に使えない。`bench.sh`はRefCの異常終了を検出しないので、
  表を作った後に実行して確かめた(ほかの22本はRefCも正常終了する)。
- 新しい項目(プール導入後に追加): `BenchListChurn`(300000要素のリストを作り、map・filterして捨てるのを50回)、`BenchListSort`
  (100万個の`Int`の`sort`)。`BenchIORef`、`BenchStringAlloc`は前のエントリで追加したもの。
- 回帰は無い。`BenchArityRaise`の前のエントリ比は0.0740秒から0.0582秒で、この日の最初の測定(0.0602秒)に戻った
  (前のエントリの値が外れ値だった)。
- 数ms以下の項目はタイマーの分解能に近く、倍率の大小は目安に留まる。Chezは起動に約0.2秒かかる。
- `BenchForeignScalar`/`BenchPtr`/`BenchPtrFn`/`BenchPtrMutual`/`BenchPtrWalk`はrc2専用の`CExpr`外部関数を使うためRefC・Chezでは
  ビルドできず、表から除外した。

### baseパッケージのビルド時間(Chez版コンパイラ vs rc2版コンパイラ)

`idris2-src/libs`の`prelude`と`base`(136モジュール)を、毎回クリーンな状態から`--build`した壁時計の5回平均
(ばらつきは±0.1秒未満)。rc2版は`rc2-norepl.ipkg`をrc2でビルドした`idris2-rc2-norepl`(stage1、`gcc -O2`でビルド、セルプール入り)。

| 対象 | Chez版(s) | rc2版(s) | 比(rc2版/Chez版) | プール導入前の比 |
|---|---|---|---|---|
| `prelude` | 4.62 | 5.54 | 1.20 | 1.43 |
| `base`(`prelude`はビルド済み) | 49.83 | 70.21 | **1.41** | 1.68 |

rc2版は`base`で約1.4倍、`prelude`で約1.2倍遅い。プール導入前(1.68倍、1.43倍)から差が縮んだが、逆転はしない。

### rc2自身のビルド時間

| 工程 | 時間(s) |
|---|---|
| Chez版が`rc2.ipkg`をクリーンビルド(`idris2 --build`) | 156.8 |
| 同、パッケージのインストール(`idris2 --install`) | 95.6 |
| rc2版が`rc2-norepl.ipkg`をビルド(`idris2-rc2 --cg rc2 --build`)の合計 | 627.0 |
| うちCコンパイラ(`gcc -O2`、2回の呼び出しの合計) | 539.7 |
| うちCコンパイラ以外(フロントエンド、rc2のパス、C出力) | 87.3 |

全体の約86%がCコンパイラの時間。stage1の実行ファイルは15.78MB(プール導入前は15.27MB)。

### セルプールの効果(同じバイナリを`IDRIS2RC2_POOL`で切り替えた比較)

rc2版コンパイラ(stage1)で`prelude`と`base`をビルドした時間(3回平均)と、マイクロベンチ(5回平均、秒)。
`IDRIS2RC2_POOL=0`は、セルを従来どおり`malloc`で確保する。mimallocは`LD_PRELOAD`で差し込んだもの(`POOL=0`と組み合わせた)。

| 対象 | プール | `malloc` | mimalloc | プール/`malloc` | プール/mimalloc |
|---|---|---|---|---|---|
| `base`のビルド | **70.16** | 90.85 | 79.50 | -22.8% | **-11.7%** |
| `prelude`のビルド | **5.56** | 7.17 | 6.29 | -22.4% | -11.6% |
| idris2-missing-containers(rc2版) | **3.32** | 4.41 | 4.20 | -24.7% | -20.9% |
| `BenchListChurn` | **1.99** | 3.02 | 2.48 | -34% | -20% |
| `BenchListSort` | **0.688** | 0.815 | 0.691 | -16% | 同等 |
| `BenchStringAlloc` | 8.07 | 8.19 | 8.18 | -1% | -1% |
| `BenchIORef` | 0.793 | 0.794 | 0.788 | 差なし | 差なし |
| `BenchPtrMutual`、`BenchPtrWalk` | 0.098 | 0.099 | 0.043 | 差なし | +130% |
| 上記以外のマイクロベンチ | | | | ±3%以内 | ±3%以内 |

- プールは、コンパイラのビルドで`malloc`比約23%、mimalloc比約12%の短縮。リストを作って捨てる処理では`malloc`比34%の短縮。
- `BenchPtrMutual`/`BenchPtrWalk`は`CExpr`の`malloc`を直接呼ぶ(セルではない)ので、プールの対象外。mimallocはC側の`malloc`も置き換えるため速い。
- `POOL=0`は、プールを入れる前のビルドより遅い(`base`は87.3秒から90.8秒)。`cellFree`でセルの大きさからクラスを求める
  分岐が残るため。プールを入れた通常の構成には影響しない。
- 数msのマイクロベンチは、mimallocの初期化で約2ms遅くなる。

## 2026-11-10(午後): プール導入前(#308・#309 まで)の再計測

計測時点: idris2-rc-cg `681c50b`(`origin/master` の `999f50d` に、未マージの PR #309 を取り込んだ使い捨てブランチ)、
idris2-missing-containers `60083f8`、gcc 16.2.0、Chez Scheme 10.4.1、4コア。他の重い処理は同時に動かしていない。
`rc2/tests/bench.sh --runs 5 --missing-containers`(壁時計5回平均)と、`install/selfbuild/`(gitignore下)の計測スクリプト。
2026-11-09に取った最初の計測(`a540f07`)との違いは、#308(IORef/Array/Lazy の lock を単一スレッドで省略)と
#309(`String` のセルと本体を1回の確保にする)だけ。

### 外部パッケージベンチマーク(idris2-missing-containers)

| backend | avg(s) | rc2との比 |
|---|---|---|
| **rc2** | **3.56** | 1.00 |
| Chez | 8.46 | 2.37倍遅い |
| RefC | 19.95 | 5.60倍遅い |

rc2はRefC比**約5.60倍**、Chez比**約2.37倍**高速。`a540f07`の計測(rc2 3.49秒)から変わらない範囲
(rc2単体の実行は、この日の別の計測で 3.43〜3.56 秒の幅があった)。

### マイクロベンチマーク(rc2 / 本家`idris2 --cg refc` / `idris2 --cg chez`)

| ベンチマーク | rc2(s) | refc(s) | chez(s) | RefC比 | Chez比 | a540f07のrc2(s) |
|---|---|---|---|---|---|---|
| `BenchChain.idr` | 0.0010 | 0.5794 | 1.9624 | 579.4倍 | 1962.4倍 | 0.0010 |
| `BenchCallArgChain.idr` | 0.0040 | 1.4494 | 2.7580 | 362.4倍 | 689.5倍 | 0.0040 |
| `BenchTailFFI.idr` | 0.0034 | 1.2058 | 1.3878 | 354.6倍 | 408.2倍 | 0.0032 |
| `BenchLoopInvariantBoxed.idr` | 0.0010 | 0.2780 | 0.2292 | 278.0倍 | 229.2倍 | 0.0010 |
| `BenchLoopCallArg.idr` | 0.0022 | 0.4858 | 1.5312 | 220.8倍 | 696.0倍 | 0.0020 |
| `BenchLoop.idr` | 0.0010 | 0.1624 | 0.2144 | 162.4倍 | 214.4倍 | 0.0010 |
| `BenchPushCon.idr` | 0.0270 | 3.4914 | 0.8178 | 129.3倍 | 30.3倍 | 0.0274 |
| `BenchKnownCon.idr` | 0.0270 | 3.4790 | 0.7800 | 128.9倍 | 28.9倍 | 0.0270 |
| `BenchConstClosureApply.idr` | 0.0100 | 0.9638 | 0.2306 | 96.4倍 | 23.1倍 | 0.0100 |
| `BenchSpecConstCon.idr` | 0.0100 | 0.9442 | 0.2290 | 94.4倍 | 22.9倍 | 0.0100 |
| `BenchMutual.idr` | 0.0020 | 0.1630 | 0.2134 | 81.5倍 | 106.7倍 | 0.0020 |
| `BenchSpecConstConRec.idr` | 0.0100 | 0.7340 | 0.2304 | 73.4倍 | 23.0倍 | 0.0100 |
| `BenchClosureChain.idr` | 0.0122 | 0.7094 | 0.4542 | 58.1倍 | 37.2倍 | 0.0110 |
| `BenchFib.idr` | 0.0040 | 0.1862 | 0.1788 | 46.5倍 | 44.7倍 | 0.0040 |
| `BenchArityRaise.idr` | 0.0740 | 3.4092 | 1.8366 | 46.1倍 | 24.8倍 | 0.0602 |
| `BenchStructReturnNative.idr` | 0.0564 | 2.4092 | 1.7830 | 42.7倍 | 31.6倍 | 0.0602 |
| `BenchStructReturn.idr` | 0.0568 | 1.6292 | 1.7428 | 28.7倍 | 30.7倍 | 0.0574 |
| `BenchConAltNativeBoxed.idr` | 0.0150 | 0.2300 | 0.2882 | 15.3倍 | 19.2倍 | 0.0130 |
| `BenchBoxedCompare.idr` | 0.1662 | 2.0888 | 0.3962 | 12.6倍 | 2.4倍 | 0.1804 |
| `BenchIORef.idr` | 0.8502 | 8.9148 | 4.5116 | 10.5倍 | 5.3倍 | (新規) |
| `BenchConstConFold.idr` | 0.1330 | 1.2016 | 0.8606 | 9.0倍 | 6.5倍 | 0.1384 |
| `BenchStringAlloc.idr` | 7.8770 | 23.4540 | 27.3938 | 3.0倍 | 3.5倍 | (新規) |

- 22本すべてでrc2がRefCにもChezにも高速。RefC比の最小は`BenchStringAlloc`の3.0倍、Chez比の最小は`BenchBoxedCompare`の2.4倍。
- 新しい項目: `BenchIORef`(1つの`IORef`を1億回読み書き)と`BenchStringAlloc`(短い文字列を作って捨てる2千万回)。
  どちらもメモリ管理や同期の固定費が見えるように選んだ。rc2との差は、`BenchIORef`でRefC比10.5倍・Chez比5.3倍、
  `BenchStringAlloc`でRefC比3.0倍・Chez比3.5倍で、ほかの項目より小さい。
- 回帰候補: `BenchArityRaise`が0.0602秒から0.0740秒(+23%)。refcは変わっていない(3.40秒)。
  #309の有無で比べても同じ(#309なし 0.078秒、あり 0.078〜0.089秒)なので原因は#309ではない。#308との関係は
  `a540f07`のランタイムで作り直して比べておらず、未確認。実行時間が約0.07秒と短く、ほかの項目に回帰は無い。
- ChezはRefCより速い項目が多い(`BenchKnownCon`、`BenchPushCon`、`BenchBoxedCompare`等)が、`BenchChain`・
  `BenchCallArgChain`・`BenchLoopCallArg`・`BenchTailFFI`はRefCよりさらに遅い。
- 数ms以下の項目はタイマーの分解能に近く、倍率の大小は目安に留まる。Chezは起動に約0.2秒かかるため、
  短いベンチマークのChez列は大半が起動時間。
- `BenchForeignScalar`/`BenchPtr`/`BenchPtrFn`/`BenchPtrMutual`/`BenchPtrWalk`はrc2専用の`CExpr`外部関数を使うため
  RefC・Chezではビルドできず、表から除外した。

### baseパッケージのビルド時間(Chez版コンパイラ vs rc2版コンパイラ)

`idris2-src/libs`の`prelude`と`base`(136モジュール)を、毎回クリーンな状態から`--build`した壁時計の5回平均
(ばらつきは±0.1秒未満)。

- **Chez版**: `install/bin/idris2`(アップストリームのコンパイラ。Chez Scheme上で動く)
- **rc2版**: rc2で`rc2-norepl.ipkg`をビルドした`idris2-rc2-norepl`(stage1、`gcc -O2`でビルド)

| 対象 | Chez版(s) | rc2版(s) | 比(rc2版/Chez版) |
|---|---|---|---|
| `prelude` | 4.64 | 6.62 | 1.43 |
| `base`(`prelude`はビルド済み) | 50.02 | 84.01 | 1.68 |

rc2版は`base`で約1.7倍、`prelude`で約1.4倍遅い。`self-hosting.md`第7項の旧計測(`base` 1.65倍、`prelude` 1.35倍)とほぼ同じ。

### rc2自身のビルド時間

| 工程 | 時間(s) |
|---|---|
| Chez版が`rc2.ipkg`をクリーンビルド(`idris2 --build`) | 156.9 |
| 同、パッケージのインストール(`idris2 --install`) | 95.6 |
| rc2版が`rc2-norepl.ipkg`をビルド(`idris2-rc2 --cg rc2 --build`)の合計 | 615.2 |
| うちCコンパイラ(`gcc -O2`、2回の呼び出しの合計) | 527.7 |
| うちCコンパイラ以外(フロントエンド、rc2のパス、C出力) | 87.5 |

全体の約86%がCコンパイラの時間(生成されるCは約114MB、gccは1コアで動く)。

### ランタイム変更の効果(#308、#309)

同じ手順で旧ランタイムと新ランタイムを比べた(マイクロベンチは同じソースを両方のランタイムでビルド)。

| 対象 | 変更前 | 変更後 | 変化 |
|---|---|---|---|
| `BenchIORef`(#308、IORefの読み書き1億回) | 1.80s | 0.85s | -53% |
| `BenchStringAlloc`(#309、文字列の生成と破棄2千万回) | 8.80s | 8.00s | -9% |
| `base`のビルド(rc2版、gcc)、#308のみ | 85.13s | 84.97s | -0.2%(差なし) |
| `base`のビルド、#308 + #309 | 85.13s | 84.01s | -1.3% |
| `prelude`のビルド、#308 + #309 | 6.70s | 6.62s | -1.2% |

- マイクロベンチでは大きく効くが、コンパイラ自身のビルドへの効果は小さい。IORefのlock省略は、`base`のビルドに
  効いていない(コンパイラの状態を持ち回る`Ref`の読み書きが、全体の時間に占める割合は小さいと見られる)。
- #309を入れた`base`のビルド(#308のみ → 両方)は、84.97sから84.01s(-1.1%)。
- 注意: 同じ`stage1`を`CC=clang`(`env.sh`の既定)でビルドすると、バイナリが22MB(gccでは15MB)になり、
  `base`が約78.7秒だった(#309を含む)。`gcc`版との差がCコンパイラによるものかは未切り分け。
  計測では`IDRIS2_CC`でCコンパイラを揃えること。

### mimallocを`LD_PRELOAD`で差し込んだrc2

`install/mimalloc/out/libmimalloc.so`(2026-11-01ビルド)を実行時に差し込んだだけで、rc2のコードは変えていない。
比較の相手は同じバイナリをglibcの`malloc`で動かしたもの(5回平均)。

| 対象 | glibc(s) | mimalloc(s) | 変化 | 前回(`a540f07`) |
|---|---|---|---|---|
| `base`をrc2版コンパイラでビルド | 84.01 | 72.70 | **-13.5%** | -5.1% |
| `prelude`をrc2版コンパイラでビルド | 6.64 | 5.75 | **-13.4%** | -5.5% |
| idris2-missing-containers(rc2版) | 3.55 | 3.59 | +1% | -1.0% |
| `BenchPtrMutual` | 0.0972 | 0.0428 | -56% | -56% |
| `BenchPtrWalk` | 0.0970 | 0.0424 | -56% | -57% |
| `BenchStringAlloc` | 7.81 | 7.92 | +1% | |
| 上記以外のマイクロベンチ | | | ±3%以内(数msの項目はmimallocの初期化で約2ms遅くなる) | |

- 前回(-5%)より効果がずっと大きい。同じmimalloc、同じ計測手順で、変わったのは#308と#309を含むランタイムでstage1を
  作り直した点だけ。その中でglibcの`base`は85.13sから84.01sとわずかしか変わっていないのに、mimallocでは80.77sから72.70sに
  縮んだ。原因(#309で文字列のブロック数が半分になったこと等)は切り分けておらず、推測にとどまる。
- mimalloc込みのrc2版は、Chez版(`base` 50.02s)に対して約1.45倍(glibcでは1.68倍)。
- 外部パッケージ(missing-containers)では、mimallocの効果はない。

## 再現方法

```sh
# リポジトリ直下で
LOG=install/bench-$(date +%Y%m%d).log
source env.sh && (cd rc2/tests && ./bench.sh --runs 5 --missing-containers) > "$LOG" 2>&1
.claude/skills/bench-rc2/compare.sh "$LOG"
```

`--missing-containers`にはChez Schemeが`scheme`としてPATHにあることと、`install/idris2-missing-containers`(無ければ自動でclone)が
必要。十数分かかる。`rc2/tests/verify.sh`とは同時に動かさない(`rc2/tests/build/`を共有する)。

コンパイラ自身のビルド時間(Chez版とrc2版)は、`rc2/tests/selfhost.sh`の手順で作るstage1(`idris2-rc2-norepl`)を使って
`prelude`と`base`を各5回クリーンビルドして計る。Cコンパイラの時間は`IDRIS2_CC`にgccを呼ぶラッパーを指定して分けた。
stage1のCコンパイラは`gcc`に揃えること(`env.sh`の`CC=clang`のままだと別のバイナリになる)。
セルプールの比較は、同じバイナリを`IDRIS2RC2_POOL=1`(既定)、`IDRIS2RC2_POOL=0`(`malloc`)、
`IDRIS2RC2_POOL=0 LD_PRELOAD=install/mimalloc/out/libmimalloc.so`(mimalloc)で動かす。
`bench.sh`はRefCの異常終了を検出しない。表を作った後に、`rc2/tests/build/Bench*_refc`の終了コードを確かめること。
