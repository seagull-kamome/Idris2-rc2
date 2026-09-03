# rc2 Stage 5: テストとベンチマーク結果

## 2026-09-03 追記: 呼び出し境界のbox往復排除4件(tail位置FFI・呼び出しチェーン・ループ引数/戻り値)

`Compiler.RC2.DualABI`/`Compiler.RC2.Loop`に、呼び出し境界でのbox化↔unbox化
往復を消す4件の関連する最適化を追加した(コミット613c0b7/6caeba5/f9a96bd/
a87ae5c、設計・実装の詳細は`rc2/doc/dual-abi.md`「Stage 4b」「Extending the
promotion to call-argument chains」、`rc2/doc/loop-conversion.md`「Known
limitation」参照):

1. tail位置の`%foreign`呼び出しも(通常関数のtail呼び出しとは異なり)クロージャ
   +トランポリン経由の遅延評価をやめ、直接インライン展開するようにした
   (`%foreign`の呼び出し先はrc2自身のトランポリン機構に参加しない末端の生C
   呼び出しであり、通常関数のtail呼び出しを除外している論拠——未知長の
   tail呼び出し連鎖によるCスタック増大リスク——が成立しないため)。
2. 呼び出し結果が、演算子のオペランドとしてではなく**別の呼び出しの
   native引数として直接**渡されるだけの場合も、box化→即unbox化の往復を
   回避してnativeのまま渡すようにした(`callArgNativeReads`)。
3. ループ内でアキュムレータがヘルパー関数への**引数**として渡されるだけの
   場合も、native shadow変数への昇格対象にした(`callArgNativeTypes`/
   `buildCalleeTable`、`Compiler.RC2.Loop`)。
4. 同じくループ内で、ヘルパー呼び出しの**戻り値**がそのまま次周のループ
   継続値になる場合も、native shadow化された枠にそのままnativeで書き戻す
   ようにした(`loopContinueNativeReads`、`Compiler.RC2.DualABI`)。

### 新規マイクロベンチマーク3本(`BenchTailFFI.idr`/`BenchCallArgChain.idr`/
`BenchLoopCallArg.idr`)

上記4件のうち、既存の`Bench*.idr`はいずれも該当パターンを踏んでいなかった
(`%foreign`呼び出しがゼロ、呼び出し結果を別呼び出しのnative引数へ直結する
形もゼロ)ため、各パターンを専用に踏む3本を新設した。`rc2/tests/bench.sh`
標準の rc2 vs 本家`idris2 --cg refc`(いずれも自己ビルドコンパイラ)比較、
壁時計3回平均:

| ベンチマーク | rc2(s) | refc(s) | 倍率(RefC比) |
|---|---|---|---|
| `BenchTailFFI.idr`(tail位置`%foreign`呼び出しを500万回) | 0.988 | 1.329 | 約1.35倍高速 |
| `BenchCallArgChain.idr`(呼び出し結果を別呼び出しのnative引数へ直結、500万回) | 0.861 | 1.580 | 約1.83倍高速 |
| `BenchLoopCallArg.idr`(ループアキュムレータをヘルパー呼び出し経由でのみ運ぶ、500万回) | 0.008 | 0.532 | **約66.5倍高速** |

`BenchLoopCallArg`が最も劇的な改善(4件のうち3番目・4番目の最適化が両方効く
複合形)。生成Cを直接確認したところ、この最適化を入れる前は`loop`のワーカー
本体がアキュムレータを毎周box化/unbox化していたが(`idris2rc2_mkInt64`/
`idris2rc2_to_i64`のペアが`goto loop;`のたびに発生)、導入後は入口の1回を
除いてヒープ確保が一切発生しない、native `int64_t`のみで完結する`goto`
ループになった——`Compiler.RC2.Loop`導入時の`BenchLoop.idr`(約60倍高速化)
と同種のパターンがヘルパー呼び出しを挟む形にも広がったかたちである。

新規スモークテスト`Test57LoopCallArgNativeShadow.idr`(旧
`Test58LoopContinueNativePromotion.idr`を統合済み、2番目・3番目の最適化それぞれの
正当性・box除去を生成C直接確認、`verify.sh`の`LEAK_SENSITIVE_TESTS`に
登録、valgrindで0バイトリーク確認済み)。既存の`Bench*.idr`・`Test*.idr`
全件に回帰なし(`verify.sh`: 94 passed, 0 known, 0 failed)。

## 2026-08-18 追記: クロージャ部分適用チェーンのin-place伸長(unique closure fast path)

「ループ変数になっているクロージャも、参照が1(unique)なら再利用できるはず」
という指摘を受けて調査した。コンストラクタのreuse-in-place(`Compiler.RC2.Reuse`)
と違い、クロージャへの一般的な拡張(コンパイル時escape解析で「一箇所で一度だけ
呼ばれる」ことを保証する)は`rc2/doc/reuse-monadic-bind-gap.md`で既に「大規模、
未着手」と判断済みの領域だったためスコープ外としたが、代わりに**IR解析を一切
必要としない、ランタイムだけで完結する最適化**の余地が見つかった。

部分適用を1段ずつ進める`idris2rc2_tailcallApplyClosure`(`rc2/support/rc2/runtime.c`)
は、それまで`refCount==1`(unique)の場合でも毎回新しいクロージャをアロケーション
してコピーしていた。一方`idris2rc2_mkClosure`(`rc2/support/rc2/memory.c`)は元々
`arity`(最終的な引数総数)と`filled`(現時点で埋まっている数)を別々の引数として
受け取っていたにもかかわらず、確保サイズは`filled`分しか取っていなかった。
確保サイズを`arity`分に変えるだけで、そのクロージャの生涯を通じて再アロケーション
が一切不要になる。unique分岐は「新規確保+コピー+free」から「フィールド1個書き
換えるだけ」まで縮む:

```c
/* 変更前 */
IDRIS2RC2_Closure *nc = idris2rc2_mkClosure(c->fn, c->arity, c->filled + 1);
if (c->header.refCount <= 1) {
    memcpy(nc->args, c->args, sizeof(IDRIS2RC2_Value *) * c->filled);
} else {
    for (int i = 0; i < c->filled; ++i) nc->args[i] = idris2rc2_dup(c->args[i]);
}
nc->args[c->filled] = arg;
if (idris2rc2_isUnique(c)) free(c); else --c->header.refCount;
return (IDRIS2RC2_Value *)nc;

/* 変更後 */
if (idris2rc2_isUnique(c)) {
    c->args[c->filled] = arg;
    ++c->filled;
    return (IDRIS2RC2_Value *)c;               /* 確保・コピー・freeなし */
}
IDRIS2RC2_Closure *nc = idris2rc2_mkClosure(c->fn, c->arity, c->filled + 1);
for (int i = 0; i < c->filled; ++i) nc->args[i] = idris2rc2_dup(c->args[i]);
nc->args[c->filled] = arg;
--c->header.refCount;
return (IDRIS2RC2_Value *)nc;
```

共有(非unique)分岐も、従来`c->header.refCount <= 1`(memcpy可否)と
`idris2rc2_isUnique(c)`(`==1`、free可否)という微妙に非対称な2つの判定を
持っていたが、unique分岐が独立したことで単純に「要素ごとdupしてコピー、
refCountを1減らす」の一本道になった。オーバーヘッドはクロージャ1個あたり
高々`(arity - filled)`ポインタ分(Idris2の関数引数は実用上少数)。安全性は
`idris2rc2_mkClosure`呼び出し直後にフィールドを順に埋めるだけの単一シーケンス
(`Emit.idr`の`makeClosureInto`)であること、rc2ランタイムがシングルスレッド
前提(非atomic参照カウント)であることから、構築途中の状態が他コードから
観測されることはない。

### 新規マイクロベンチマーク `BenchClosureChain.idr`(3段の部分適用チェーンを300万回)

| | 変更前 | 変更後 | RefC |
|---|---|---|---|
| rc2(壁時計、3回平均) | 0.482s | **0.287s** | 0.753s(不変) |
| rc2倍率(RefC比) | 約1.56倍高速 | **約2.63倍高速** | - |

rc2自身の実行時間が**約40%短縮**。RefC側はこの変更の対象外(rc2独自ランタイム
のみの変更)のため数値は不変。新規スモークテスト`Test18ClosureInPlaceGrow.idr`
(unique連鎖・共有クロージャの両経路をカバー)を`verify.sh`の
`LEAK_SENSITIVE_TESTS`に追加し、valgrindで0バイトリークを確認済み。他の
`Bench*.idr`(Chain/Fib/Loop/Mutual)には回帰なし。

### 外部パッケージベンチマーク(idris2-missing-containers)再計測: 大幅な追加改善

上記「ループ変数のネイティブ表現化」の節で判明していた通り、`idris2-missing-
containers`のハッシュアルゴリズム内部ループは1バイトごとに`idris2rc2_applyClosure`
をインターフェース経由で2回呼び出す、まさに部分適用チェーンが支配的なホット
パスだった。今回の変更後に同じワークロードを再計測したところ(壁時計時間、
3回実行):

| | 直前の記録値(2026-08-14、デュアルABI+ループshadow後) | 今回(in-place伸長後) |
|---|---|---|
| rc2 | 15.16s | **10.92s**(10.9567s/10.8847s、2回計測の平均) |
| RefC | 21.91s | 20.49s |
| Chez | 7.52s | 7.09s |

RefC/Chezは今回の変更の対象外(それぞれ別ランタイム)なので、両方とも数%
下がっている絶対値の変化はセッション間の環境差(マシン負荷等)によるノイズと
見るべきで、比較の軸は同一セッション内での比率に置く:

| | 直前 | 今回 |
|---|---|---|
| rc2/RefC比 | 約1.45倍高速 | **約1.88倍高速** |
| rc2/Chez比 | 約2.02倍(rc2が遅い) | **約1.54倍**(rc2が遅い) |

RefC優位幅がさらに広がり、Chezとの差も縮まった。`rc2`自身の絶対時間で見ても
15.16s→10.92s(約28%短縮)と、自己/相互末尾再帰ループ変換(17.30s→15.20s、
約12%短縮)を上回る改善幅になっている。今回はフェーズ別の再計測(FNV1a/
MurMur3等の個別タイミング)までは行っていないが、既存の分析(前節参照:
ハッシュ状態がインターフェース経由の部分適用チェーンで1バイトごとに更新
される)と整合する結果であり、ランタイムだけで完結する最適化が実ワーク
ロードにもそのまま波及することを裏付けている。

## 2026-08-14 追記: デュアル呼び出し規約(Compiler.RC2.DualABI、Stage 1〜4完了)

これまでの各セクションで繰り返し「デュアルABI(未実装)を実装しない限りこの
境界は消せない」と記録してきた、呼び出し規約自体がBoxedのままという最大の
ボトルネックに対応した。設計・実装の全体像・発見したバグは
`rc2/doc/dual-abi.md`(英語、詳細版)を参照。ここでは実測結果のみ記録する。

### `BenchFib.idr`(非末尾再帰fib(30))の再計測

`fib`は非末尾再帰(`fib(n-1)+fib(n-2)`が両方とも足し算の被演算子で末尾位置
ではない)なため、これまでの自己/相互末尾ループ変換・比較融合のいずれの
対象にもならず、本ドキュメントの各セクションで一貫して「数値不変」の対照群
だった。デュアルABI(worker/wrapper分割 + 非末尾位置の呼び出しサイト書き換え)
はこの`fib`をまさに主眼として設計されたもので、実際に初めて数値が動いた:

| ベンチマーク | デュアルABI前 | デュアルABI後(Stage 4完了) | RefC | 倍率(RefC比) |
|---|---|---|---|---|
| `BenchFib.idr`(fib(30)) | 0.18s | **0.14s** | 0.21s | 約35%高速 |

(壁時計時間、3回実行の代表値。`time`コマンドで直接計測。)

生成Cコードを直接確認すると、`fib`のworker自身の本体(`idris2rc2_worker_Main_fib_0`)は
以下のように、2回の再帰呼び出しの引数・戻り値ともに一切box化/unbox化されず、
関数の入口から`return`まで完全に`int64_t`のまま計算されている:

```c
int64_t idris2rc2_worker_Main_fib_0(int64_t var_0)
{
    ...
    int64_t var_4 = (var_0 - INT64_C(1));
    int64_t var_3 = idris2rc2_worker_Main_fib_0(var_4);
    int64_t var_6 = (var_0 - INT64_C(2));
    int64_t var_5 = idris2rc2_worker_Main_fib_0(var_6);
    return (var_3 + var_5);
}
```

以前(worker/wrapper分割のみ、呼び出しサイト書き換え未実装の段階)は
`idris2rc2_worker_Main_fib_0(idris2rc2_to_i64(var_0))`のように引数だけがネイティブで、
戻り値は`idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(...))`のように毎回box化され、
それを呼び出し元の`+`が即座に`idris2rc2_to_i64`でunbox化し直すという
往復コストが再帰呼び出し2回のたびに発生していた。これが完全に消えたことが
実行時間の改善に直結している。

### `BenchLoop.idr`/`BenchChain.idr`/`BenchMutual.idr`は既存の効果を維持

これら3本は既に自己/相互末尾再帰ループ変換の対象で、ループ本体自体は
以前から完全ネイティブだった(上記セクション参照)。デュアルABI追加後も
`valgrind --leak-check=full`で参照リークがないことを再確認済み(`definitely
lost: 0 bytes`、`still reachable`の800バイト/100ブロックはsmall-intキャッシュの
immortalエントリのみ)。数値・生成Cコードの構造に変化はない。

### 発見したバグ(参照リーク、valgrindでのみ検出可能)

デュアルABIのworker/wrapper分割自体(Stage 3a)に、昇格されたネイティブ
パラメータをworkerが読む際、元のBoxed引数への参照を一度もdropしない
参照リークが存在した。`fib(30)`では再帰の引数が常にsmall-intキャッシュ
範囲(`[0,100)`、immortalなので drop が no-op)に収まるため、通常の
出力比較(diff)ベースの検証では一切検出できなかった -- `valgrind`で
意図的にキャッシュ範囲外の値を使う合成テスト(`rc2/tests/Test11DualABILeak.idr`)
を作って初めて実際のリーク(200万回の呼び出しでほぼ200万回分)を確認できた。
修正の詳細は`rc2/doc/dual-abi.md`の「Bugs found and fixed」参照。

**教訓**: 出力の正しさ(diff一致)だけでは参照カウントの正しさは保証されない。
`valgrind --leak-check=full`による検証を、今後もdual-ABI・呼び出し規約に
関わる変更の標準的な検証手順に含めることとした。

### 発見したバグ2件目(コンパイルエラー、外部パッケージで発見)・外部ベンチマーク再計測の状況

上記の外部パッケージ`idris2-missing-containers`でデュアルABI導入後の
再計測を試みたところ、以下2つの独立した問題に遭遇した:

1. **rc2自身のバグ(修正済み)**: `RAppNameRep: more than 8 args not yet
   supported`というコンパイルエラー。同パッケージのハッシュアルゴリズム
   実装には(自由変数のラムダリフトにより)9〜23個のトップレベル引数を
   持つ内部関数があり、その一部にネイティブ昇格可能なパラメータが
   含まれていたため、`RAppNameRep`の(8引数を超える場合の抽出機構が
   未実装な)呼び出しレンダリングでクラッシュしていた。rc2自身の
   テストスイートには8引数を超える関数が一つもなく、これまで一切
   発見されていなかった。Stage 3aの時点から存在していたバグ(Stage 4
   由来ではないことをbisectで確認済み)。修正: `applyDualABI`が、
   9引数以上の関数を(`paramEligibility`/`returnEligibility`の判定に
   関わらず)デュアルABI適格性判定そのものから無条件に除外するように
   変更。詳細は`rc2/doc/dual-abi.md`の「Bugs found and fixed」参照。
2. **(訂正: 2026-08-14、ワークスペース全体のクリーンビルド後に再調査)
   実際にはrc2・環境いずれとも無関係な、単純な作業ディレクトリの
   取り違えだった**: 当初`benchmarkHashMap`実行中に`Unhandled input
   for Main.case block`という実行時エラーに遭遇し、デュアルABI導入前の
   コミット・本家の無改造`idris2 --cg refc`でも同じエラーが再現したため
   「rc2・デュアルABIとは無関係な既存の環境問題」と結論していたが、これは
   誤りだった。`test/src/Main.idr`の`benchmarkHashMap`は`"test/input_large"`
   `"test/words"`という**パッケージルートからの相対パス**でファイルを
   開いており(`openFile`失敗時の`Left`分岐は書かれておらずコメントアウト
   されたままなので、パスが誤っていると即`Unhandled input`になる)、
   毎回の計測コマンドを`test/src/`やその配下から実行していたため
   ファイルが見つからずに失敗していた。パッケージルート
   (`install/idris2-missing-containers/`)から実行し直したところ、
   rc2・RefC・Chezの3バックエンド全てで問題なく完走した。以前の
   bisect調査はおそらく毎回同じ誤ったディレクトリから実行していたため、
   「どのコミットまで遡っても、本家RefCでも再現する」という一貫した
   誤った結果になっていたと考えられる。

**結論**: デュアルABI自体に起因する新たなバグはこの過程で見つからなかった
(1つ目のバグはStage 3aから存在した既存のバグで、Stage 4のbisect時に
たまたま発見されただけ)。2つ目は環境問題ではなく調査時の作業ディレクトリ
の誤りであり、パッケージルートから正しく実行すれば再現しない。デュアルABI
導入後の正しい再計測結果は下記「2026-08-14 追記: ワークスペース全体の
クリーンビルド後の外部パッケージベンチマーク再計測」を参照。

## 2026-08-14 追記: ワークスペース全体のクリーンビルド後の外部パッケージベンチマーク再計測

上記の作業ディレクトリ取り違えの訂正を受け、`idris2-src`のidris2 APIパッケージ
から`rc2`コンパイラ本体・ランタイム・`idris2-missing-containers`まで全て一旦
削除してゼロから再構築した上で(ビルドキャッシュ汚染の可能性を完全に排除する
ため)、`refc-suite`回帰テスト19件全てPASSを確認後、パッケージルートから正しく
実行して計測し直した(壁時計時間、3回実行、デュアルABI Stage 1〜4込み)。

| 実行 | rc2 | RefC | Chez |
|---|---|---|---|
| 1回目 | 14.942s | 21.104s | 7.268s |
| 2回目 | 15.074s | 21.528s | 7.581s |
| 3回目 | 15.451s | 23.098s | 7.705s |
| 平均 | **15.16s** | **21.91s** | **7.52s** |

rc2はRefC比で平均**約31%高速**(1.45倍)。ループ変換のみの時点(約30%高速)から
ほぼ横ばいで、デュアルABI追加による目立った改善はこのワークロードでは見られ
なかった。支配的な`IOHashMap`の`write`/`read`フェーズは`IORef`/連結リスト走査
主体でそもそも数値演算の呼び出し境界をあまり跨がず、ハッシュアルゴリズム
本体の非末尾呼び出しも(自己末尾再帰ループの内部に閉じているため)デュアルABI
が主眼とする「関数境界を跨ぐ非末尾呼び出し」にあまり該当しなかったことが
理由と考えられる(上記「ループ変数のネイティブ表現化」節で判明した、
インターフェース経由ディスパッチ・コンストラクタでラップされた数値状態と
いう別の限界要因もそのまま残っている)。3者ともテスト結果(`testHashMap`
3件・`dict`/`words`件数)は一致し、出力の構造的な差異はなし。

## 2026-08-14 追記: ループ変数のネイティブ表現化(Compiler.RC2.Loopの拡張)

自己末尾再帰・相互末尾再帰ループ変換(上記、既存)そのものはループの**呼び出し
規約**(クロージャ+トランポリン→`goto`)を変えただけで、ループパラメータ自体は
依然として毎反復Boxedのまま(`goto`直前でbox化、ループ先頭で読み直す際は
必要に応じて都度unbox)だった。今回追加した最適化は、ループパラメータ自身が
ループ本体内で一貫してネイティブ演算(`ROp`/`RCmpCase`)のオペランドとして
読まれている場合、それを**ループ突入時に一度だけunboxしたネイティブshadow変数**
に昇格し、以後反復のたびに発生していたbox化↔unbox化の往復を完全に除去する
(`Compiler.RC2.Loop`の`applyLoop`、詳細は`TODO.md`/`git log`参照)。

### 自前マイクロベンチマークの再計測(壁時計、5回実行)

| ベンチマーク | 変換前(自己/相互末尾ループ変換のみ) | 今回(ネイティブ shadow 追加後) | RefC | 倍率(RefC比) |
|---|---|---|---|---|
| `BenchLoop.idr`(`sumTo`、300万回) | 0.12s | **0.003s** | 0.18s | 約60倍高速 |
| `BenchFib.idr`(非末尾再帰fib(30)) | 0.18s | 0.18s(不変) | 0.21s | (対象外、変化なし) |
| `BenchChain.idr`(`loopPoly`、300万回) | 0.47s | 0.45s | 0.66s | 約1.5倍高速 |
| `BenchMutual.idr`(相互末尾再帰、300万回) | 0.135s | **0.016s** | 0.18s | 約11倍高速 |

`BenchLoop`/`BenchMutual`で劇的な改善が出た理由は生成Cコードで直接確認できる:
`sumTo`のループ本体(`loop:;` 〜 `goto loop;` の間)が、以下のように**ヒープ確保・
参照カウント呼び出し・関数呼び出しを一切含まない、素の`int64_t`演算のみ**に
なった:

```c
IDRIS2RC2_Value *Main_sumTo(IDRIS2RC2_Value *var_0, IDRIS2RC2_Value *var_1) {
    int64_t var_4 = (var_0 == NULL) ? 0 : (idris2rc2_to_i64(var_0));
    idris2rc2_drop(var_0);
    int64_t var_5 = (var_1 == NULL) ? 0 : (idris2rc2_to_i64(var_1));
    idris2rc2_drop(var_1);
    loop:;
    int64_t tmp_3 = var_5;
    if (tmp_3 == INT64_C(0)) { return idris2rc2_mkInt64(var_4); }
    int64_t var_2 = (var_4 + var_5);
    int64_t var_3 = (var_5 - INT64_C(1));
    var_4 = var_2;  var_5 = var_3;
    goto loop;
}
```

box化/unbox化は関数の入口(1回)と出口(1回、戻り値)にしか残らない。以前は
毎反復で`idris2rc2_mkInt64`(ヒープ確保)+dup/drop一式が発生していたのが完全に
消えたことが、実行時間ベースで約60倍という改善幅に直結している。`BenchMutual`
(`MutualLoop`がマージした合成関数)でも全く同じパターンが確認でき(合成関数
自身のトップレベル引数がネイティブshadow化される)、約11倍の改善につながった。
`BenchChain`は`loopPoly`のループカウンタ自身も今回ネイティブ化されたが、
反復あたりの支配的コストは既に(前段階で)完全ネイティブ化されていた`poly`
本体側にあったため、追加の改善幅は比較的小さい(0.47s→0.45s)。`BenchFib`は
末尾再帰でないため今回の変更の対象外で、数値は不変。

### 外部パッケージベンチマーク(idris2-missing-containers)の再計測: ほぼ効果なし、原因を特定

同じ`idris2-missing-containers`のワークロードを再計測したところ、総実行時間は
**15.0秒**(3回平均、変換前は15.20秒)とほぼ変化がなかった。個々のフェーズ
(FNV1a/MurMur3/OneAtATime/Sip64/Sip32のハッシュ計算、`write`/`read`)も軒並み
変換前とほぼ同じ数値(誤差範囲)だった。

一見「ハッシュアルゴリズムは数値アキュムレータを持つ自己末尾再帰ループのはず
で、大きく効くのでは」と予想していたが、生成Cコードを直接確認したところ、
今回の最適化が**適用対象外になる理由が明確に判明した**:

- `feedCharOfString`の内部ループ`go`(`Data.Hash.Algorithm.Internal.idr`)は
  `Int -> Int -> algo -> algo`(`len`, `n`, `h`)という形で、バイト位置カウンタ
  `n`自体は確かにネイティブshadow化された(`int64_t var_18`)。
- しかし、ハッシュ状態`h`(`algo`型、`HashAlgorithm`インターフェース制約付きの
  多相な値、実体は`FNV1a`/`OneAtATime`等の**コンストラクタでラップされた**
  `Bits64`/`Bits32`)は、今回の最適化の対象に**なり得ない**(ループの
  トップレベル引数そのものがネイティブ型の値である場合しか判定していないため、
  コンストラクタでラップされた値の**中身**をshadow化する仕組みは今回実装して
  いない)。1バイトごとに`idris2rc2_applyClosure`をインターフェース経由で
  2回呼び出し、そのたびに新しい`algo`値をヒープ確保しており、これがループの
  支配的コストになっている。
- さらに、ループの継続条件`n <= len`自体も`Prelude.EqOrd`インターフェース
  経由でディスパッチされる比較(`Prelude_EqOrd__lt_eq_Ord_Int`)であり、
  `RCmpCase`融合(既存の比較/分岐融合最適化)の対象外(この最適化はネイティブ
  PrimFnの直接比較のみを見ており、インターフェースメソッド呼び出しの内部は
  見えない)。そのため、ネイティブ化されたはずの`n`もこの比較のためだけに
  毎回`idris2rc2_mkInt64(var_18)`で**再box化**されている。

実測される生成Cコード(該当部抜粋):

```c
int64_t var_18 = ...; /* n、ネイティブshadow化された */
loop:;
IDRIS2RC2_Value *var_6 = idris2rc2_trampoline(
    Prelude_EqOrd__lt_eq_Ord_Int(var_3, idris2rc2_mkInt64(var_18)));  /* n を再box化してまで呼ぶ */
...
IDRIS2RC2_Value *var_15 = idris2rc2_applyClosure(var_10, var_5);       /* h を1バイトごとに2回インターフェース越しに更新 */
IDRIS2RC2_Value *var_8 = idris2rc2_applyClosure(var_15, idris2rc2_mkBits8(var_16));
```

さらに`benchmarkHashMap`全体の実行時間の大半(10.2秒)を占める`IOHashMap`の
`write`フェーズは、そもそも数値アキュムレータを持つ単純なループではなく、
`IORef`/配列アクセス・バケットの連結リスト走査(コンストラクタベースのADT
走査)が支配的であり、今回の最適化が対象とする形(トップレベル引数が直接
ネイティブ演算のオペランドになるループ)には元々当てはまらない。

**結論**: 今回追加したループパラメータのネイティブ化は、「ループの
トップレベル引数そのものが素のネイティブ型の値であり、かつその型の
ネイティブ演算/比較で直接読まれている」という狭いが実際に頻出する形
(`BenchLoop`/`BenchMutual`のような単純な数値カウンタ・アキュムレータ)には
劇的に効くが、(a) 数値状態がコンストラクタでラップされている(`newtype`的な
ハッシュ状態など)、(b) 比較がインターフェース経由でディスパッチされ`RCmpCase`
融合の対象外、(c) ループ自体が数値アキュムレータではなくIORef/配列/ADT走査が
支配的、という条件のいずれかに当てはまる実ワークロードにはほぼ効果が出ない。
(a)への対応(コンストラクタでラップされた単一フィールドをshadow化する拡張)
は、この計測結果を踏まえた具体的な将来課題として`TODO.md`に追記する価値がある
と考えられる。

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
`Test9SelfTailLoop.idr`(旧`Test10MutualLoop.idr`を統合済み、アリティの異なるグループでのスロットパディング、
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
消せない。(2026-08-14追記: デュアルABI実装後の現在は、`fib`自身のような
非末尾呼び出しについてはこの境界が消えている。上記の冒頭セクション参照。
ただしこれはユーザーコード自身が直接呼ぶ関数の話で、`Prelude.EqOrd`のような
インターフェースメソッド実装自身の境界は依然対象外。)

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
現状では原理的に避けられないコストである。(2026-08-14追記: `poly`自身は
`BenchChain.idr`内でループ本体から呼ばれる非末尾呼び出しであり、デュアルABI
実装後の現在は`x`自身も昇格対象になり得る -- ただし本セクションの数値は
デュアルABI実装前の計測のまま未再計測。)

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

**2026-08-14追記**: デュアルABI(`Compiler.RC2.DualABI`、Stage 1〜4)を実装した。
上記の見込み通り、`BenchFib.idr`(このセクションで「対象外」としていた非末尾
再帰fib)でRefC比約35%高速という、この文書で初めての`fib`自身の数値改善を
確認した。詳細は本文書冒頭の「デュアル呼び出し規約」セクション、設計・実装の
全体像は`rc2/doc/dual-abi.md`参照。

## 外部パッケージベンチマーク: idris2-missing-containers

(以下は初回計測時の記録。デュアルABI Stage 1〜4導入後・ワークスペース全体の
クリーンビルド後の最新計測値は上記「2026-08-14 追記: ワークスペース全体の
クリーンビルド後の外部パッケージベンチマーク再計測」を参照。)

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
