# `RC.idr`のlookupEnv: `IsVar`証明による完全な全域化は不可能(2026-09-17)

(原文: `doc/lookupenv-totality.md`。`TODO.md`から移した日本語の原稿。内容が乖離した場合は原文を正とする。)

`Compiler.RC2.RC`のPhase 1(`normalizeDef`)は`Compiler.LambdaLift`の
`Lifted vars`を歩く際、de Bruijn添字を`Env = List Int`という
`vars`と同じ長さである"べき"平場のリストで追跡しており、`lookupEnv`は
添字が範囲外だと`idris_crash`する安全網を持っていた。`LLocal`自体は
`(0 p : IsVar x idx vars)`という、`idx`が`vars`の正当な添字である
ことを示す証明を既に持っている(`Core.TT.Var`)。当初「この証明を
`normalizeDef`に通せば`lookupEnv`をクラッシュ無しの全域関数にできる」
という設計(「型で保証されていた不変条件を境界で捨てている」という
パターン)を実装しようとした。

**判明した事実**: `LLocal`の`p`フィールドはupstream側で`0`量(消去)
と宣言されている。Idris2は、消去された値のコンストラクタで分岐して
「分岐ごとに異なる実行時データ」を返す関数の定義を一貫して拒否する
(`Can't match on First (Erased argument)`)。これは実装の順序や
書き方の問題ではなく、`Core.TT.Var`の`nameAt`(`nameAt {vars = n ::
_} First = n`のような、まさに欲しかった書き方)が一見コンパイル
できることに惑わされたが、独立した最小再現で検証したところ`nameAt`
が許されるのは、返す値`n`が`vars`という**型レベルの添字そのもの**
から取り出せる場合に限られており、実行時に計算された値(今回なら
`Int`)を返す一般の関数では、引数が`p`ひとつだけの最小構成でも
同じエラーが再現した(`myCount : (0 p : MyIsVar n idx vars) -> Int`
相当)。つまり「消去された妥当性証明を使って、実行時データへの
安全なインデックスアクセスを型検査だけで保証する」という設計は、
`IsVar`がupstream側で消去されている限り、rc2側の書き方をどう工夫
しても届かない。

**実施した代替案**: `Env`を`List Int`から`Data.List.Quantifiers.All`
経由の`Env : List Name -> Type; Env vars = All (const Int) vars`へ
変更し、`env`の"長さ"を`vars`と型レベルで一致させた。これにより
`normalizeDef`/`LLet`/`normalizeConAlt`など、スコープを拡張する
すべての箇所で「`env`を`vars`の拡張と食い違ったまま構築してしまう」
というクラス全体がコンパイルエラーになる(実行時クラッシュではなく)。
ただし`lookupEnv`自体は結局`Nat`(`idx`)による再帰と、最終的な
"届かないはずのcatch-all"クラッシュ節を今まで通り残さざるを得ない
-- 縮小できたのは「`idx`自体が誤っている」場合だけに絞られた
クラッシュ到達可能性であり、完全な全域化ではない。

**今後の検討課題**: `Compiler.LambdaLift`自体(upstream)を変更して
`LLocal`の`p`を非消去にできれば真の全域化が可能になるが、upstream
コンパイラへの改変は本パッケージのスコープ外。あるいは、rc2独自の
Phase 0として`Lifted`を一度、非消去の`Fin`ベースの添字を持つ独自IRへ
変換し直す(証明を作り直すコスト)手もあるが、費用対効果は要検討。
