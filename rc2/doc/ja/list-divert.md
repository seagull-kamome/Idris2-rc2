# 上流の末尾再帰版リスト関数の置き換え (`Compiler.RC2.ListDivert`)

(原文: `doc/list-divert.md`。内容が乖離した場合は原文を正とする。)

既定では無効である。`--directive listdivert`(またはプログラム中の`%cg rc2 listdivert`)で有効になる。プログラム全体のコンパイルでのみ動く。

## 問題

`Prelude.Types`は、長いリストでスタックがあふれるバックエンドのために、`::`の下で再帰するリスト関数を、`%transform`規則で末尾再帰のものに書き換える。

| ソース | 実行時 | 走査 | セル |
|---|---|---|---|
| `xs ++ ys` | `tailRecAppend`: `reverseOnto ys (reverse xs)` | `xs`を2回 | 2n。うちn個は中間リスト |
| `map f xs` | `mapTR`: `mapAppend [<] f xs`の後に`<>>` | 2回 | 2n |
| `filter p xs` | `filterTR`: `filterAppend`の後に`<>>` | 2回 | 2k |
| `mapMaybe f xs` | `mapMaybeTR` | 2回 | 2k |

rc2には`Compiler.RC2.Trmc`(`trmc.md`)がある。素朴な`x :: f xs`は、各セルのホールを埋める1つのループになり、セルはn個、スタックは一定である。rc2のもとでは、上流の規則は、すべての`++`、`map`、`filter`、`mapMaybe`の確保と`teardown`を倍にするだけである。`rc2-norepl`のcase treeでは、`++`の形が815回、`mapAppend`が2,086回、`mapMaybeAppend`が185回、`filterAppend`が132回現れる。

## パス

`applyListDivert`は、名前付きのcase treeに対して、`applyLazyCaf`の直後、`InlineCExp`の前に走る(`Compiler.RC2.RC2`)。上流のヘルパーの呼び出しを、すべてrc2独自の定義の呼び出しに変える。その定義は、使われたときにプログラムに追加する。

- `tailRecAppend xs ys`と、インライナがそれを展開して残す形(`reverseOnto ys (reverseOnto [] xs)`、`reverseOnto ys (reverse xs)`)を、`rc2_append xs ys`にする。
- `mapAppend [<] f xs`(`mapTR`は`%inline`なので、フロントエンドが残すのはこの形である)を`rc2_map f xs`に、`[<]`を伴う`filterAppend`/`mapMaybeAppend`を`rc2_filter`/`rc2_mapMaybe`にする。

4つの定義は素朴なもので、TRMCが扱う形をしている(再帰呼び出しが`::`の最後のフィールドにある。`filter`と`mapMaybe`には普通の末尾呼び出しが混ざるが、これはTRMCのフェーズ1が扱う)。`Bool`の選択肢は`B8`の定数である。上流の`Compiler.Opts.Constructor`が列挙型のコンストラクタをそう作るからである。`SnocList`自身の規則には手を付けない。snocリストは、本来逆順に構築されるものである。`length`にも手を付けない(`lengthPlus`は何も確保しない)。

このパスはプログラム全体のコンパイルでだけ走る。追加する定義はプログラムに1つずつであり、モジュール単位のコンパイルでは、モジュールごとにコピーが追加されてしまうからである。

## 計測

効果はプログラムに依存するので、既定では無効にしている。コンパイラ自身の`prelude`のビルドは、すべて短いリストであり、命令数(無効で27.97 G、有効で28.00 G。+0.09%)も時間も変わらない。実行ファイルは5.5%大きくなる(呼び出し箇所ごとの`map`の複製はTRMCのループであり、49行のものが225個ある。対して`mapAppend`の複製は23行のものが197個である)。リストを多用するプログラムでは、時間が約4分の1減る。

| | 前 | 後 |
|---|---|---|
| `BenchListAppend`(50万要素のリスト2つの連結を40回) | 6.80 s | 5.18 s (-24%) |
| `BenchListChurn`(30万要素のmap、filter、sumを50回) | 2.35 s | 1.82 s (-23%) |

`Test178ListDivert`: `listdivert`のもとでは、`++`、`map`、`filter`、`mapMaybe`はIRに上流のヘルパーを残さず、TRMCがホールを埋める。出力は、このディレクティブなしの場合ともRefCとも同じである。

`verify.sh --directive listdivert`は、このパスを有効にしてテスト一式を走らせる。出力はすべて一致する。IRのノードを、`check.sh`がグローバルなディレクティブなしでビルドする版と比べて数える2つの検査(`Test112Numeric`の比較の統合の数、`Test13NativeArgChain`の`noboolfield`の数)は、そこで差を報告する。リストのコードを変えるグローバルなディレクティブであれば、どれでもそうなる。

## 融合(`--directive listfuse`)

`listfuse`(`listdivert`も有効にする)を使うと、同じパスが、差し替えた呼び出しの連鎖を1つのループにする。`rc2_map f (rc2_filter p xs)`という呼び出しは、次に`map`が読むリストを作っていた。今は1つの関数`rc2_fuse_fm`が`f`、`p`、`xs`を受け取り、要素ごとに両方を行う。TRMCがそれを、結果だけを確保する1つのループにする。

- **融合するもの。** `map`、`filter`、`mapMaybe`の呼び出しの連鎖で、6個まで。各呼び出しは、次の呼び出しの最後の引数(リスト)である。また、`xs`がそのような連鎖である`xs ++ ys`も融合する。このときループは`[]`ではなく`ys`で終わる(`rc2_fuse_mf_t`)。長さ1で`++`のない連鎖は、そのまま残す。名前は段を、最初に適用するものから順に綴ったものである(`m`がmap、`f`がfilter、`j`がmapMaybe)。`_t`は終端のリストを表す。定義は形ごと、プログラムごとに1回作る。段の関数はパラメータのままなので、定数のクロージャに対しては、`SpecClosure`がそれを引き続き特殊化する。
- **場所。** 差し替えた呼び出しを作る呼び出しの書き換えの中で、ボトムアップに行う。そのため、内側の連鎖は、それを読む連鎖より先に融合される。終端のリストを持つ内側の連鎖は延長しない(`map f (xs ++ ys)`は`map f xs ++ map f ys`ではない)。
- **消費者。** 連鎖に対する`foldl`、`foldr`、`length`(`lengthPlus`)も1つのループになる(`rc2_foldl_mf`、`rc2_foldr_m`、`rc2_length_f`)。引数は、段の関数、消費者自身のパラメータ(`g`とアキュムレータ、`z`、またはカウント)、リストである。`foldl`と`length`は末尾呼び出しなので、ループはリストをまったく作らない。`foldr`は元の呼び出しを残し、それが結果を作る。`sum`などは、`Foldable`が特殊化されれば`foldl`である。
- **連鎖に対する`foldMap`** は`rc2_foldMap_<stages>`の呼び出しになる。これは上流の定義そのもの(`foldl (\acc, elem => (<+>) acc (f elem)) neutral`。モノイドは2つの値のレコード)で、連鎖に対する`foldl`を1つのループにしたものである。段の関数、モノイド、`f`、リストを受け取る。小さな呼び出し元では、たいてい`foldMap`がすでに`foldl`へインライン化されており、それが1つとして融合される。これは、そうなっていない場合である(コンパイラで23回使われる)。
- **2回。** `length (filter p xs)`や`sum (map f xs)`が持つ形は、インライン化によって変わる。関数のリスト引数が、本体が1回読む`let`になる(`let l = chain in lengthPlus [0, l]`)。そこでこのパスは`InlineCExp`の後にもう1回走り、本体の最後の引数だけが読む`let`を、呼び出しの引数として扱う。2回目の実行は、1回目が作った定義を追加しない。
- **`++`に対する畳み込み。** `xs ++ ys`(リストは4つまで。それぞれ連鎖でも連鎖でなくてもよい)に対する`foldl`、`foldr`、`length`、`foldMap`は、`xs`を畳み込み、作ったものを持って`ys`に進む。そのため、`++`が作るリストは作られない。`foldr`は逆向きに進む(`ys`の畳み込みが、`xs`の畳み込みの始まりになる)ので、その関数はやはり最後の要素から先に実行される。分割を行う関数は小さく、インライン化される。残るのは各リストのループの呼び出しである(連鎖でないリストには`rc2_foldl_`)。
- **ウォーカー。** プログラムの関数で、名前は何でもよく、本体がパラメータの1つをリストとして分解し(`case p of [] => onNil; x :: rest => onCons`)、`rest`を、同じ位置への自分自身の呼び出しに1回だけ渡すものには、連鎖を与えられる。`rc2_thru_<f>_<stages>`は、その関数自身の定義で、各要素をまず段に通すものである。段が落とした要素については、ほかの引数をすべてそのままにして残りに進む。これは、その要素がリストになかった場合にその関数が行ったであろうことと同じである。残した要素は、その`x`になる。関数が`x`やほかのパラメータで何をしても(アキュムレータ、`::`で作る結果、カウンタ)、リストの残りがその1つの呼び出しだけに読まれる限り、これは成り立つ。`rest`を2回読む関数は段を2回実行してしまうので、手を付けない。このパスが追加する関数は対象外である。
- **中間リストは決して共有されない。** 連鎖は、次の呼び出しの引数に直接入れ子になった呼び出しか、読み手がその引数1つだけの`let`に限る。そのため、中間リストにはほかの読み手がない。

### 何が何になるか

ソースとして書き、右に書き換え後の式を示す。`xs`は、それ自体は連鎖でない任意のリストの式である。NamedCExpでは、呼び出しは`rc2_map f xs`などである。融合したループは、プログラムに追加する定義の呼び出しで、その名前は段を最初に適用するものから順に綴ったもの(`m`がmap、`f`がfilter、`j`がmapMaybe)に、ループがリストで終わる場合は`_t`を付けたものである。

**`map`、`filter`、`mapMaybe`の連鎖**(段の関数を最も内側のものから順に、次にリスト):

| 前 | 後 |
|---|---|
| `map f (map g xs)` | `rc2_fuse_mm g f xs` |
| `map f (filter p xs)` | `rc2_fuse_fm p f xs` |
| `filter p (map g xs)` | `rc2_fuse_mf g p xs` |
| `filter p (filter q xs)` | `rc2_fuse_ff q p xs` |
| `mapMaybe h (map g xs)` | `rc2_fuse_mj g h xs` |
| `map f (filter p (map g xs))` | `rc2_fuse_mfm g p f xs` |

**後ろに`++`が続く連鎖**(ループは`ys`で終わる。段の関数、`xs`、`ys`の順):

| 前 | 後 |
|---|---|
| `map f xs ++ ys` | `rc2_fuse_m_t f xs ys` |
| `map f (filter p xs) ++ ys` | `rc2_fuse_fm_t p f xs ys` |

**連鎖に対する畳み込みまたは`length`**(段の関数、消費者のパラメータ、リストの順):

| 前 | 後 |
|---|---|
| `foldl g z (map f xs)` (`sum (map f xs)`) | `rc2_foldl_m f g z xs` |
| `foldr g z (filter p xs)` | `rc2_foldr_f p g z xs` |
| `length (filter p (map f xs))` (`lengthPlus 0 …`) | `rc2_length_mf f p 0 xs` |
| `foldMap h (map f xs)` | `rc2_foldMap_m f monoid h xs` |

**`++`に対する畳み込み**(各リストのループで、1つの結果が次の始まりになる):

| 前 | 後 |
|---|---|
| `sum (map f xs ++ filter p ys)` | `rc2_foldl_f p g (rc2_foldl_m f g z xs) ys` |
| `length (xs ++ ys)` | `rc2_length_ (rc2_length_ 0 xs) ys` |
| `foldr g z (map f xs ++ ys)` | `rc2_foldr_m f g (rc2_foldr_ g z ys) xs` |

**ウォーカー**(その形の任意の関数。ここでは`sumSq acc [] = acc; sumSq acc (x :: xs) = sumSq (acc + x * x) xs`):

| 前 | 後 |
|---|---|
| `sumSq 0 (map f (filter p xs))` | `rc2_thru_Main.sumSq_fm p f 0 xs` |

**`let`を通して。** インライン化が残すのはこの形である。`let l = <chain or call> in <call> [.., l, ..]`で、呼び出しの引数の1つが`l`であり、ほかに`l`を読むものがなければ、それはその引数に連鎖を置いた呼び出しであり、あとは上の行のいずれかになる。インライン化が分解した関数の中の`length (filter p xs)`は`let l = rc2_filter p xs in lengthPlus [0, l]`であり、これは`rc2_length_f p 0 xs`になる。

書き換えが呼ぶループは次のとおりである(`B8 1`は`True`。`f0`、`f1`、...は順に並べた段の関数)。

```
rc2_fuse_fm f0 f1 xs        -- map f1 (filter f0 xs)
  = case xs of
      []        => []
      x :: rest => case f0 x of
                     1 => let v1 = f1 x in v1 :: rc2_fuse_fm f0 f1 rest
                     0 => rc2_fuse_fm f0 f1 rest

rc2_fuse_mj f0 f1 xs        -- mapMaybe f1 (map f0 xs)
  = case xs of
      []        => []
      x :: rest => let v0 = f0 x in
                   case f1 v0 of
                     Just w1 => w1 :: rc2_fuse_mj f0 f1 rest
                     Nothing => rc2_fuse_mj f0 f1 rest

rc2_fuse_m_t f0 xs ys       -- map f0 xs ++ ys
  = case xs of
      []        => ys
      x :: rest => f0 x :: rc2_fuse_m_t f0 rest ys

rc2_foldl_m f0 g acc xs     -- foldl g acc (map f0 xs)
  = case xs of
      []        => acc
      x :: rest => rc2_foldl_m f0 g ((g acc) (f0 x)) rest

rc2_foldr_f f0 g z xs       -- foldr g z (filter f0 xs)
  = case xs of
      []        => z
      x :: rest => case f0 x of
                     1 => (g x) (rc2_foldr_f f0 g z rest)
                     0 => rc2_foldr_f f0 g z rest

rc2_length_f f0 n xs        -- length of filter f0 xs, `n` the count so far
  = case xs of
      []        => n
      x :: rest => case f0 x of
                     1 => rc2_length_f f0 (n + 1) rest
                     0 => rc2_length_f f0 n rest
```

要素を落とす段(`filter`が偽、`mapMaybe`が`Nothing`)は、リストの残りに進む。要素を残す段は、その結果を次の段に渡す。最後の段の後で、要素を出力する(consする、畳み込む、数える)。`++`と連鎖のループの再帰呼び出しは`::`の最後のフィールドにあり、`Compiler.RC2.Trmc`がそれをループにする。`foldl`と`length`は末尾呼び出しであり、`Loop`がループにする。`foldr`の深さは上流のものと同じである。

**そのまま残すもの:**

- `++`も消費者もない、段が1つの連鎖(`rc2_map f xs`)。
- `map f (xs ++ ys)`: 内側の連鎖に終端があるので、延長しない。
- `(map f xs ++ ys) ++ zs`と`xs ++ (map f ys)`(融合するものがない。`++`の2番目のリストは`++`が読まない)。
- 段が6つを超える連鎖。
- 2回読まれるリスト(`let ys = map f xs in (map g ys, filter p ys)`): `ys`には読み手が2つある。
- インライナが分解しなかった関数をまたぐリスト(`chain`が独立した関数である`sum (chain n)`)。パスに見えるのは連鎖ではなく呼び出しだからである。
- 独自の`foldl'`のような関数、`all`、`any`、`elem`: 消費者の一覧にない。
- リストの残りを2回以上読む関数や、それをほかの関数に渡す関数。
- 解決されていない辞書のメソッドから出てくるリストに対する畳み込み: `Data.SortedMap`の`fromList`は、与えられた`Foldable`のレコードを通して畳み込む。そのレコードは分かっている(インスタンスの`let`)が、このパスはそこからメソッドを取り出さない。

### 設計上の判断: 作用の順序は保たない

融合すると、段の関数が実行される順序が変わる。`map f (map g xs)`は、すべての要素に`g`を実行してから、すべての要素に`f`を実行していた。ループは、1つの要素に`g`と`f`を実行してから、次の要素に進む。純粋な関数なら、これは観測できない。`unsafePerformIO`や`crash`を呼ぶ段の関数は、それを書いた人が純粋とみなしたものであり、その作用は違う順序で起きることがある。後の段がクラッシュするはずだった要素をfilterが落とす場合には、まったく起きないこともある。このパスはそれらを探さない。そのような関数は、純粋として扱われうることを承知のうえで書かれるものであり、ほかのすべてのパスもそう扱う。しかも、この段階全体がオプトインである。IOのループ(`traverse_`、`forM_`、`mapM_`)は別の関数であり、手を付けない。`IO`アクションのリストは`map`が作るだけであり、それを実行するのはその後である。

ウォーカーにあたるIOのループ(`printAll (x :: xs) = do printLn x; printAll xs`)では、IOの作用の順序は保たれる。ループ自身の本体は変わらず、要素が段を通る場所だけが変わるからである。段の関数は、ループの前にすべて実行されるのではなく、ループの作用の合間に1要素ずつ実行されるようになる。そのため、`boom`が5番目の要素でクラッシュする場合の`printAll (map boom xs)`は、4行を表示してからクラッシュする。融合しなければ、何も表示する前にクラッシュする。2回実行されるアクションは段を2回実行し、1回も実行されないアクションは段を実行しない。これは同じ判断(段の関数は純粋とみなす)であり、IOのループについてもそのまま採用した。

### 計測

コンパイラ自身のNamedCExpの調査(静的。差し替えた呼び出しは3,350個): 長さ2の連鎖が約70個、最初の引数が`map`、`filter`、`mapMaybe`である`++`が126個、それらを直接読む畳み込み(`foldMap`、`foldr`、`foldl`)が63個ある。

| | `listdivert` | `listfuse` |
|---|---|---|
| `BenchListFuse`(50万要素の連鎖4つ。うち2つを`sum`と`length`が消費する。40回) | 6.54 s | 5.44 s (-17%) |

コンパイラ自身の`prelude`のビルド(短いリスト。このディレクティブ付きでセルフビルドしたもの。命令数と実行ファイルのサイズ): 無効で27.964 G、15.68 MB。`listdivert`で27.984 G、16.56 MB。`listfuse`で、消費者込みで27.990 G、16.56 MB(消費者の対応前は27.979 G、16.55 MB)。ここでは融合は役にも立たず、コストにもならない。

`Test180ListFuse`: 終端のリストの有無を含む9つの融合の形と、連鎖、リスト、`[]`、filterが空にするリストに対する`foldl`、`foldr`、`length`を扱う。出力は、このディレクティブなしの場合と同じである。
