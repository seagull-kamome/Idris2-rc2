# クロージャを返す関数のアリティ引き上げ (world arity raising)

(原文: `doc/world-arity-raising.md`。内容が乖離した場合は原文を正とする。)

状態: 2026-09-26から実装済みで、デフォルトで有効
(`Compiler.RC2.ArityRaise`。`--directive noarityraise`で無効にできる)。
`struct-return.md`の未解決の問い「`apply` tails」から派生した。

## 問題

`IO`(またはupstreamの`Core`。`IO (Either Error a)`を包むレコードである)
を返す関数は、world引数が独立したラムダとして切り離された状態でIRに
届くことが多い。関数本体はworldを待つクロージャを組み立てるだけで、
呼び出し側はそのクロージャをすぐに`apply`する。

```
def TTImp.WithClause.mergeMatches  (fun args= [v1, v2, v3, v4] ret= Boxed)
  partial TTImp.WithClause.{mergeMatches:0} missing= 1 [v1, v2, v3, v4]

-- 呼び出し側
let x : Boxed =
  let c : Boxed =
    call TTImp.WithClause.mergeMatches [a, b, c, d]
  apply c [w]
case x of
  Prelude.Types.Left ... -> ...
  Prelude.Types.Right ... -> ...
```

呼び出しのたびに、クロージャの確保、全引数のキャプチャ(つまり
`dup`)、`apply`によるディスパッチ、クロージャの解放が起きる。ラムダが
返す`Either`は`apply`の向こう側にあるので、struct return
(`struct-return.md`)からは見えない。呼び出される側の結果の形が不明
だからである。

末尾が定数クロージャ(何もキャプチャしないクロージャ。
`#Main.{sumPos:0}/1~closure`、`RCConstClosure`)になることもある。
また、関数がどのクロージャを返すかを選ぶ前に、明示的な引数に対して
パターンマッチすることもある。小さな`Core`のクローンを使えば、両方の
例が見られる。

```idris
sumPos : List Int -> Core Int
sumPos [] = pure' 0
sumPos (x :: xs) = if x < 0 then throw' "negative"
                   else sumPos xs `bind` \s => pure' (s + x)
```

```
def Main.sumPos  (fun args= ["v38:Boxed"] ret= Boxed)
  case v38 of
    _builtin.NIL ... -> #Main.{sumPos:0}/1~closure
    _builtin.CONS ... args= [v39, v40] -> partial Main.{sumPos:2} missing= 1 [v39, v40]
```

### この形がどこから来るか

upstream自身のダンプ(`--dumpcases`、`--dumplifted`。
`idris2-src/docs/source/reference/debugging.rst`を参照)を見ると、
この形はすでにcase treeに現れている。エラボレータはまず明示的な引数に
対してマッチし、worldのラムダを各分岐の内側に置く。

```
-- --dumpcases
Main.sumPos = [{arg:0}]: (%case !{arg:0}
  [(%concase _builtin.NIL ... (%lam {eta:0} (Main.pure' [0, !{eta:0}]))),
   (%concase _builtin.CONS ... [{e:2}, {e:3}] (%lam {clam:0} (%case ...)))] Nothing)
-- --dumplifted
Main.sumPos = [{arg:0}][]: %case !{arg:0} of
  { %conalt _builtin.NIL() => <Main.{sumPos:0} underapp 1>()
  | %conalt _builtin.CONS({e:2}, {e:3}) => <Main.{sumPos:2} underapp 1>(!{e:2}, !{e:3}) }
Main.{sumPos:2} = [{e:2}, {e:3}][{clam:0}]: ...
Main.main = ... Main.sumPos(...) @ (!{ext:0}) ...
```

ラムダリフトは、各分岐のラムダを、キャプチャした変数を先頭に、worldを
末尾に並べた独立の関数にする(`args`の後に`scope`)。したがって
`partial`の引数列の末尾にworldを足せば、そのまま飽和した呼び出しに
なる。呼び出し側の`f(...) @ (w)`は、`RCExp`では
`let c = call f ...; apply c [w]`の組になる。

## 測定(idris2-lsp、2026-09-26)

使い捨てのツールをセッションのscratchpadに置き、struct returnを
無効にした最終的な`dumprcexpr`を解析した。

`apply`の末尾をすべて許可した場合にstruct returnが追加する関数は
2,148個ある(これは上限で、4,245個のcase付き呼び出し箇所が4,656個に
なる)。それらの末尾にあるクロージャの出どころは次のとおりである。

| クロージャの出どころ | `apply`の末尾 |
|---|---|
| 呼び出しの結果 | 1,181 |
| コンストラクタのフィールド(`MkMonad`/`MkApplicative`: 283) | 324 |
| パラメータ(継続、`mapTTImp f`) | 253 |
| その他 | 112 |

辞書のフィールドやパラメータは、特殊化しない限り、クロージャが何を
返すかについて何も教えてくれない。しかも上限の合計自体が小さい。
呼び出しの結果は、上で見たパターンに当たる。

- **622個の関数**が、すべての末尾でちょうど1引数足りないクロージャを
  返す(`partial ... missing= 1`、1引数足りない定数クロージャ、
  crash、またはそのような別の関数への末尾呼び出し)。そのうち136個は
  単なるラッパー(`f args = partial g missing= 1 args`)である。
- **4,069個の`apply`箇所**が、それらの1つの呼び出しを飽和させている。
  末尾にあるのが1,057個、**2,826個**がただちにswitchされる。
- worldを追加パラメータとして渡すようにすると、622個のうち338個が
  struct returnの対象になり、2,826個の箇所のうち1,247個が、
  struct returnを行うワーカーへのcase付き呼び出しになる(struct
  returnには現在4,245個のcase付き箇所があり、+29%にあたる)。

このパターンは`Core`風のコードに属する。idris2-missing-containersに
は、こうした箇所が2つある。

## 変換

上記の集合`R`に属する各関数`f`について、パラメータ`w`を1つ増やした
`f#`を作る。

- 末尾の`partial g missing= 1 xs`は`call g (xs ++ [w])`になる。
- 末尾の定数クロージャ`g/1~closure`は`call g [w]`になる。
- `R`に属する`h`への末尾呼び出し`call h ys`は
  `call h# (ys ++ [w])`になる。
- crashはそのまま残す。

`f`自身は単なるラッパー`partial f# missing= 1 args`になる。クロージャ
を保持し続ける(格納する、渡す)呼び出し側は、これまでどおりクロー
ジャを受け取り、結局は同じコードが実行される。`g`の単なるラッパー
`f`には`f#`は要らない。その箇所は`g`を直接呼ぶ。

`R`に属する`f`の呼び出し箇所`let c = call f xs`のうち、`c`がちょうど
1回だけ、直後に評価される`apply c [w]`で使われるものは、
`call f# (xs ++ [w])`になる。直後とは、`let`の本体か、次の`let`の値
(上の例のとおり)を指す。呼び出しを何も飛び越さないので、評価順序は
保たれる。呼び出しは、値の中の`let`の連鎖の末端にあってもよい
(`let c = (let a = ...; call f [a]); apply c [w]`。引数をインライン化
した後に残る形である)。その場合、引き上げた呼び出しは連鎖の末端に
入る。それ以外はすべて、クロージャを保持する。

`R`は、struct returnの計画と同じく最大不動点である。末尾は`let`の
本体と、あらゆる`case`の分岐を通して読み、関数はクロージャの末尾に
少なくとも1つ到達しなければならない。lazyな呼び出しとlazyな`apply`
は対象外とする。引数のない関数(CAF)も対象外である。CAFのクロー
ジャは一度だけ作られて共有される(`caf-memoization.md`を参照)。

## 配置

RCより前の`RCExp`上、「RC normalize」の直後で`ConstFold`の前に置く。

- まだ`dup`/`drop`が存在しないので、書き換えは純粋に構造的なもので
  ある。新しい呼び出しの所有権は、他の呼び出しと同様に`annotate`が
  決める。
- `ConstFold`、`PushCon`、各種の特殊化、各種のインライナーが、直接
  呼び出しを見られる。小さな`f#`は呼び出し元にインライン化される
  可能性があり、そこから返る既知のコンストラクタは畳み込まれる可能性
  がある。
- DualABIは、その後`f#`に、他の関数と同様にネイティブのパラメータ
  とstruct returnを与える。

case treeの段階でラムダを`case`の外へ引き出す
(`\x => case x of { A => \w => a; B => \w => b }`を
`\x, w => case x of { A => a; B => b }`にする)と、形の問題を根元で
解決できる。しかし、case treeはラムダリフトの`Lifted`と同様、de
Bruijnインデックスでスコープを表現しており、パラメータを足すと本体の
インデックスを振り直す必要がある。一方、RCより前の`RCExp`はローカル
をidで名づけている。

`f#`の中の`g`への末尾呼び出しは、通常の末尾呼び出しである。`Loop`は
自己末尾呼び出しを`goto`にし、それ以外は従来どおりトランポリンを
通る。書き換え前は、`f`がクロージャを呼び出し元の`apply`へ返して
いたので、それより深くなることはない。

## 実装

`Compiler.RC2.ArityRaise.applyArityRaise`は、RCより前の`RCExp`に
対して2回動く。1回目は`ConstFold`の直前、2回目はearly inlineの後で
ある。2回目は、間のパスが露出させた箇所(たとえばインライン化された
`bind`)を見つける。1回目で引き上げられた関数は、この時点では引き
上げ後の版の単なるラッパーになっているので、その新しい箇所は引き
上げ後の版を直接呼ぶ。

新しい形によって、既存のバグが2つ表面化した。どちらもこの変更と
一緒に修正した。

- `Sink`が、あるローカルを読む`let`を、そのローカルの`drop`より後ろへ
  移動した(`branch-sinking.md`の「Not sinking a read past its
  operand's drop」)。idris2-lspで`rcexpr-lint`が検出した。
- `MutualLoop`がメンバー間でパラメータのスロットを位置で共有して
  いたため、1つのスロットにあるメンバーのクロージャと別のメンバーの
  `Int`が入りうる状態になり、ネイティブshadowの昇格がそのクロー
  ジャをunboxした(`loop-conversion.md`の「Bugs found」8)。
  `BenchArityRaise`がこれでクラッシュした。現在は、スロットを共有
  するのは、パラメータの同じクラス(Loopが昇格させるネイティブ型で
  分けたもの)の中だけにし、クラスのないスロットは昇格させない。

## 結果(2026-09-26)

idris2-lsp、最終的な`dumprcexpr`。どちらの場合も`rcexpr-lint`に
異常はない。

| | `noarityraise` | 引き上げあり |
|---|---|---|
| 定義 | 22,798 | 19,530(うち1,325個を引き上げ) |
| `apply` | 9,161 | **3,771**(−59%) |
| `partial` | 11,115 | 8,556 |
| structワーカー | 726 | 1,345 |
| `let ... : RetN`(case付きstruct箇所) | 6,164 | **9,952**(+61%) |
| `reuseOffer` | 17,768 | 12,658 |
| `con` | 51,038 | 49,498 |

消えた定義の大半は、クロージャ自身のラムダ(`{f:0}`)である。これは
引き上げ後の版からしか呼ばれなくなって、その中にインライン化された。
残りは、すべての箇所が書き換えられた元の関数である。

`tests/BenchArityRaise.idr`は、`BenchStructReturn`の`step`のチェーン
を、`pure`と`>>=`が`%inline`である(upstreamと同じ)`Core`のクローン
と比べるものである。500万回の呼び出しで、5回のうちの最良値は
**2.15秒から1.02秒**になった。`%inline`がない場合、`bind`がインライン
化されるのはRCアノテーションの後で、そこではこのパスはもう動かない
ため、改善は3.21秒から1.77秒にとどまる。`Test92ArityRaise`は、パター
ンマッチ、定数クロージャ、末尾の委譲、リストに保持して後で適用する
クロージャ、通常の`IO`関数を扱う。

idris2-missing-containers(こうした箇所が2つ。交互に6回実行して最初
の1回を除き、平均を取った): 8.05秒から7.83秒(−2.8%)で、出力は同一
だった。

## `LateInline`の後(2026-09-26に調査)

このパスはRCアノテーションの前に動くので、その後で`LateInline`が初め
て露出させた箇所には、クロージャが残る。idris2-lspの最終IRには、
`apply`の箇所が3,788個残っている。クロージャの出どころ別に見ると次の
とおりである。

| クロージャ | `apply`の箇所 | `LateInline`なしの場合 |
|---|---|---|
| パラメータ(継続、高階引数) | 1,161 | 2,467 |
| 呼び出しの結果 | 1,092 | 860 |
| コンストラクタのフィールド(辞書のメソッド) | 857 | 848 |
| `case`など | 318+ | 262+ |
| 同じ関数内の`partial` | **110**(ぴったり52、引数がより多いもの58) | 75 |

呼び出しの結果のうち186個は、引き上げられた関数のラッパー(`partial
f# missing= 1`)の結果をただちに適用するものである(`LateInline`なし
では72個)。upstreamの`>>=`は`%inline`なので、その展開はRCアノテー
ションの前に起き、このパスから見える。この形を`LateInline`に任せる
ことになるのは、`BenchArityRaise`の`%inline`なし版のような、
`%inline`でない`bind`だけである。したがって`LateInline`後の分は約300
箇所であり、これが下の「RC後のfold」の対象になる。

残りの呼び出しの結果は、おもに、末尾に`partial`とその他のクロージャ
が混在する呼び出し先から来ている。`partial`と`apply`が190、`partial`と
変数が72、`apply`のみが226、呼び出しのみが218である。これらも引き上げ
ること(末尾の`apply h ys`を`apply h (ys ++ [w])`に、変数`x`を
`apply x [w]`に、引き上げていない関数`h`への呼び出しを
`let c = call h ...; apply c [w]`にする)は健全だが、クロージャを節約
できるのは`partial`の分岐だけである。まだ着手していない(`TODO.md`)。

### RC後のfold(2026-09-26に実装、`--directive noapplyfold`)

`LateInline`の直後、`Sink`とDualABIの前で、次の条件を満たす`let c`に
適用する。その値が(先頭の`let`と`dup`を通して)`partial g m xs`で終わ
るか、単なるラッパー`f xs = partial g m xs`の呼び出しで終わること。
かつ、`c`が後でちょうど1回、ループの外の`apply c ys`で適用され、
それ以外では`drop`されるだけであること。

- `|ys| == m`: `apply`は`call g (xs ++ ys)`になる。
- `|ys| == m + 1`で、`g`自身が`h`の、1引数足りない単なるラッパーである
  場合: `call h (xs ++ ys)`になる。

値の先頭にある`let`と`dup`は元の位置に残す。移動するのは、クロー
ジャの構築だけである。`dup`/`drop`は変わらない。`partial`、`call`、
`apply`はいずれも引数を消費し、構築を後ろへ動かしても、それまでの
参照カウントはすべて変わらないからである。クロージャが持っていた
`xs`への参照は、その間のコードが触れなかったものである。アノテー
ションにより、どの経路も`c`をどこかで消費する。したがってどの経路
も、そこで適用するか、(下記のとおり)解放するかのどちらかになる。

クロージャを適用しない経路にある`drop c`は、クロージャが保持して
いたもの、つまり`Boxed`のキャプチャ引数の`drop`になる。クロージャは
新しく作られたもので、他の誰も保持していないので、クロージャの
`drop`はまさにそれらを解放していたはずである。キャプチャされた
`RInlineNative`ローカル(読まれる場所にスプライスされるもの)がある
場合は、その読み出しを動かしてはならないので、クロージャはその場に
残す。

結果: 非`%inline`の`bind`を使う`BenchArityRaise`(Test93の形)は、
1.77秒から**1.18秒**になる(`%inline`ありは1.02秒のままで変わらない)。
idris2-lspでは、`apply`が3,771から3,507に、自分の関数内で適用される
`partial`が110から25に、case付きstruct箇所が9,952から9,984になった。
`rcexpr-lint`に異常はない。`Test93ApplyFold`は、`run`に`apply`が残ら
ないことを検査する。

### 末尾にクロージャが混在する関数の引き上げ: 見積もり(2026-09-26)

未実装。idris2-lspの最終IR(このパスとRC後のfoldを適用済み)では、
呼び出しの結果をただちに適用する`apply`箇所が915個残っている。その
うち839個(呼び出し先は84個。374個がただちにswitchされ、66個が末尾に
ある)では、呼び出し先のすべての末尾が何らかのクロージャである。
呼び出し先ごとに各末尾を等しく重みづけすると、箇所あたりの内訳は
次のようになる。

| 引き上げる末尾 | 重み | クロージャの確保 |
|---|---|---|
| `partial ... missing= 1` → 呼び出し | 250 | 節約される(このパス自身と同じ) |
| `partial ... missing= m > 1` → `partial ... missing= m - 1` | 51 | 1つ節約される |
| `apply h ys` → `apply h (ys ++ [w])` | 270 | `h`が引数不足だった場合に節約される(大半) |
| 変数`x` → `apply x [w]` | 47 | なし(`apply`が移動するだけ) |
| 引き上げていない`h`への呼び出し → `let c = call h ...; apply c [w]` | 222 | なし |

クロージャを確実に節約できる箇所は約300、`apply`の末尾を含めると
570である。これは、このパス自身が対象にした数(4,069)の1割から2割に
あたる。`apply`や変数の末尾があると、引き上げた関数の結果の形が
不明のままなので、このパス自身とは違い、struct returnの利得はほとん
どない。最有力の候補は、`partial`が大半で`apply`の末尾が少数ある関数
である(`goPTerm`が97箇所、`schExp`が80箇所、`processDecl`が12箇所)。
末尾が`partial`と`apply`だけの呼び出し先に限れば、292箇所(うちcase付き
が188)が残り、書き換えにはこのパスに`apply`の規則を足すだけで済む。
これらがどのくらいの頻度で実行されるかは、idris2-lspがC生成に到達
できない間は分からない。

## case tree上で(2026-09-29)

最初の実行を、ラムダリフトの前(`Compiler.RC2.ArityRaiseCExp`)、
インライン化と未使用引数の除去の後に移した。上の「配置」の節では、
そのときcase treeがde Bruijnインデックスで表現されていることを理由に
これを除外していたが、rc2は今ではそれらを名前で読む。すべての末尾が
ラムダ、crash、または同様の別の関数への飽和した末尾呼び出しである
関数に対して、worldの`w`を最後のパラメータとして取る
`rc2_raised_f`を作る。末尾のラムダ`\x => b`は`let x = w in b`になる。
そのため本体は、それが呼び出していたリフト済みの定義ではなく、
引き上げ後の関数の中に置かれる。`f`は`\w => rc2_raised_f args w`に
なり、すべての`(f xs) w`は`rc2_raised_f`を直接呼ぶ。early inlineの後の
実行は、RCより前の`RCExp`上のままである。

idris2-lsp、`rcexpr-lint`に異常なし。RCExp版と比べると次のとおりである。

| | 前 | 後 |
|---|---|---|
| 定義 | 18,921 | 18,213 |
| `con` | 51,716 | 48,571 |
| `partial` / `apply` | 8,019 / 4,006 | 7,499 / 3,672 |
| `dup` / `drop` | 89,424 / 179,394 | 83,513 / 171,149 |
| 値で返されるコンストラクタ | 8,923 | 9,507 |
| `MutualLoop`のfall-through crash | 459 | 96 |

引き上げられた関数が、自分のリフト済みラムダを呼び、そのラムダが
自分を呼び返していた場合、それは単純な自己再帰になる。そのため
マージされる相互ループが減った。アリティ引き上げは0.45秒から0.14秒
に、early inlineは5.52秒から4.76秒に、early inlineの後の実行は0.77秒
から0.27秒になった。
