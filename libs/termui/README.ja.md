# termui

*[English](README.md)*

JavaScriptのInkに着想を得た、Idris2向けのリッチなターミナルUIライブラリです。レイアウトEDSLでビューを記述すると、レイアウトエンジンが画面を計算し、変更された差分セルのみを端末に書き出します。プレーンなANSI出力（notcurses不使用）で動作し、バックエンドは`rc2`、ランタイムには`rc2base`および`control-async`を使用します。

```idris
view : Node ()
view =
  box [border Rounded, padding 1, gap 1]
    [ styled (withAttr Bold plain) "termui"
    , row [justify JBetween] [ text "left", text "right" ]
    ]

main : IO ()
main = do
  frame <- render view 40 6
  frameLines frame >>= traverse_ putStrLn
```

現在の状況: 純粋な計算部分（スタイル、文字幅、レイアウト、描画、フレーム差分計算）、端末ランタイム（rawモード、キーおよびマウス入力、画面リサイズ、タイマー、シグナル処理）、ランタイム管理フォーカスを備えたElmスタイルのプログラムモデルが実装されています。ウィジェット（テキスト入力欄、複数行エディタ、リスト、スクロールビュー、スピナー、プログレスバー、表）、スタイル付きテキスト（pretty-printerの`Doc`を入力元にできます）、テーマ設定可能でブロックの折りたたみに対応したMarkdownビューア、独自のスタイルを持つラベル、単一セルの直接描画が可能なキャンバスが用意されています。

デモ:
- [`examples/Demo.idr`](examples/Demo.idr)
- [`examples/Editor.idr`](examples/Editor.idr)
- [`examples/Chat.idr`](examples/Chat.idr)（チャットログ）
- [`examples/LlmChat.idr`](examples/LlmChat.idr)（応答をストリーミング受信し、ブロック折りたたみ可能なMarkdownとして表示するLLMチャット。HTTPクライアントのために`web`パッケージ（`-p web`）が必要です）

入門ツアーは[`doc/ja/00_getting.md`](doc/ja/00_getting.md)（[英語版](doc/00_getting.md)）、設計リファレンスは[`doc/ja/design.md`](doc/ja/design.md)（[英語版](doc/design.md)）を参照してください。

## ビルドとテスト

```sh
source ../../env.sh
tests/verify.sh      # 型検査、install/ へのインストール、rc2によるテスト実行
```
