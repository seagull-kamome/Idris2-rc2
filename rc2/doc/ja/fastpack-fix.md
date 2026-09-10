# リークしない `fastPack`/`fastConcat`: Emit 時の横取り(修正済み)

(原文: `doc/fastpack-fix.md`。内容が乖離した場合は原文を正とする。)

`KNOWN-BUGS.md` の "Pre-existing `valgrind` leaks" セクションに記録
された `fastPack`/`fastConcat` リークの修正についての解説。最初の
修正試行(`Prelude.Fix.RC2` + `%transform`)がなぜ不十分だったか、
それを置き換えた実際の Emit 時リダイレクト、そして修正をプロジェクト
全体で無条件にする過程で見つかった 2 つ目の無関係なバグ(空文字列
の SIGSEGV)を含む。この解説には保留中のコードはない -- ここに
記述されているものはすべて実装・検証済み(フル `rc2/tests/verify.sh`:
82 passed, 0 known, 0 failed; `libs/rc2base/tests/verify.sh`: 全 PASS)。

## 元のリーク

`fastPack : List Char -> String` と
`fastConcat : List String -> String` は
`%foreign "RefC:fastPack"`/`"RefC:fastConcat"` として `CFString`
戻り値型で宣言されているので、`Compiler.RC2.Emit` の汎用 FFI ラッパ
コード生成(他のすべての `%foreign` 宣言が通る経路)は、C 実装が
返す `char *` を `idris2rc2_mkString`(`rc2/support/rc2/memory.c`)
経由で新しい `IDRIS2RC2_String` にコピーして包み -- そして元の
ポインタを決して解放しない。

これは一般的なケースでは*正しい*プロトコルである: 実在する外部
ライブラリ自身の `char *` 戻り値(例えば `curl_easy_strerror`)は
呼び出し側が解放してはならない。ライブラリが所有しているからである。
それが `fastPack`/`fastConcat` に限っては誤りになる: どちらも、
一度コピーされたら破棄されるためだけに作られた、このプロジェクト
自身が所有するバッファを `malloc` する
(`rc2/support/rc2/idris2rc2_strings.c` の `fastPack`/`fastConcat`)。
汎用ラッパは FFI シグネチャだけからその区別を知る術がない --
`CFString` を返す foreign 関数は、下のバッファが借用か所有かに
かかわらず同一に見える。

## 最初の試行: `Prelude.Fix.RC2` + `%transform`(不十分)

最初の修正は、リークしない置換 `idris2rc2_fastPackFixed`/
`idris2rc2_fastConcatFixed`(今も `idris2rc2_strings.c` にある)を
追加した。それぞれ新しい `IDRIS2RC2_String` に直接構築し、既に
完全形の `IDRIS2RC2_Value *` を返す -- コピーしてリークする対象の
中間 `char *` がない。これらは、`fastPack`/`fastConcat` への呼び出し
を修正版の呼び出しに書き換えるために上流 Idris2 自身の `%transform`
機構を使う `libs/rc2base/src/Prelude/Fix/RC2.idr` モジュール経由で
接続されていた。

これは動作したが、そのモジュールを明示的に `import` した
プログラムに対してのみだった。アーキテクチャ上の理由は根本的で
あり、モジュールの書き方のバグではない: `%transform` は書き換える
定義自身のエラボレーション/インポートスコープ内でのみ、
エラボレーション時に呼び出し箇所を書き換える。別のパッケージ自身の
別途コンパイルされた `.ttc` に既に焼き込まれた呼び出し箇所に届く
術がない -- 書き換えは呼び出しがエラボレートされる時点で*スコープ内*
になければならず、`network`/`base` はこのプロジェクト自身の
`%transform` ルールがスコープ内になり得るずっと前にエラボレート
(され `.ttc` として出荷)されていた。

これにより、`verify.sh` に `KNOWN_LEAK_BYTES` エントリを持つテストが
2 つ残った。呼び出し側が何を `import` しようとフロントエンド側から
は修正不能だった:

- `Test35NetworkLoopback` -- `network` 自身の
  `Network.Socket.Data.parseIPv4` 経由でリークする。これは内部で
  `fastPack` を呼ぶ。
- `Test37SystemMisc`(旧 `Test40SystemProcess`)-- `base` 自身の
  `System.File.ReadWrite` の `fRead'` 経由でリークする。これは内部
  で `fastConcat` を呼ぶ。

## 実際の修正: Emit 時の横取り

フロントエンドがこれらの呼び出し箇所に届かないので、修正は横取りを
rc2 自身の C 生成時、`Compiler.RC2.Emit` に移す。rc2 のバックエンド
は、各定義がどのパッケージ由来かにかかわらず、コンパイル対象
プログラムの完全な `RCDef` 集合を処理する -- なのでこの段階で行う
検査は、事前コンパイル済みの `network`/`base` コードに既に焼き込まれ
たものを含めて、それらのパッケージの再コンパイルなしに、すべての
呼び出し箇所を見る。

`fastPackFixedReplacement : Name -> Maybe String`(`Emit/Foreign.idr`)
は定義の**完全な名前空間修飾名**にマッチする:

```idris
fastPackFixedReplacement : Name -> Maybe String
fastPackFixedReplacement (NS ns (UN (Basic "fastPack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastPackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastConcat"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastConcatFixed" else Nothing
fastPackFixedReplacement _ = Nothing
```

基底名だけでなく完全な名前空間を検査するのは意図的な防御的選択で
ある: 名前のみのマッチは、たまたま別の名前空間で基底名 "fastPack"
を共有するだけの無関係な将来の関数で誤動作するだろう。

`emitForeignDef` のディスパッチ(`Emit/Foreign.idr`、
`createCFunctions` の `MkRCForeign` ケースから到達)は、通常の
コード生成経路から逸れる前に、正確なシグネチャ形状に対する
**2 つ目の独立した**検査を加える:

```idris
case (fastPackFixedReplacement n, ret, fargs) of
     (Just fixedFnName, CFString, [CFUser _ _]) => emitFastPackFixedWrapper fixedFnName
     _ => emitGenericForeignWrapper
```

`CFString` を返し、単一の `CFUser` 型引数を持つことは、
`List Char -> String`/`List String -> String` 自身の形状に正確に
マッチする -- なので、なんらかの形で `Prelude.Types` にも存在する
仮想的な名前衝突があっても、リダイレクトされるには同一のシグネチャ
形状が必要になる。両方の検査(名前と形状)が成立して初めて
`emitFastPackFixedWrapper` が走る; それ以外はすべて手つかずの
`emitGenericForeignWrapper` に落ちる。

`emitFastPackFixedWrapper`(`Emit/Foreign.idr`)は
`emitGenericForeignWrapper` が生成したであろう**同一の外部 C 名と
宣言シグネチャ**を出力する -- なので既存のあらゆる呼び出し箇所は、
完全に無改変のまま同じシンボルに対してリンクし続ける。異なるのは
ラッパ自身の*本体*だけ: `idris2rc2_fastPackFixed`/
`idris2rc2_fastConcatFixed` を直接呼び、結果を即座に返す。
`packCFType`/`idris2rc2_mkString` を完全に飛ばす(素の `CFUser`
戻り値が既にそれを飛ばすのと同じやり方)。
`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` 自身が既に
完全形で正しく所有された `IDRIS2RC2_Value *` を返すからである。

`Test35NetworkLoopback` の実際の生成 C を検査して確認済み: その
`Prelude_Types_fastPack` ラッパ(`network` 自身の事前コンパイル済み
`parseIPv4` 呼び出し箇所のために出力されたもの -- そのパッケージは
**再コンパイルされていない**)は今 `idris2rc2_fastPackFixed` を
呼び、リークは消えている。

## `Prelude.Fix.RC2` の廃止

`libs/rc2base/src/Prelude/Fix/RC2.idr` は削除された
(`rc2base.ipkg` の `modules` から除去; 不要になったその `import` も
`rc2/tests/Test28Utf8Strings.idr` から除去)。Emit 時の修正は厳密に
より一般的である -- `%transform` モジュールがカバーしたすべての
呼び出し箇所に加えて、届かなかったすべてをカバーする -- ので、
オプトインモジュールを残しておいても冗長なだけである。

## なぜ `deprecated` 属性を除去せず残したか

`idris2rc2_strings.h` は今も `fastPack`/`fastConcat` を
`__attribute__((deprecated(...)))` 付きで宣言し、
`rc2/src/Compiler/RC2/CC.idr` は今も生成 C のコンパイル時に
`-Wno-error=deprecated-declarations` を渡す。どちらも、リダイレクト
によって実際上到達不能とされた今も、掃除するのではなくセーフティ
ネットとして意図的に**残された**。

理由: リダイレクトはコード生成レベルの保証であって型レベルの保証で
はない -- `Emit/Foreign.idr` への将来の変更が
`fastPackFixedReplacement` のマッチを狭める(あるいは他の形で
リダイレクトを壊す)のを、誰もすぐに気づかずに止めるものは何も
ない。もしそれが起きたら、生成コードは `emitGenericForeignWrapper`
に落ち、本物のリークする `fastPack`/`fastConcat` を再び呼び始める
-- 一見正しく見えるが、リークする。`deprecated` 属性を残すことは、
その回帰が `valgrind` 下で偶然また発見される静かなリークではなく、
**ビルド時の警告**として再出現することを意味する(明示的な
`-Wno-error=deprecated-declarations` フラグによってハードエラーに
なることだけが抑制されるので、ビルドをブロックすることは決してない
が、ビルド出力を読む人には見える)。両方の属性メッセージは
(実装セッションによって)、そこに到達することは呼び出し側が
回避すべき何かではなくリダイレクトの rc2 バグを示す、と言うよう
更新された。

## 途中で見つかった 2 つ目のバグ: 空文字列の SIGSEGV

元の計画の一部ではない -- Emit 時のリダイレクトが
`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` をプロジェクト
全体で無条件にした後、検証中に発見された。

**根本原因**: どちらの関数も、`idris2rc2_mkEmptyString(byteLen + 1)`
の後に明示的な `r->str[byteLen] = '\0'` を行っていた
(`byteLen`/`total` は計算された出力長)。空入力のケース
(`byteLen == 0`、例えば `pack []`/`concat []`)では、
`idris2rc2_mkEmptyString(1)` は新しいバッファを一切割り当てない --
共有される不滅の `const` static `idris2rc2_emptyStringValue` を返す。
その場合に `r->str[0]` へ書き込むのは読み取り専用メモリへの書き込み
である。

これは修正が `Prelude.Fix.RC2` 経由のオプトインのみだった間は
見えなかった: 既存のインポータで修正経路を通して `pack []`/
`concat []` を呼ぶものは一つもなかった。Emit 時のリダイレクトが
これらを全プロジェクトで無条件にした途端、`refc-suite` 自身の
`strings` テスト(まさにこれを行う)が SIGSEGV でクラッシュした。

**修正**: 両方の末尾 NUL 書き込みを削除する。
`idris2rc2_mkEmptyString` 自身の malloc 経路は既にバッファ全体を
`memset()` でゼロにするので、終端バイト(コピーループが書き込む
最後のバイトの直後)は明示的な書き込みなしに常に既に正しかった。
これは `idris2rc2_strings.c` の他のすべての `idris2rc2_mkEmptyString`
呼び出し側が既に従っているパターンに一致する
(`idris2rc2_strTail`/`strReverse`/`strCons`/`strAppend`/`strSubstr`
-- いずれも自分の `memcpy` したペイロードを越えたインデックス書き込み
はしない)。

## 検証方法

1. フル `rc2/tests/verify.sh`: 82 passed, 0 known, 0 failed。
2. フル `libs/rc2base/tests/verify.sh`: 全 PASS。
3. `Test35NetworkLoopback`(`parseIPv4` への無改変の事前コンパイル
   済み `network` パッケージ呼び出し箇所)の実際の生成 C を検査し、
   その `Prelude_Types_fastPack` ラッパが `idris2rc2_fastPackFixed`
   を呼ぶことを確認。`network`/`base` の再コンパイルはどこにも不要。
4. `verify.sh` の `KNOWN_LEAK_BYTES` マップは今や本当に空である --
   `Test35NetworkLoopback`/`Test37SystemMisc`(当時
   `Test40SystemProcess`)エントリは除去され、どちらもリークバイト
   0 を確認。(`Test35NetworkLoopback` は完全に無関係な、まだ未解決
   の理由で `NO_REFC_DIFF_TESTS` に残る: `parseIPv4` 自身の生成
   キャスト関数名の大文字小文字不一致という real-RefC のみの
   コンパイルバグ -- この修正とは無関係。)
5. 新しい回帰テスト: `rc2/tests/Test46FastPackUnconditional.idr`
   (+ `.expected`)、オプトイン import ゼロで `pack`/`concat` を
   呼ぶ -- `verify.sh` の `LEAK_SENSITIVE_TESTS` に登録、リークなし
   を確認。そのモジュールコメントは空でないリストで `pack`/`concat`
   を呼ぶことで空文字列ケースも暗黙にカバーする; 空入力の SIGSEGV
   は新しい専用テストではなく `refc-suite` の既存 `strings` テスト
   で捕捉された。そのテストが既にたまたま `pack []`/`concat []` を
   行っていたからである。

## ファイル

- `rc2/src/Compiler/RC2/Emit/Foreign.idr` --
  `fastPackFixedReplacement`、`emitForeignDef` のディスパッチ、
  `emitFastPackFixedWrapper`。
- `rc2/support/rc2/idris2rc2_strings.c` -- `idris2rc2_fastPackFixed`/
  `idris2rc2_fastConcatFixed`(空文字列の末尾 NUL 書き込み除去)。
- `rc2/support/rc2/idris2rc2_strings.h` -- `fastPack`/`fastConcat` に
  残された `deprecated` 属性(そこに到達することを呼び出し側の回避策
  ではなく rc2 バグとして記述するようメッセージ更新)。
- `rc2/src/Compiler/RC2/CC.idr` -- 残された
  `-Wno-error=deprecated-declarations` フラグ。
- `rc2/tests/Test46FastPackUnconditional.idr` -- 新しい回帰テスト。
- `libs/rc2base/src/Prelude/Fix/RC2.idr` -- **もはや存在しない**
  (廃止; `rc2base.ipkg` の `modules` から除去、その import は
  `rc2/tests/Test28Utf8Strings.idr` から除去)。
