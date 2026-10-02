# `RApp`のN引数化: カリー化されたクロージャ適用の連鎖を1回のディスパッチにまとめる

(原文: `doc/rapp-nary-closure-apply.md`。内容が乖離した場合は原文を正とする。)

## 動機

`rc2/doc/speculative-closure-specialization.md`の動機の節と、`TODO.md`の「Performance: interface-dictionary method dispatch stays boxed even when the concrete instance is known」の項は、どちらも同じ実コストを同じ原因に帰している。*boxedなクロージャ値*(interface辞書のメソッド、あるいは普通の高階関数の引数)に対するカリー化された多引数の適用は、1引数の`RApp`ノードの連鎖にコンパイルされ、各ノードが個別に`idris2rc2_applyClosure`を通る、という原因である。

`HashAlgorithm`の`feed8`(アリティ2、`acc -> byte -> acc'`)では、これが1バイトあたり2回のboxedディスパッチになる。生成されたCを見ると、1回目の(まだ部分適用の)適用のために、ヒープ上の`IDRIS2RC2_Closure`が実際に中間値として確保されている。呼び出し全体は必ずすぐに全引数が揃うにもかかわらず、である。

先行する2つの調査は、`apply`を含む関数を*特殊化*または*複製*してboxedディスパッチを直接呼び出しに解決する方針を提案していた(`SpecClosure`自身のクロージャ引数特殊化、あるいは`feedCharOfString`を辞書ごとに複製する案)。本書は同じコストのうち、より安価で常に安全な側、すなわち1引数ずつのboxedディスパッチの連鎖そのものを解消する。何も複製しないので、クロージャの最終的な対象が静的に分かるかどうかに関係なく効果がある。

この変更は、将来の`SpecClosure`型の対象別最適化と併用できる(置き換えるものではない)。実行時にしか対象が分からない完全に汎用なクロージャでも、残りの`missing`個の引数を`missing`回の連鎖ではなく1回のディスパッチで適用できるからである。

## 採用した設計: 新ノードではなく`RApp`自体を一般化する

`RApp`の隣に新しい`RAppClosureN`コンストラクタを追加する案も検討したが、採用しなかった。`Compiler.RC2.RAppName`(*名前付き*関数の呼び出し)は、名前付き呼び出しのアリティが常に事前に分かるという同じ理由で、すでに`List RCLocal`を取っている。このGADTの中で`RApp`(*クロージャ*呼び出し)だけが引数1個に固定されているのであって、これが標準というわけではない。そこで一般化する。

```idris
RApp : FC -> (lazy : Maybe LazyReason) -> RCLocal -> List1 RCLocal -> RCExp
```

(`List1`にしたのは、`RApp`には常に少なくとも1個の引数があり、`Emit`が空の場合を弾く分岐を持たずに済むからである。)

この方式は、兄弟ノードを追加するより厳密に少ないコードで済む。パイプライン全体にある既存の`RApp fc lazy c a`の節は、その場で`RApp fc lazy c args`/`c :: args`に広げれば足りる。対象は次のとおりである。

- `RCExp.idr`の`freeLocalsR`/`countUsesR`/`foldRCNamesL`
- `ConstFold`、`Sink`、`ConAltNative`、`Pretty`、`LateInline`、`SpecClosure`
- `RC2.rcSizeOf`、`Emit`、`Loop`
- `RC.idr`のPhase 1/2

新ノードを追加する場合は、これらのファイルの大半に新しい節を書く必要がある。しかも、所有権のロジックが`c`と`a`を2要素のリストとして扱っている箇所(`splitBorrows`/`wrapDups`、`countInvariantDups`/`wrapInvariantDups`、`countDupsNeeded`/`wrapNDups`)では、いずれにせよ拡張が要る。

単一要素の場合の`RApp fc lazy c [a]`は、現在の形とバイト単位で一致する。したがって後方互換性は保たれ、更新が必要な箇所はIdris2自身の網羅性検査がすべて指摘してくれる。

## 引数リストはどこで作るか: 後続のパスではなくPhase 1

`RLet`でつながった1引数の`RApp`を1つに戻す「連鎖の畳み込みパス」を別に設ける案も検討したが、不要と判断した(`SpecClosure.chainArgs`が、より狭い用途のために同様の処理をすでに行っている)。ソースレベルの`f a1 a2 a3`を`Lifted`に変換する`Compiler.LambdaLift`の`unload`は、すでにネストした`LApp`の構造を組み立てているからである。

```idris
unload : FC -> (lazy : Maybe LazyReason) -> Lifted vars -> List (Lifted vars) -> Core (Lifted vars)
unload fc _ f [] = pure f
-- only outermost LApp must be lazy as rest will be closures
unload fc lazy f (a :: as) = unload fc Nothing (LApp fc lazy f a) as
```

`f a1 a2 a3`は`LApp fc Nothing (LApp fc Nothing (LApp fc lazy0 f a1) a2) a3`になる。元の`lazy`タグは*最も内側*の`LApp`(真の呼び出し先`f`を直接包むもの)に付く。2番目以降の適用はすべて`Nothing`を持つ。`unload`のコメント(「rest will be closures」)のとおり、それらは適用済みの中間値であり、単独で遅延になることはない。

このネスト構造は、`Compiler.RC2.RC`のPhase 1(`normalize`)にそのまま届く。`RC.idr`はupstreamの`Lifted`を直接受け取る側であり、`unload`から`normalize`までのあいだに構造を平坦化する処理はない。したがって`normalize`の既存の`LApp`節は、自分の引数を`LApp`でない根まで1回たどるだけでよい。後続のパスで、`RLet`でつながった`RApp`から同じ連鎖を見つけ直す必要はない。

```idris
||| `LApp _ lazy c x`の`c`、`lazy`、`x`を受け取り、ネストした`LApp`のスパインを
||| `LApp`でない根までたどって、引数を元の左から右の順に集める
||| (Compiler.LambdaLiftの`unload`が、最も内側に`lazy`を付ける形で作ったもの)。
||| 根の`lazy`タグは、`unload`の「only outermost [i.e. innermost-built] LApp must
||| be lazy」にあたるものである。それより上のすべての`LApp`は構成上`Nothing`を
||| 持つので、*最も深い*`LApp`の`lazy`フィールドを見れば近似ではなく正確である。
collectAppChain : Lifted vars -> Maybe LazyReason -> Lifted vars -> (Lifted vars, Maybe LazyReason, List1 (Lifted vars))
collectAppChain (LApp _ lazy c a) _ x =
    let (base, lazy0, args) = collectAppChain c lazy a in (base, lazy0, appendl args [x])
collectAppChain c lazy x = (c, lazy, singleton x)
```

`normalize env (LApp fc lazy c a)`の既存の本体(`bindOne env c (\cl => bindOne env a (\al => pure $ RApp fc lazy cl al))`)は、次のようになる。

```idris
normalize env (LApp fc lazy c a) =
    let (base, lazy0, x ::: xs) = collectAppChain c lazy a
    in bindOne env base (\basel => bindOne env x (\xl => bindMany env xs (\xsl => pure $ RApp fc lazy0 basel (xl ::: xsl))))
```

ここでの`fc`は*最も外側*の適用自身のソース位置である。他の多引数ケース(`LAppName`/`LUnderApp`/`LCon`)がノード全体の`fc`に使っているものと同じで、連鎖全体を1つの`RApp`ノードとして扱う方針と整合する。

この方式では、畳み込みのために**クロージャの具体的な対象をコンパイル時に知っておく必要がまったくない**。`SpecClosure`と違って投機的ではなく、採否の判定もない。`Lifted`がすでにスパイン全体をrc2に渡している時点で、構造上の変換を一度行うだけである。プログラム中のクロージャ値に対するカリー化された適用は、辞書であるかどうかを問わず、すべてこの恩恵を受ける。

## ランタイム側: アリティで分岐する既存のswitchを再利用し、新しいswitchは追加しない

`rc2/support/rc2/runtime.c`には、この変更に必要なパターンがすでにある。小さな閉じた範囲のアリティで実装を共有し、それを超えたら汎用の経路にフォールバックする、`idris2rc2_dispatchClosure`の`switch (c->arity)`である(0〜20を扱い、`default`は配列渡しの`FUNSTAR`呼び出し規約になる)。各caseが読むのは`c->args[i]`だけで、クロージャに固有の処理は含まれない。

**ステップ1**: このswitchを、`Closure*`ではなく`(fn, arity, xs)`を直接受け取る形に切り出す。これで、2つ目の呼び出し箇所から重複なしに再利用できる。

```c
static inline IDRIS2RC2_Value *idris2rc2_dispatchFn(void *fn, uint8_t arity, IDRIS2RC2_Value **xs) {
  switch (arity) { /* unchanged body, still 0-20 + default */ }
}
static inline IDRIS2RC2_Value *idris2rc2_dispatchClosure(IDRIS2RC2_Closure *c) {
  return idris2rc2_dispatchFn(c->fn, c->arity, c->args);
}
```

**ステップ2**: `idris2rc2_applyClosureN(IDRIS2RC2_Value *_c, IDRIS2RC2_Value **newArgs, uint8_t n)`を追加する。

```c
IDRIS2RC2_Value *idris2rc2_applyClosureN(IDRIS2RC2_Value *_c, IDRIS2RC2_Value **newArgs, uint8_t n) {
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)_c;
  uint8_t remaining = c->arity - c->filled;

  if (n == remaining && c->arity <= 20) {
    // 1回で全引数が揃う場合: 中間クロージャは作らない。既存の充填済み
    // 引数をdupしてスタック上の作業バッファに置き、新しい引数をその後ろに
    // 並べて、dispatchClosureと*同じ*switchを再利用する。
    IDRIS2RC2_Value *xs[20];
    for (uint8_t i = 0; i < c->filled; ++i) xs[i] = idris2rc2_dup(c->args[i]);
    for (uint8_t i = 0; i < n; ++i) xs[c->filled + i] = newArgs[i];
    IDRIS2RC2_Value *result = idris2rc2_dispatchFn(c->fn, c->arity, xs);
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return idris2rc2_trampoline(result);
  }

  if (n < remaining) {
    // n個を適用してもまだ部分適用の場合: tailcallApplyClosureの
    // 「一意ならその場で更新、そうでなければコピーして拡張」の分岐を
    // +1から+nに一般化したもの。
    if (idris2rc2_isUnique(c)) {
      for (uint8_t i = 0; i < n; ++i) c->args[c->filled + i] = newArgs[i];
      c->filled += n;
      return (IDRIS2RC2_Value *)c;
    }
    IDRIS2RC2_Closure *nc = idris2rc2_mkClosure(c->fn, c->arity, c->filled + n);
    for (uint8_t i = 0; i < c->filled; ++i) nc->args[i] = idris2rc2_dup(c->args[i]);
    for (uint8_t i = 0; i < n; ++i) nc->args[c->filled + i] = newArgs[i];
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return (IDRIS2RC2_Value *)nc;
  }

  // n > remaining(過剰適用。たとえば、呼び出しの根自身がさらに引数を
  // 要する別の関数を返す場合)、またはarity > 20(FUNSTARの領域で、
  // 高速経路の対象外)の場合: 完全に汎用な、すでに正しい1引数ずつの
  // フォールバックを使う。過剰適用では、反復は多くても`remaining`回で済む。
  IDRIS2RC2_Value *it = _c;
  for (uint8_t i = 0; i < n; ++i) it = idris2rc2_applyClosure(it, newArgs[i]);
  return it;
}
```

アリティごとの新しいswitchも、`n`ごとのコード生成も要らない。`n`に上限を設ける必要もなく、フォールバックのループがどんな`n`でも無条件に処理する。効いてくる上限は、`dispatchFn`にもともとあるアリティ20の制限だけである。これは2つの呼び出し箇所で共有されるので、引き上げるときも1箇所を変えれば済む。

## Emit側の変更

`Compiler.RC2.Emit`の`RApp`節(`emitRC sink (RApp fc _ closure arg) tailPosition`)は、`length args`で分岐する。

- `[a]`(圧倒的に多いケースで、この変更以前から存在するものはすべてこれにあたる): 現在と同一のコード生成で、`idris2rc2_applyClosure`/`idris2rc2_tailcallApplyClosure`を使う。
- `a :: rest`(2個以上): 生成したオペランドから、スタック上に小さな`IDRIS2RC2_Value *argsN[]`を作り、`idris2rc2_applyClosureN`を呼ぶ(`NotInTailPosition`の場合)。

末尾位置でのN引数版のランタイム関数は将来の課題であり、今回は試みていない。`idris2rc2_tailcallApplyClosure`の契約(呼び出し元自身の末尾ループのために、ディスパッチしていないクロージャを返す)に対応するN引数版の兄弟が別途必要になる。上の`applyClosureN`は常にその場でディスパッチするので、`tailcallApplyClosure`ではなく`applyClosure`に対応する。

`InTailPosition`では、代わりに既存の1引数プリミティブを連鎖させる。ただし`idris2rc2_tailcallApplyClosure`を使ってよいのは**最後の1回だけ**で、それ以前はすべて`idris2rc2_applyClosure`を通さなければならない。最初の実装ではすべての段で`tailcallApplyClosure`を連鎖させたところ、実際にクラッシュした(`Test111Basics/Basics.idr`、`free(): invalid size`)。

原因は次のとおりである。`tailcallApplyClosure`は、`filled == arity`になっても決してディスパッチしない。末尾ループがディスパッチとトランポリンのコストを毎回払わずに蓄積を続けられるようにするためで、これがこの関数の契約である。したがって、*前の*段が適用先のクロージャを完成させてしまうと、次の連鎖した`tailcallApplyClosure`はそのクロージャをさらに拡張しようとし、確保領域の1スロット先に書き込む。

これは仮定の話ではない。`Prelude.IO`の`io_bind`融合ワーカー(`Compiler.Inline`が特別扱いして脱糖するもの)は、連鎖の途中の位置に*あと1引数で完成する*クロージャを日常的に渡す。そのため、連鎖した2回の適用の1回目で、すでにそのクロージャが完成する。`idris2rc2_applyClosure`にはこの問題がない。完成した時点で即座にディスパッチし、返ってきた新しい値を連鎖の次の段に渡すからである。これは、統合前の1引数`RApp`を1ノードずつたどる連鎖がすでにしていたことと正確に一致する。

## これによって部分的に単純化できるもの: `SpecClosure.chainArgs`

`SpecClosure.idr`の`chainArgs`は、ちょうど`missing`個の引数に達する適用の連鎖を、`RLet`でつながった`RApp`の列をたどって再発見するために存在する。ソースレベルの`v x y`(構文上1つの適用)は、`SpecClosure`に届く時点ですでに統合された1つの`RApp v [x, y]`ノードになっている。`collectAppChain`がPhase 1で統合するので、`SpecClosure`が走るより前の話である。これはまさに`feed8`型のコードで、本書の動機にあたる。したがって、`chainArgs`の「1段で、引数の数が過不足なく一致する」場合が、むしろ一般的なケースになる。

ただし、完全に不要になるわけではない。ソース自身に書かれた、本物の`let`束縛による中間の部分適用(`let partial = v x in ... partial y ...`のように、構文上別々の2つの適用が独立した束縛を持つもの)は、`RLet`でつながった2つの別々の`RApp`ノードを生成する。`collectAppChain`が統合するのは*直接ネストした*`LApp`だけであり、間に明示的な`let`があればネストは本当に途切れている。これは今回の変更で取り除ける副産物ではない。

そのため`chainArgs`は、`RLet`でつながった経路のフォールバックを残し、各段が自身の`RApp`の持つ任意個数の引数を寄与できるように一般化する(常にちょうど1個ではなくなる)。

```idris
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v missing (RLet _ t _ (RApp _ _ c args) cont) =
    if c == v && length args < missing
       then (args ++) <$> chainArgs (RCLoc t) (missing `minus` length args) cont
       else Nothing
chainArgs v missing (RApp _ _ c args) =
    if c == v && length args == missing then Just args else Nothing
chainArgs _ _ _ = Nothing
```

## 所有権とdupの一般化

現在`RApp`の2つのオペランドをリテラルのリスト`[c, a]`として扱っている箇所は、すべて`c :: args`に広げる。各箇所が実装している意味論は変わらず、操作対象のリストのアリティが変わるだけである。

- `RC.idr`のPhase 2 `annotate`: `splitBorrows natives owned [c, a]` -> `splitBorrows natives owned (c :: args)`
- `ConAltNative.idr`の`reannotateFieldOwnership`: `countDupsNeeded fid owned [c, a]` -> `countDupsNeeded fid owned (c :: args)`
- `Loop.idr`の`dupInvariantBoxed`/`existsInvariantUse`/`renameRCExp`: 同様に広げる
- `Sink.idr`の`genuinelyUsedR`、`LateInline.idr`の`hasNonNativeUse`、`RCExp.idr`の`freeLocalsR`/`countUsesR`/`foldRCNamesL`: 同様に広げる

どれも新しい*ロジック*は不要で、オペランドのリストのリテラルを広げるだけである。これは本書を書く前に、すべての呼び出し箇所を読んで確認した(正確な位置は後述の「ファイル」を参照)。

## 検証

`rc2/tests/verify.sh`: 85 passed、0 known、0 failed。valgrindも含む(valgrindが見つけた2つの実バグを修正した後にクリーンになった。後述の「実装中に見つかって修正したバグ」を参照)。

`idris2-missing-containers`の`test/src/Main.idr`を再度ベンチマークした。`speculative-closure-specialization.md`の動機の節が使ったのと同じ、`feedCharOfString` -> `feed8`を通る`write`/`read`のワークロードである。`SpecClosure`は辞書メソッドには届かないので、依然としてboxedで、対象を特定しないディスパッチになる(詳細は同書と、`TODO.md`の「interface-dictionary method dispatch stays boxed」の項を参照)。比較対象は、すでに取り込まれている`HasIO`除去後のベースライン(`write`が約8.14秒、`read`が約0.807秒。エントリ数はそれぞれ約986k、約99k)で、各3回実行した。

| | HasIO除去後のベースライン | + 本変更 | 追加の改善 |
|---|---|---|---|
| write | ~8.14s | ~7.63s | ~6.3% |
| read | ~0.807s | ~0.749s | ~7.2% |

これは設計のねらいと整合している。`feed8`の連鎖した2回のboxedディスパッチ(とその間の中間クロージャの確保)を、1回の飽和呼び出しにまとめた効果である。コードの重複はなく、コンパイル時に辞書の正体を知る必要もない。

## 実装中に見つかって修正したバグ

どちらも`rc2/tests/verify.sh`自身が見つけたもので、コードレビューでは見つからなかった。確認は`valgrind --track-origins=yes`で行った。さらに、クラッシュのスタックトレースだけでは原因箇所を絞れなかったため、`fprintf`を仕込んだ一時的なランタイムビルドも使った。最小の再現コード(`ref <- newIORef 0; modifyIORef ref (+1); v <- readIORef ref; printLn v`)について、`git stash`で変更前後を比較しながら`--directive dumprcexpr`の出力を最初から比べた。

- **`idris2rc2_applyClosureN`の飽和の高速経路が、一意なクロージャ自身の既存の引数をdupしすぎていた。** 最初の版は、ディスパッチの前に`c->args[0..filled-1]`を無条件にdupし、その後`c`を無条件に`idris2rc2_drop`していた。一意でない場合は正しい(`idris2rc2_applyClosure`の既存の高速経路とまったく同じ)。しかし*一意な*クロージャでは、充填済みの各引数を二重に数えてしまう。dupしたコピーは意図どおりディスパッチされた呼び出しに消費されるが、`c->args[i]`に残っている*元の*参照が、`c`自身の解体時に余計にもう一度dropされる。オブジェクトが論理的にはまだ使用中なのに、早すぎるfreeが起きる。

  修正は、`idris2rc2_tailcallApplyClosure`がすでにしているのと同じく、`idris2rc2_isUnique(c)`で分岐することである。一意なら、`c->args[i]`をdupせずにそのままディスパッチへ渡し、その後はクロージャの*殻*だけをfreeする(`idris2rc2_trampoline`の解体と同じ)。一意でなければ、従来どおりdupしてからdropする。

  症状は、`Test111Basics/Basics.idr`が何も出力せず、glibcの`free(): invalid size`でクラッシュすることだった(ヒープ破壊は、実際の不正なfreeからかなり離れた、まったく無関係な後続の`idris2rc2_trampoline`呼び出しで検出された)。*このバグ*が原因だと確定できたのは、最小の独立した3引数クロージャの再現コードが正常に動作し、基本的な飽和呼び出しの仕組みの問題ではないと分かった後に、一意か否かの区別を見直したからである。
- **`Emit.idr`の`InTailPosition`の多引数フォールバックが、途中の段を含むすべての段で`idris2rc2_tailcallApplyClosure`を連鎖させていた。** `tailcallApplyClosure`の契約は、`filled == arity`になってもディスパッチしないことである(1つの末尾ループ内の蓄積で連鎖させても安全で安価なのは、このため)。無条件に連鎖させるのは、連鎖の最後の引数より前に、*途中の*段が適用先のクロージャを完成させることはないと仮定している。この仮定は誤りだった。`Prelude.IO`の`io_bind`融合ワーカー(`Compiler.Inline`が特別扱いして脱糖するもの。`PrimIO.idr`の`io_bind`を読んで確認した)は、連鎖のある位置に、*あと1引数で完成する*部分適用済みのクロージャ(`Data.IORef`のカリー化されたワーカー)を渡す。連鎖の最初の段でそのクロージャはすでに完成し、2つ目の、まだ連鎖している`tailcallApplyClosure`呼び出しが、いっぱいになった確保領域の1スロット先に書き込んでいた。

  `valgrind --track-origins=yes`で「0 bytes after a block of size 40」という不正書き込みを特定し、さらに`idris2rc2_applyClosureN`と`idris2rc2_tailcallApplyClosure`の両方に一時的に`fprintf`を入れて、クラッシュ時のアリティ、filled、nの並びを確認した。

  修正は、最後の段以外のすべてで`idris2rc2_applyClosure`を連鎖させ(飽和した段では安全にディスパッチして続行し、次の段へ新しい値を渡す)、最後の段だけを`tailcallApplyClosure`のままにすることである。これは、統合前の1つの`RApp`を1段ずつ処理するコードがすでにしていたことと同じである。症状は同じ`free(): invalid size`のクラッシュだが、別の呼び出し経路を通って到達した(`Test111Basics/Basics.idr`の`do`ブロック内にある、3つの連鎖した`IORef`操作)。

どちらのバグも、この変更が導入したコード(ランタイム関数`applyClosureN`と、`Emit.idr`の多引数`RApp`の各ケース)に固有のものだった。統合そのもの(`collectAppChain`)は、同じ最小の再現コードについて変更前のコンパイラと`--directive dumprcexpr`を並べて差分比較して検証した。結果は、元の「連鎖した1引数`RApp`」の形と、引数の値も順序もバイト単位で同じだった。上の2つのバグは引数を*どう適用するか*にあり、*何を集めるか*にはなかった。

## 未解決の問題とリスク

- **末尾位置でのN引数適用**: 今回は試みていない。`InTailPosition`の`RApp`は、現状では引数ごとに`idris2rc2_tailcallApplyClosure`を出力する。これにN引数版(ディスパッチしていない、正しく拡張されたクロージャを、外側のループ自身のトランポリンへ返す)を用意するのは、この変更が入った後の自然な次の課題であり、この変更の前提条件ではない。本書の動機の節が引用するプロファイリングによれば、`feed8`型のホットループが実際に時間を費やすのは`NotInTailPosition`の高速経路である。
- **`SpecClosure`との相互作用**: 直交していて併用でき、重複しない。`SpecClosure`は、クロージャ引数が*どの*関数かを(分かる場合には)解決して直接呼び出す。その呼び出し箇所では`idris2rc2_applyClosureN`を一切通らない。この変更は、`SpecClosure`が扱わないケース(辞書の調査によれば、複製なしには構造上扱えないケース)を、より安価にするだけである。
- **統合された呼び出し箇所での`missing`と`args`の長さの不一致**: `collectAppChain`から得られる`args`は、構成上ちょうどソースプログラム自身のカリー化された適用リストである。静的なアリティについては何も主張せず、要求もしない。`idris2rc2_applyClosureN`の3方向の分岐(`remaining`との`==`/`<`/`>`)は、任意の`n`に対して無条件に安全である。これは`idris2rc2_applyClosure`の既存の1引数版が、1段ずつの形ですでに与えている保証と同じである。

## ファイル

- `rc2/src/Compiler/RC2/RCExp.idr`: `RApp`の宣言、`freeLocalsR`/`countUsesR`/`foldRCNamesL`。
- `rc2/src/Compiler/RC2/RC.idr`: Phase 1 `normalize`の`LApp`節(`collectAppChain`、新規)、Phase 2 `annotate`の`RApp`節。
- `rc2/src/Compiler/RC2/ConstFold.idr`、`Sink.idr`、`ConAltNative.idr`、`Pretty.idr`、`LateInline.idr`、`Loop.idr`、`RC2.idr`(`rcSizeOf`): オペランドのリストを機械的に広げただけで、ロジックの変更はない。
- `rc2/src/Compiler/RC2/SpecClosure.idr`: `chainArgs`の単純化(上記参照)。
- `rc2/src/Compiler/RC2/Emit.idr`: `RApp`のコード生成。`length args`による`applyClosure`と`applyClosureN`の切り替え。
- `rc2/support/rc2/runtime.c`/`runtime.h`: `idris2rc2_dispatchFn`(切り出し)、`idris2rc2_applyClosureN`(新規)。
- `rc2/doc/speculative-closure-specialization.md`、`TODO.md`の「interface-dictionary method dispatch stays boxed」の項: この設計が応える調査。本書がこれらに取って代わるわけではない。そこに書かれている「既知の対象ごとにクロージャを複製する」案は、クロージャの正体が静的に分かり、*かつそれが保たれる*場合のための、別の未解決の課題として残る。
