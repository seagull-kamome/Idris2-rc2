# コンストラクタ再利用がモナド的bind継続をまたいで届かない件(調査したが見送り)

(原文: `doc/reuse-monadic-bind-gap.md`。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.Reuse`(`rc2/doc/reuse-analysis.md`参照)が、実際の
ベンチマーク支配的なコード片に対してなぜ発火しないのか、そして最初は
有望に見えた修正がなぜここには適用できなかったのかについての調査
記録。本調査の結果としてコードは一切変更されていない -- 本書は将来の
セッションがこの検討を再びやり直さずに済むように存在する。

## 動機

`Compiler.RC2.ConAltNative`が出荷された後(`rc2/doc/con-alt-native.md`)、
外部パッケージ`idris2-missing-containers`の`benchmarkHashMap`
ベンチマークを再計測したところ、ほぼ変化が見られなかった(rc2は
`ConAltNative`後にRefCより約36%速く、事前は約31%だった -- おそらく
計測誤差の範囲内)。`benchmarkHashMap`の`write`フェーズだけで、
全体約16.5秒のうち約10秒を占める。そのホットパスは
`Data.Container.Internal.IOHashSet.replaceL2`
(`install/idris2-missing-containers/src/Data/Container/Internal/IOHashSet.idr`、
`runIOHashSet`自身の`where`ブロックの内側)であり、自己再帰的な
バケットリスト(単なる`List t`)の走査である:

```idris
replaceL2 : List t -> io (r, Maybe (List t))
replaceL2 [] = do ...
replaceL2 xs@(x::xs') with (decEq k (keyfunc hs x))
  _ | Yes prf = case !(found (x ** prf)) of
    NoOp r => pure (r, Nothing)
    Remove r => pure (r, Just xs')
    InsertOrReplace r v => pure (r, Just (v::xs'))
  _ | No _ = do
      (r, Just zs) <- replaceL2 xs'
        | r@(_, Nothing) => pure r
      pure (r, Just (x::zs))
```

どちらの枝も`x::xs'`をdestructureし、同じ形の`::`セルを再構築
している(`v::xs'`はheadを差し替え、`x::zs`はheadを保持してtailを
再構築)-- 教科書通りのコンストラクタin-place再利用の対象である。
実パッケージビルド向けの生成Cを見ても、どちらの再構築の近くにも
`reuse_`接頭辞の変数は一切見当たらなかった: バケットリストの各
ステップは`idris2rc2_newConstructor`経由で全く新しいconsセルを
確保し、元のセルは無条件に解放されている。本書はその理由の調査で
ある。

## 第一仮説: `with`ブロックが別関数へ持ち上げられる(記述通りには反証された)

Idris2の`with`は、rc2が`Lifted` IRを目にするよりずっと前に、別の
トップレベル定義(補助的な「with-block」関数)へ脱糖される。第一
仮説は、この呼び出し境界こそが`Reuse`を妨げているというものだった。

最小の再現コードでこの*半分*が確認された: 同じ形の2つのバージョン、
片方は`with`、もう片方は通常の`case`を使い、どちらも
`idris2-rc2 --cg rc2`でコンパイルした:

```idris
-- with-blockバージョン: 生成されたCのどこにもreuse_変数が無い。
replaceL2 : Nat -> String -> List KV -> List KV
replaceL2 k v [] = [MkKV k v]
replaceL2 k v (x::xs) with (decEq k (key x))
  replaceL2 k v (x::xs) | Yes _ = MkKV k v :: xs
  replaceL2 k v (x::xs) | No _ = x :: replaceL2 k v xs

-- 通常のcaseバージョン: reuse_var_2が両方の枝で綺麗に発火する。
replaceL2 : Nat -> String -> List KV -> List KV
replaceL2 k v [] = [MkKV k v]
replaceL2 k v (x::xs) =
  case decEq k (key x) of
       Yes _ => MkKV k v :: xs
       No _ => x :: replaceL2 k v xs
```

これは綺麗な修正法に見えた: `replaceL2`を`with`ではなく`case`を
使うよう書き換える。この書き換えを実際のライブラリ
(`install/idris2-missing-containers`、計測目的のみで一時的に適用 --
その後`git checkout --`で取り消し、コミットはしていない)に適用し、
同一条件下で`bench.sh --missing-containers`を再計測したところ、
**有意な差は見られなかった**(`with`版14.62秒 対
`case`版14.43秒、どちらも新規に再計測 -- `ConAltNative`計測セッション
由来の16.53秒という数値は、単にマシンの状態のノイズが大きかった
だけで、比較対象として信頼できる基準値ではなかった)。書き換え後の
ライブラリの生成Cを検査して理由が判明した: 再構築サイトでは今も
`idris2rc2_newConstructor`が無条件に呼ばれている -- **こちらにも
`reuse_`変数は一切現れない。**

つまり`with`対`case`は実際の変数ではなかった。実際の関数
(`runIOHashSet`、およびその`where`ブロック内の`replaceL2`)は
`HasIO io =>`多相であり、`!`バング記法(`case !(found (x ** prf))
of ...`)を使っている -- そしてこれは外側のディスパッチが`with`で
書かれていようと`case`で書かれていようと変わらない事実である。
次節の通り、これが実際に重要な点である。

## 根本原因、`--directive dumprcexpr`経由で確認済み

生成Cからの逆算には本物の曖昧さが残っていた(下記「余談: 再利用は
発火しているが、間違ったセルに対してである」参照)ので、実際の
機構はRCExp IR(`idris2-rc2 --cg rc2 --directive dumprcexpr ...`、
`.c`出力の隣に`.rcexpr`ファイルを生成する -- `rc2/doc/reading-the-ir.md`
参照)から直接確認した。実際の形に合わせた再現コード
(`HasIO io`多相、副作用のあるコールバックに対するバング記法):

```idris
replaceL2 : HasIO io => Nat -> String -> (Nat -> io Bool) -> List KV -> io (List KV)
replaceL2 k v found [] = pure [MkKV k v]
replaceL2 k v found (x::xs') =
  case decEq k (key x) of
       Yes _ => case !(found k) of
                     True => pure (MkKV k v :: xs')
                     False => pure (x :: xs')
       No _ => do
         zs <- replaceL2 k v found xs'
         pure (x :: zs)
```

は以下のようにダンプされる(省略あり、外側の関数の`CONS`枝のみ表示):

```
def Main.replaceL2  (fun args=["v0:Boxed", ..., "v4:Boxed"] ret=Boxed)
  case v4 of                              -- v4 = xs
    _builtin.CONS args=[v16, v17] ->      -- destructure x::xs'
      drop [v4]                           -- unconditional -- no reuseOffer
      ...
      let v30 : Boxed =
        partial Main.{replaceL2:0} missing=1 [v16, v17, v0, v1, v2]
      apply v26 v30
```

`v4`(リストセル)は無条件にdropされており、再利用に一度もオファー
されていない。`Compiler.RC2.Reuse`の適格性検査
(`rc2/src/Compiler/RC2/Reuse.idr`の`resolveAlt`)は、
`usedConstructorsR`がalt自身の本体のどこかに、マッチする名前の
文字通りの`RCon`を見つけることを要求する(`RCExp.idr:436-451`) --
そして`usedConstructorsR`は、明示的な設計により、あらゆる呼び出しの
形(`RApp`、`RAppName`、`RUnderApp`)について`empty`を返す
(`Reuse.idr`自身のモジュール注記: 「呼び出しはここでは常に行き止まり
である -- これは純粋にローカルな、手続き内解析であり、呼び出し先が
何をしようと不可視である」)。実際の再構築は`Main.{replaceL2:0}`の
内側で起きている -- この検査からは不可視な、*別個の*ラムダリフト
された定義である。そして決定的に、そこに到達する呼び出しは
`partial ... missing=1`である: **本物の部分適用**であり、完全に
飽和した呼び出しではない -- なぜなら`case !(found k) of ...`は
`>>=`を経由して脱糖され、そのシグネチャ(`io a -> (a -> io b) -> io
b`)は継続をファーストクラスのクロージャ値として構築することを
要求するからである。`io`はここでは多相な型変数のままであり
(具体的な`IO`へ単相化されることはない)、rc2にはその継続がちょうど
1回だけ呼び出されるという静的な保証が一切ない -- 構文的に行儀の悪い
`Monad`/`HasIO`インスタンスであれば、それを0回または複数回呼び出す
可能性もあり、コンパイラはそれら全てについて正しく動作しなければ
ならない。

## ユーザーが提案した修正、そしてなぜそれがこのケースに届かないか

自然な次の案: `Reuse`を手続き間解析に拡張する(ずっと大きな作業)
代わりに、呼び出しサイトがちょうど1つで*かつ*完全に飽和した直接
呼び出し経由で呼ばれている(部分適用されたクロージャとして捕捉
されることは決してない -- これはより深いエフェクト解析なしには
「ちょうど1回呼ばれる」に限定できないため)、任意のリフトされた
定義を、`Reuse`が実行される*前に*インライン化する。そうすれば
`Reuse`は複数の関数本体ではなく1つの合成された関数本体を見ること
になる。これは健全であり、`Reuse`自体を手続き間対応にするよりも
かなり単純である。

しかしこれはここでは役に立たない: RCExpダンプは、実際の呼び出しが
`partial Main.{replaceL2:0} missing=1 [...]`であり、完全には飽和して
いないことを示している。「呼び出しサイトがちょうど1つ」という性質
は、これらのリフトされたcase-blockヘルパーについては実際に成り立つ
(経験的にも確認済み: `replaceL2`自身のリフトされたヘルパーそれぞれ
は、実パッケージの生成Cの中にちょうど3回現れる -- プロトタイプ+
定義+呼び出しサイト1つ、これに対して本物の再帰的な名前付き
`replaceL2`自体は4回で、2つの呼び出しを持つ: 初期呼び出し+末尾
呼び出し)が、条件の*完全飽和*の半分の方が、呼び出し回数の曖昧さの
せいではなく、まさにモナド的bind継続のせいで満たされない。

## 余談: 再利用は発火しているが、間違ったセルに対してである

実パッケージの生成Cを最初に読んだ時、再利用がリフトされたヘルパー
の内側で*発火している*ように見えた(`reuse_var_0`/`reuse_var_4`、
`idris2rc2_isUnique`チェック、実在する)。RCExpダンプでこれを追跡
すると、実際に何が再利用されているのかが明らかになった: rc2は
*あらゆる*単一コンストラクタ・2フィールドのboxed値(`List`の
consセルだけでなく、例えば2メソッドのインターフェース辞書レコード
も)を同じ`_builtin.CONS`タグ付きの物理形状で表現しており、
`Reuse`のマッチングはその形状/名前によるものであって、元のソース
レベルの型のアイデンティティによるものではない。リフトされた
ヘルパー内では、consセルと構造的に同一な形を持つ、かつその1つの
関数に完全にローカルなインターフェース辞書の値が、自身の正当な
ローカル再利用オファーを得ており -- これがたまたま新しい
`x::zs`/`v::xs'`セルの構築で消費されている。これは*本当に*1回の
確保を節約しているが、本調査が追っていたものではない: *元の*
リストセル(上記の`v4`)は、このヘルパーが一度も実行される前に、
既に1段上で無条件にdropされている。そのため元のセルについては
依然として無駄な確保+解放のペアが残っており、辞書形状の再利用は
それを部分的に、偶然に相殺するおまけであって、意図した再利用が
実際に起きている証拠ではない。

## なぜこれ以上追求しなかったか

実際のボトルネックに届くには、以下のいずれかが必要になる:

1. 既知の、信頼できる`Monad`/`HasIO`実装(例えば具体的な
   `Prelude.IO`自身の`>>=`。これは真に自身の継続をちょうど1回、
   末尾位置で呼び出す)を特別扱いし、`Reuse`(または先行するパス)が
   その特定の継続をあたかも直接の末尾呼び出しであるかのように扱える
   ようにする -- 狭く、いくらか原則性に欠ける(コンパイラがたまたま
   その場で使われている特定のbind実装を認識できる場合にのみ役立つ)
   上に、`HasIO io =>`に対して一般的に書かれたライブラリコードに
   ついて、具体的な`io`がコンパイル時にそもそもどれだけ判明する
   かも不明である。
2. モナドの意味論を知る必要のない、より一般的な「このクロージャは
   ちょうど1回、末尾位置で、それが参照される唯一の場所で適用される」
   という解析 -- デュアルABIのエスケープ解析の原案(その履歴は
   `rc2/doc/dual-abi.md`自身参照)が、それを必要としないより単純な
   道を見つける前に検討していたのと同程度の規模の、本物の手続き間/
   エスケープ解析である。

どちらも、この領域でこれまでに出荷されたどんなものよりも実質的に
大きく、それに対して得られる利益は、この特定の形をした1つの
ベンチマークの1つのホット関数に固有のものである。追求せず。将来
似たようなベンチマーク結果に出会うセッションが、この一連の推論を
ゼロから再導出せずに済むよう、ここに記録する。

## 検証方法(これを再び開く場合)

1. `cd rc2 && source ../env.sh`
2. case枝の内側で、スクルティニー自身のコンストラクタを再構築する
   副作用のあるコールバックに対してバング記法を使う、最小限の
   `HasIO io =>`多相な再現コードを書く(上記の再現コード参照)。
3. `nix-shell -p idris2 gcc gmp pkg-config --run 'build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr <file>.idr -o <out>'`
4. `build/exec/<out>.rcexpr`を読む(`rc2/doc/reading-the-ir.md`参照)
   -- destructureされたスクルティニーに`drop [...]`(無条件)がある
   のか`reuseOffer`/`reuse=`があるのかを探し、再構築が
   `partial ... missing=N`呼び出し(bind継続、インライン化は安全
   でない)なのか完全に適用された直接呼び出しなのかを確認する。
5. 実パッケージに対して再計測する場合: `rc2/tests/bench.sh
   --missing-containers --skip-build`を、候補となるソース変更の
   前後どちらも*同一セッション内で*実行する(マシン負荷はセッション
   をまたぐと十分に変動するため、セッションをまたいだ比較は信頼
   できない -- 変更と並べてベースラインも再計測すること。以前の
   文書に記録された数値を信用しないこと)。
