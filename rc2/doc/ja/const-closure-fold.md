# 定数クロージャ畳み込み(`RCConstClosure`)

(原文: `doc/const-closure-fold.md`。内容が乖離した場合は原文を正とする。)

インターフェース辞書の形をした CAF -- メソッドごとに 1 つの
クロージャからなるレコードで、各クロージャは名前付きトップレベル
関数の、素の、ゼロ埋めされた部分適用 -- は、このパス以前は呼び出しの
たびにゼロから再構築されていた: 6 メソッドの辞書は 6 つの新しい
`idris2rc2_mkClosure` 割り当てと 1 つの新しい `IDRIS2RC2_Constructor`
割り当てを意味し、決してメモ化されなかった(rc2 は自前の CAF 共有を
持たない)。本書は、`Compiler.RC2.ConstFold` の既存の `RCConstCon`
畳み込み(`rc2/doc/const-con-fold.md`)がそのような辞書を貫いて、
全体を 1 つの不死の static へ潰せるようにする拡張と、この拡張が
浮上させた実際の正当性ギャップおよび関連する既存バグを扱う。

## 設計

### `RCLocal` の新しい定数形式

`RCExp.idr` は `RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon`/`RCConstCon` と
並んで 6 つ目の `RCLocal` ケースを追加する:

```idris2
RCConstClosure : Name -> (missing : Nat) -> RCLocal
```

`RCConstCon` と異なり、これは真の葉である: ゼロ埋めされたクロージャは
捕捉引数を一切持たないので、再帰する対象がネストしていない。
`IsConstClosureLocal` は独自の狭い証拠型(`RCConstCon` に対する
`IsConstLocal` の推論を鏡写しにする)で、`IsAnyConstLocal` は 5 つ目の
コンストラクタ `ItIsConstClosure2` を得る。そのため `RCConstClosure`
へ畳まれる辞書フィールドは、`RCConstCon` が既に自身のフィールドに
要求するのと同じ `All IsAnyConstLocal args` の義務を満たす。
`Compiler.RC2.ConstFold` によってのみ構築される。

### 畳み込み(`Compiler.RC2.ConstFold`)

畳み込み自体は 1 つの新しい `RLet` 値分類アーム
(`ConstFold.idr:223-227`)である:

```idris2
RUnderApp _ n missing [] =>
    let body' = foldConst (insert var (Element (RCConstClosure n missing) ItIsConstClosure2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

リテラルな空引数マッチ(`RUnderApp fc n missing []`)は、`n` への
畳み込んで安全な素の参照を、動的かもしれない値を捕捉する畳み込んで
危険な部分適用(`RUnderApp fc n missing (x :: xs)`、既存のキャッチ
オールへ落ちて実際の `RLet` のまま)から区別するものそのものである --
ゼロ引数 `RUnderApp` の中には、非定数になりうるものは何も無い。

この 1 アームと、`RCConstClosure` を `IsAnyConstLocal` として認識する
`isConstLocalProof` ケース以外、**`ConstFold.idr` の他のコードは
変わっていない**。`RCon` 自身の畳み込みケース(`ConstFold.idr:
245-251`、コンストラクタの解決済み `args` に対する `allConstLocal`)は
そのまま: 各フィールドが 5 つ(今や 6 つ)の定数形状のどれを取るか
ではなく、`IsAnyConstLocal` を満たすかどうかだけを既に気にして
いた。インターフェース辞書は構造的には、全フィールドがたまたま
`RCConst`/`RCEmptyCon` の代わりに `RCConstClosure` へ解決される
`RCon` にすぎない -- 既存の機構が、新しい定義横断解析ゼロで、
`[1,2,3,4,5]` や `Just 42` を既に畳んでいたのとまったく同じ方法で、
これを `RCConstCon` へ畳む。

### ステージング(`Compiler.RC2.Emit.Util`)

新しい `boxedConstClosureExpr`(`Emit/Util.idr:809-826`)は、初めて
見たときに `RCConstClosure` をステージングし、以降の参照ごとに
ステージングされた static への参照を返し、`boxedConstConExpr` 自身が
既に使うのと同じ `ConstConDef` 状態に対して重複排除する -- `Eq`/
`Ord RCLocal` が `RCConstClosure` をカバーする(どちらもこの変更で
拡張)と、同じ `(Name, missing)` ペアへ畳まれる 2 つの辞書
フィールドは、別個の重複排除テーブルを必要とせず自動的に同じ
マップキーへ衝突する。`boxedConstConExpr` より単純: ゼロ埋めされた
クロージャは再帰的にステージングする捕捉引数を持たないので、その
関数の `All` インデックス付きの配管はここでは不要。

ステージングされた C の形状は static な構造体リテラル:

```c
static struct { IDRIS2RC2_Header header; void *fn; uint8_t arity; uint8_t filled; }
    const constclosure_7 = { IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CLOSURE), (IDRIS2RC2_Value *(*)())Main_greet_Dog, 1, 0 };
```

これは意図的に `IDRIS2RC2_Closure` の実際のレイアウトを完全には
鏡写しに**しない**。`datatypes.h` の実際の構造体は

```c
typedef struct {
  IDRIS2RC2_Header header;
  void *fn;
  uint8_t arity;
  uint8_t filled;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Closure;
```

-- フレキシブル配列メンバで終わる。素の C はフレキシブル配列
メンバの static 初期化子構文を持たず、いずれにせよ空になる:
`filled` はここでは構築上常に `0`(これはリテラルなゼロ引数
`RUnderApp` からしか来ない)なので、初期化するものが何も無い。
ステージングされた型は代わりに先頭の `header; fn; arity; filled`
メンバ列だけを共有し、配列を完全に省く -- 健全である。`filled == 0`
のとき `i < filled` に対して `->args[i]` を読むものが何も無く、
この特定の static に対して `sizeof(IDRIS2RC2_Closure)` を計算する
ものが何も無い(ヒープ割り当てされることも、実際のフレキシブル
配列メンバレイアウトを仮定する何かに渡されることも決してない)。
特に、`idris2rc2_isUnique`/`idris2rc2_tailcallApplyClosure` の
インプレース成長分岐(`args[filled]` を書き込む)は、不死
(`REFCOUNT_MAX`)ヘッダに対して発火し得ない -- `idris2rc2_isUnique`
は素の `refCount == 1` チェックである。

`IDRIS2RC2_STOCKVAL` は、`RCConstCon` 自身のステージングされた
static、小整数キャッシュ、`ConstDef` 値が既に使うのと同じ不死の
参照カウントマーカ(`IDRIS2RC2_REFCOUNT_MAX`)である -- オーナー
シップ解析(`Compiler.RC2.RC` の `annotate`)は、`RCConstCon` が既に
1 行の追加を必要としたのと同じ一握りの分類ヘルパ(`RC.idr` の
`splitBorrows`/`dropIfLastUse`/`isBoxedOperand`、および `Util.idr` の
`localRepIn`)で `RCConstClosure` を不死として扱う以上の、自身の
変更を必要としない: `idris2rc2_dup`/`idris2rc2_drop` 自身の
`REFCOUNT_MAX` ガードが、ステージングされた値に対するあらゆる
dup/drop を既にランタイム no-op にする。

## より広い適用範囲: 全プログラム自身のエントリポイント

これはインターフェース辞書だけよりもはるかに広く効いていると判明
する。プログラム自身の `{__mainExpression:0}` エントリポイント継続は
それ自体が名前付き関数上のゼロ埋めクロージャなので、この畳み込みは
今や、インターフェースを使うものだけでなく*全ての* rc2 コンパイル
済みプログラムで発火する。`refc-suite/callingConvention` の
ゴールデンファイルはまさにこの理由で再生成が必要だった: そのファイル
の生成 C 内の全ての `tmp_N` 名が 1 つずつ上へずれた(`tmp_4` ->
`tmp_5` など)。コードの形状が変わったからではなく、エントリ
ポイントクロージャのステージングが今や、`tmp_N`/`constcon_N`/
`constclosure_N` 名を発行する同じ共有 `ArgCounter`
(`Emit/Util.idr` の `getNextCounter`)を 1 回進めるからである --
意味変化ではない無害な番号のずれだが、畳み込み自身の普遍性の
目に見える指紋。

## 見つかったバグ

### #1: `Compiler.RC2.DeadCode` が畳まれたクロージャ自身の参照を見通せなかった

`DeadCode.idr` の到達可能性ウォーカー `usedFunctionNamesR` は、
`RCExp` ノードが呼ぶ・参照するかもしれない全ての `Name` を計算した
が、`RCExp` ノード自体しか検査せず -- `RCLocal` 自身のフィールドの
中を決して見なかった。これはこの変更以前は無害だった: どの `RCLocal`
定数形式も自身の `Name` を持たなかった(`RCConstCon` は*コンストラクタ*
名を持つ。`defs` の関数名キーとは別の名前空間で、既に正しく除外
されている)。`RCConstClosure` が存在した瞬間、これは実際の、確認
された正当性ギャップになった -- 畳まれた辞書の、自身のメソッドの
1 つへの唯一残った参照は、`RCConstClosure` フィールドの中に埋め込ま
れた `Name` であり、それを囲む `RCon`/`RCConstCon` 自身の `args`
リストを `RCLocal` レベルで越えて見ないウォーカーには不可視である。
したがって `DeadCode.pruneDeadDefs` は、畳まれた辞書フィールドを
*通じてのみ*到達可能なメソッドを、`Emit.Util` がそのフィールドの
ために生成する不死の static リテラルが自身の C 初期化子内で
シンボルによってそのメソッドを名指しているのに、デッドコードとして
刈り取ってしまう。

**修正**: 新しい `usedFunctionNamesL : RCLocal -> SortedSet Name` が
`RCConstClosure`(`singleton n`)と `RCConstCon`(その `args` に対する
`concatMap usedFunctionNamesL`)へ再帰し、`usedFunctionNamesR` は
末尾の `_ = empty` キャッチオールを持つ関数から、全ての `RCExp`
コンストラクタにわたって真に網羅的なものへ書き直され、それが触れる
全ての `RCLocal` 型フィールド(`RV` 自身のローカル、全ての
`args`/`postDrop` リスト、`RCon` の `reuseFrom`、`RConCase`/
`RConstCase` の `sc` など)に対して `usedFunctionNamesL` を呼ぶ。
古いキャッチオールがギャップを見過ごさせたものである: まだ教えられて
いないノードのクラス全体に対して黙って `empty` を返す関数は、型
チェッカの観点からは、正しく報告するものが何も無い関数と区別
できない。キャッチオールの削除は、ここに一致するケース無しで追加
された将来の `RCExp` コンストラクタを、黙った到達可能性の見逃しの
代わりにコンパイル時のカバレッジエラーへ変える。

**検証方法**: 修正を一時的に戻し(`usedFunctionNamesL` を
`const empty` へ骨抜きに戻す)、再ビルドして確認 -- これは黙った
誤答ではなく実際の C コンパイルエラーを再現する:
`constclosure_N` static 初期化子の中の `error: '...' undeclared here
(not in a function)`。刈り取られた関数自身の C 定義(と、その前方
宣言さえ)が生成された `.c` から完全に不在だからである。これが
リンク段階の "undefined reference" ではなくコンパイル段階の失敗で
あるのは、特に、static 初期化子の address-of が、通常の呼び出し箇所の
参照のようにリンカへ遅延されず、C コンパイラ自体によってチェック
されるからである。修正を戻すと再びビルドしパスする。同じ戻された
ビルドは、このギャップを直接行使するものだけでなく*全ての* rc2
プログラムを壊す -- `{__mainExpression:0}` 自身のエントリポイント
継続が、インターフェースによらずまさにこの機構を通じて畳まれる
(上記「より広い適用範囲」参照)。

### #2: `boxedConstExpr` の `ConstDef` 重複排除キャッシュが `I`/`I64` を衝突させた

この変更が新たに露出させた(それによって導入されたのではない)
関連する既存バグ: `Emit.Util.boxedConstExpr` は `ConstDef` 重複排除
キャッシュを生の `Constant` でキーづけしていたので、同じ値の `I x`
と `I64 x` -- `genConstant` 自身の `I`/`I64` 等価性
(`isReuseConsumingOp` 自身のドキュメントコメントが `cPrimType` に
ついて文書化しているのと同じ等価性)により既に同一の C 名へ
レンダリングされる -- が 2 つの別個のキャッシュエントリとして扱われた。
それぞれが独立に同じ `idris2rc2_constant_Int64_...` 名をステージング
し、C の再定義を生じた。これはこのセッション以前は一度も
トリガされなかった。`litRep` が既にカバーしているにもかかわらず、
ネイティブ適格なリテラルが `boxedConstExpr` を通じて強制される場合に
のみ到達可能だからである -- それは畳まれた `RCConstCon` フィールドの
中から `constConFieldExpr` 自身の `RCConst` ケース経由でのみ起こり
(`inlineExprFor` の `RCConst` アームからは決して起こらない。そちらは
ネイティブ適格なリテラルを代わりにインラインでレンダリングする)、
この追加以前はどのインターフェース辞書も完全に畳まれたことが
なかった。`rc2/tests/refc-suite/integers` 自身の `Cast`/`Neg` 辞書を
`RCConstCon` へ畳むことがこの経路を行使し始めて確認された。

**修正**: 新しい `constDefKey : Constant -> Constant` が、`ConstDef`
に対する全ての `lookup`/`insert` の前に `I x` を `I64 (cast x)` へ
正規化し、他の全ての `Constant` は変えない。

## 防御的な堅牢化: `idris2rc2_trampoline` の `REFCOUNT_MAX` ガード

現行バグの修正ではない(`idris2rc2_trampoline` への全ての呼び出し
箇所が辿られ、新しい関数呼び出し結果、新しく `mkClosure` された
オブジェクト、または既に `idris2rc2_isUnique` をパスした
オブジェクトだけを渡すことが確認された -- 今日書かれているコードの
どれも不死のクロージャにはなり得ない)が、対称性/将来対応のために
追加: `idris2rc2_trampoline` 自身の参照カウントデクリメントは、今や
アトミックデクリメントの前に `c->header.refCount != IDRIS2RC2_REFCOUNT_MAX`
をチェックし、`idris2rc2_drop` が既に持つガードを鏡写しにする。
いつか不死のクロージャを渡す将来の呼び出し元に備えて。

## スコープ / 制限

これは辞書自身の*構築*コスト -- 本書が扱う呼び出しごとの 1 割り当て
-- だけを畳む。辞書を*通じた*ディスパッチ(実際のメソッド呼び出し、
`RCLoc` 読み取りされた辞書フィールドに対する `idris2rc2_applyClosure`)
は完全に不変で、依然として boxed な間接呼び出し。それは別個の、
はるかに大きな問題(辞書値が静的に既知になったら呼び出し箇所を
具体的なメソッドへ特殊化する) -- そのギャップのまだ開いている
半分は `TODO.md` の "Performance: interface-dictionary method dispatch
stays boxed even when the concrete instance is known" 参照。

## フォローアップ(コミット `0e7c755`): エイリアス伝播と一般的な呼び出し引数のケース

上記の元のパス(コミット `a01eaa2`)は、インターフェース辞書 --
`RCon`/`RCConstCon` の中に座る `RCConstClosure` フィールド -- に対して
スコープされ検証された。このセッションで機能をエンドツーエンドで
再検証した際の 2 度目の見直しで、1 つの実際の完全性ギャップと、
1 つのテストされていないが既に動作する一般化が見つかった。

### ギャップ: 既に畳まれたクロージャの `let` 再束縛が伝播しなかった

`ConstFold` の `RLet` 値分類ブロックは既に `RCConstCon` に対する
ミラーアームを持っていた: `a` が定数へ畳まれたら、さらなる
`let b = a` は `a` 自身の使用を解決したままにするだけでなく、`b` も
その同じ定数として `env` へ再入力しなければならない --

```idris2
RV _ cval@(RCConstCon {}) =>
    let body' = foldConst (insert var (Element cval ItIsConstCon2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

(`ConstFold.idr:211-215`)。`RCConstClosure` に対する同等のアームが
存在しなかったので、`let a = someTopLevelFn in let b = a in MkDict a b`
のようなチェーンは `a` を正しく畳んだが、`b` はまったく同じ不死の
値を表しているのに、`b` で黙って伝播を止めた -- `b` は実際の
ランタイムローカルのまま残り、`MkDict a b` 自身の `b` フィールドは
`RCConstCon` 畳み込みの `allConstLocal` チェックに決して到達しなかった。
正当性バグではない(生成コードは依然として妥当で、単に畳み込みを
逃した)が、最初にコミットされた `RCConstClosure` の完全性の実際の
ギャップ。

修正は `RCConstCon` アームと構造的に同一 -- どの定数形状と証拠
コンストラクタに一致するかだけが異なる 2 つ目の `RV` ケース:

```idris2
RV _ cval@(RCConstClosure {}) =>
    let body' = foldConst (insert var (Element cval ItIsConstClosure2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

(`ConstFold.idr:228-232`、`RCConstCon` アームの直後、そもそも
`RCConstClosure` を最初に生成する `RUnderApp _ n missing []` アームの
直前)。

**検証方法。** 真の、*生き残る* `let b = a`(素のローカル間
エイリアス)を rc2 自身の IR へ入れることが、修正自体ではなく難所
だと判明した: Idris2 自身のフロントエンドが、Lifted IR がそれを
見る前に、まさにこの形状を熱心に潰す(`--directive dumplifted` で
手作業で確認 -- 直接書かれた素の `let a = greetFn; b = a in ...` は、
どの関数の中に書かれても、`Compiler.LambdaLift` 自身の出力へ 2 つの
別個の束縛として決して到達しない)。`Test69ConstFoldClosure` は
代わりに `%noinline` パススルーヘルパ(`mkAlias : (String -> String)
-> (String -> String); mkAlias f = f`)経由でそれを再現する --
`%noinline` はそれを*Lifted* IR で実際の呼び出しに保つ
(`--dumplifted` で確認: `Main.main` 自身の定義が依然として
`%let b = Main.mkAlias(!a) in ...`、真の 2 つ目の束縛を示す)。
そして `Compiler.RC2.Inline` -- rc2 自身の、別個の、Lifted レベルの
インライナで、本家の `%noinline` フラグを尊重しない -- が、その後
`mkAlias` の本体(素のパラメータパススルー)を呼び出し箇所へ
差し込み、`b` 自身の値を `ConstFold` が実行される前にまさに
`RV fc (RCLoc a)` へ変える。それは `env` を通じて `RV fc
(RCConstClosure ...)` へ解決され、新しいアームにちょうど着地する。
構造的に確認: アーム無しでは、テスト自身の `MkDict a b` 構築が
生成された `.c` で真の `RCon` のまま(`Main_main` の中の実際の
`idris2rc2_newConstructor(2, 1)` 呼び出し、1 フィールドがランタイム
ローカルからコピーされる); アームありでは、`dict` が、2 つの
フィールドが両方とも*同じ* `constclosure_N` static を参照する単一の
不死の `RCConstCon` へ畳まれ、`Main_main` はコンストラクタ割り当て
呼び出しを一切含まない。

### 一般化: 畳み込みはコンストラクタフィールドに固有ではない

上記の元の設計節は、`RCConstClosure` 畳み込みを完全に `RCon` 自身の
コンストラクタフィールドに対する `allConstLocal` チェック(インター
フェース辞書、`{__mainExpression:0}` の継続)の観点で枠づけている。
しかし畳み込み自体には、その位置に固有なものは実際には何も無い:
`RUnderApp _ n missing []` -> `RCConstClosure` は、束縛された変数の
特定の*消費者*が考慮される前に、`RLet` の値分類の中で一度、一様に
起こる。その束縛を後で読むもの -- コンストラクタフィールド、通常の
関数呼び出し引数、何でも -- は、`RCConstClosure` を含めて
`resolveLocal` がそれを解決するものとしてそれを読む。

`Test69ConstFoldClosure` は、そもそもこれ全体を気にする動機になった
ケースに対してこれを確認する: コンストラクタフィールドではなく、
通常の関数呼び出しへ渡されるゼロ埋めクロージャ引数 -- `TODO.md` が
"Dropped: closure generation for statically-known higher-order function
arguments" として追跡していた `map double [1,2,3,4,5]` の形状
(下記「完全な解決」参照)。テストの `useIt : List Int -> List Int;
useIt xs = map double xs` は、`double` のクロージャ引数を `useIt`
自身のコンパイルされた本体に直接焼き込まれた単一の不死の
`constclosure_N` static へコンパイルし、生成 C 検査によってそれに
対する `idris2rc2_mkClosure` 呼び出しがどこにも**ゼロ**であることを
確認する。`main` の 3 つの別々の呼び出し箇所から `useIt` を呼ぶ
(`useIt [1,2,3]`、`useIt [4,5,6]`、`useIt [7,8,9]`)ことで、畳み込みが
実行ごとに 1 回ではなく、コンパイル時にちょうど*一度*起こることを
確認する: 3 つの呼び出しすべてが同一の `constclosure_N` static を
参照し、どれも自身の呼び出し箇所や `useIt` の中で `double` の
新しいクロージャを割り当てない。

### `TODO.md` のかつての "Dropped: closure generation..." エントリの完全な解決

`TODO.md` にはかつて "Dropped: closure generation for
statically-known higher-order function arguments" と題した節があり、
`double` が静的に既知のトップレベル関数なのに `map double
[1,2,3,4,5]` の形のコードが呼び出しのたびに新しいクロージャ割り当て
を支払う理由を調査していた。2 つの修正方向を検討し、両方を捨てた:

1. **クロージャをキャッシュ/不死化する** -- 当時、
   `idris2rc2_tailcallApplyClosure` の非ユニーク分岐が `REFCOUNT_MAX`
   ガード無しで無条件に参照カウントをデクリメントし、不死の
   クロージャを渡すのを危険にするという信念で捨てられた。この
   セッションの調査中に実際のソースに対して再チェック: その分岐は
   既に完全にガードされた `idris2rc2_drop` を呼んでいるので、実際に
   危険だったことは一度も無い。(1 つの実際のガードされていない
   デクリメントは別の関数 `idris2rc2_trampoline` にあり、いずれに
   せよ対称性/将来対応のためコミット `a01eaa2` で一致する防御的
   ガードが付いた -- 上記「防御的な堅牢化」参照。)
2. **静的に既知の引数ごとに呼び出し先を特殊化する**(汎用の
   高階ヘルパを、異なる関数引数ごとに 1 回クローンする) -- 方向 1
   とは独立に捨てられた。プログラム全体で多くの異なる関数で呼ばれる
   遍在的に使われる汎用ヘルパ(`map`/`filter`/`foldl` の形)が、
   それぞれニアデュプリケートな特殊化コピーを発行し、呼び出しごとの
   割り当てを無制限の生成コードサイズ増加とトレードするからである。
   この理由付けは下記の何にも触れられていない -- 単に必要ないと
   判明しただけ。

方向 1 のブロッカーは古くなっていたと判明し、本書自身の
`RCConstClosure` 畳み込み -- 事実上の方向 1 で、名前付き関数上の
ゼロ埋めクロージャが現れるところならどこでも、呼び出し箇所ごとに
手でトリガするのではなく自動的に適用される -- が、動機となった問題を
完全に解決する。このセッションで経験的に確認済み:

- まさに `map double [1,2,3,4,5]` の形状が、それに対する
  `idris2rc2_mkClosure` 呼び出しがどこにもゼロ残る 1 つの不死の
  `constclosure_N` static へ畳まれる(`Test69ConstFoldClosure`、上記)。
- 実行ごとに 1 回ではなくコンパイル時に*一度*畳まれる: 内部で
  `map double xs` を呼ぶヘルパへの 3 つの別々の呼び出し箇所すべてが
  同一の static を参照する(`Test69ConstFoldClosure`、上記)。
- これをエンドツーエンドで再検証中に見つかった 1 つの完全性ギャップ
  (`let` 再束縛が 1 ホップを越えて伝播しない)自体が今や修正済み
  (`Test69ConstFoldClosure`、上記)。

方向 2(呼び出し箇所ごとの特殊化)は、自身の独立した、依然として
妥当なコードサイズの理由で正しく捨てられたまま -- 単に必要な方向
ではないと判明しただけである。方向 1 が既に別の、より良い方法で
目標を達成しているからである: コード複製変換ではなく、既存の
クロージャ表現に対する割り当て省略なので、汎用ヘルパがいくつの
異なる関数で呼ばれても生成コードサイズには何のコストもかからない。

## ファイル

- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCLocal` の新しい
  `RCConstClosure` ケース、`IsConstClosureLocal`、`IsAnyConstLocal` の
  5 つ目のコンストラクタ、および `Eq`/`Ord`/`Show` の追加。
- `rc2/src/Compiler/RC2/ConstFold.idr` -- `RUnderApp _ n missing []`
  に対する新しい `RLet` 値分類アーム、および `isConstLocalProof` の
  新しいケース; 加えて(コミット `0e7c755`)既に畳まれたクロージャ
  定数をさらなる `let` 再束縛を通じて伝播させるミラーの
  `RV _ (RCConstClosure {})` アーム。
- `rc2/src/Compiler/RC2/Emit/Util.idr` -- `boxedConstClosureExpr`、
  `boxedConstExpr` の `constDefKey` 修正、および
  `constConFieldExpr`/`inlineExprFor`/`repOfLocal`/`varName` へ追加
  された `RCConstClosure` ケース。
- `rc2/src/Compiler/RC2/DeadCode.idr` -- `usedFunctionNamesL`、および
  `usedFunctionNamesR` の網羅的な書き直し。
- `rc2/src/Compiler/RC2/RC.idr` -- `annotate` の `splitBorrows`/
  `dropIfLastUse`/`isBoxedOperand`/`(RV fc v)` ケース、`RCConstClosure`
  を不死として扱うよう拡張。
- `rc2/src/Compiler/RC2/Util.idr` -- `localRepIn` の `RCConstClosure`
  ケース(常に `RBoxed`)。
- `rc2/support/rc2/runtime.c` -- `idris2rc2_trampoline` の防御的
  `REFCOUNT_MAX` ガード。
- `rc2/support/rc2/datatypes.h` -- `IDRIS2RC2_Closure` の実際の
  レイアウト(参照のみ、未変更)と `IDRIS2RC2_STOCKVAL`/
  `IDRIS2RC2_REFCOUNT_MAX`(そのまま再利用)。
- `rc2/tests/Test69ConstFoldClosure` -- この畳み込みの統合された
  回帰スイート; ここで関連する節は:
  - §1(旧 `Test69ConstFoldClosureDict`) -- 構造的回帰: 3 メソッドの
    `Greeter Dog` インスタンス辞書が 3 つの `RCConstClosure`
    フィールドからなる単一の `RCConstCon` へ畳まれる。`--directive
    dumprcexpr` と、辞書を構築する `idris2rc2_mkClosure` 呼び出しが
    生成された `.c` に無いことの grep で確認。
  - §2(旧 `Test71ConstFoldClosureDeadCodeSurvival`) -- `DeadCode`
    修正そのもの: 畳まれた辞書フィールド経由でのみ到達可能な
    メソッド(`secretG`)と、それだけが呼ぶ 2 ホップ目のヘルパ、
    両方が `pruneDeadDefs` を生き残らねばならない。
  - §3(旧 `Test72ConstFoldClosureAliasFold`、コミット `0e7c755`)
    -- `RCConstClosure` ミラーアーム修正: 既に畳まれたクロージャの
    `%noinline` 仲介の `let` エイリアスが、依然として `MkDict a b` を
    単一の不死の `RCConstCon` へ畳む。
  - §4(旧 `Test73ConstFoldClosureCallArg`、コミット `0e7c755`)
    -- 一般的な呼び出し引数のケース(`map double [1,2,3,4,5]` の形):
    クロージャ引数が、3 つの別々の呼び出し箇所にわたって同一に共有
    される 1 つの不死の static へ畳まれる。生成 C 検査で
    `idris2rc2_mkClosure` 呼び出しをゼロ必要とすることを確認。
- `rc2/tests/Test70ConstFoldClosureCallthrough` -- 結果として得られる
  不死のクロージャを通じた 500 反復のディスパッチの正当性/valgrind
  クリーンさ。`Test18ClosureInPlaceGrow` 自身の厳密さをモデルに
  している。(独自のテストのまま保持 -- valgrind 下の長いループは
  統合スイートに属さない。)
