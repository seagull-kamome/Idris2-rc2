# termui ツアー

**画面の姿を書けば、termuiが描きます。**

```
╭──────────────────────────────────────────╮
│                                          │
│ todo                                   ⠸ │
│                                          │
│ add: ┌──────────────────────────────┐    │
│      │buy tea                       │    │
│      └──────────────────────────────┘    │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │> milk                                │ │
│ │  bread                               │ │
│ │  eggs                                │ │
│ │                                      │ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ Tab: switch   Enter: add   Esc: quit     │
│                                          │
╰──────────────────────────────────────────╯
```

これは実際に動くToDoリストです。入力欄、矢印キーで選べるリスト、タイマーで回るスピナーがあり、Tabでパーツ間を移れて、マウスのクリックも効きます。プログラム全体は約50行で、[第6節](#6-ウィジェットとフォーカス)にあります。

カーソルを動かすことも、エスケープシーケンスを出力することもありません。書くのは、プログラムの状態から箱の木を作る関数だけです。レイアウトの計算、描画、変わったセルだけの書き出しはtermuiが行います。

このツアーは、termuiを初めて使う人向けです。Idris2は知っている前提ですが、ElmアーキテクチャやCSSのflexboxは知らなくてかまいません。termuiが使う範囲に限って説明します。このガイドのプログラムはすべて、コンパイルして実行を確かめています。

| | |
|---|---|
| [1. 動かす](#1-動かす) | 3つのコマンドでデモをビルドして実行する |
| [2. ビューを描く](#2-ビューを描く) | 端末なしで試せるレイアウトの書き方 |
| [3. 最初のプログラム](#3-最初のプログラム) | カウンター。モデル、update、view |
| [4. レイアウト](#4-レイアウト) | 行、列、枠、重ね表示 |
| [5. 色と文字](#5-色と文字) | スタイル、全角文字 |
| [6. ウィジェットとフォーカス](#6-ウィジェットとフォーカス) | 冒頭のToDoリスト |
| [7. コマンドと購読](#7-コマンドと購読) | タイマー、タスク、終了 |
| [8. マウス](#8-マウス) | クリック、ホイール、ダブルクリック |
| [9. つまずきやすい点](#9-つまずきやすい点) | よくある落とし穴 |
| [10. 次に読むもの](#10-次に読むもの) | 例とリファレンス |

## 1. 動かす

termuiはパッケージ`libs/termui`で、`rc2`バックエンド向けです(`contrib`と`rc2base`に依存します)。

```sh
source env.sh                                    # リポジトリのルートで
(cd libs/termui && idris2 --install termui.ipkg)  # パッケージをインストール
cd libs/termui/examples && ./rundemo.sh          # デモを動かす
```

`rundemo.sh`は`Demo.idr`をコンパイルして実行します。Tabを押し、あちこちをクリックし、入力欄に打ち込み、Escで終了してください。

自分のファイルをビルドするには、次のようにします。

```sh
idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -o hello Hello.idr
./build/exec/hello
```

> **`--cg rc2`は必ず付けてください。** 付けないとIdris2は既定のバックエンドに切り替わり、`rc2base`を使うプログラムをビルドできません。コンパイルと実行を一度に行うときは、`-o hello`の代わりに`--exec main`を使います。

端末を占有するプログラムは、端末から起動する必要があります。標準入力か標準出力が端末でないとき、`runProgram`は何も描かずに`Left ENOTTY`を返します。

## 2. ビューを描く

まずは端末なしで試します。`render`は、指定した大きさの画面にビューをレイアウトしてセルを作り、`frameLines`はそれを文字列にします。

```idris
module Main

import TermUI.Frame
import TermUI.Node
import TermUI.Style

main : IO ()
main = do
  frame <- render view 30 8
  frameLines frame >>= traverse_ putStrLn
  where
    view : Node ()
    view =
      box [border Rounded, padding 1, gap 1]
        [ styled (withAttr Bold plain) "Hello, termui"
        , row [justify JBetween] [ text "left", text "right" ]
        ]
```

```
╭────────────────────────────╮
│                            │
│ Hello, termui              │
│                            │
│ left                 right │
│                            │
│                            │
╰────────────────────────────╯
```

- ビューは`Node msg`の木です。葉は`text "..."`と`styled style "..."`です。`box props children`は子を上から下へ積み、`row props children`は子を横に並べます。
- `msg`は、木の中のウィジェットが送れるメッセージの型です。ウィジェットのない木なら何でもよく、ここでは`()`にしています。
- ルートは画面全体を占めます。文字列より枠が広いのはそのためです。ノードは親の端で切り取られるので、画面の行数は十分に取ってください。上の例を5行にすると、枠しか見えません。
- `border Rounded`は`Prop`、つまり`Props -> Props`の関数です。`box`はリストの順に適用するので、後ろのプロパティが前のものを上書きします。

レイアウトを試すには、これがいちばん手早い方法です。ビューを書き換えて、実行し、絵を読みます。

## 3. 最初のプログラム

対話プログラムは、**モデル**と、それを**更新**する方法(update)と、その**ビュー**でできています。これがElmアーキテクチャです。`Program model msg`には4つのフィールドがあります。

| フィールド | 型 | 役割 |
|------------|----|------|
| `init`   | `(model, Cmd msg)` | 開始時の状態と、最初のコマンド |
| `update` | `msg -> model -> (model, Cmd msg)` | メッセージを受けた後の新しい状態 |
| `view`   | `model -> Node msg` | ある状態で画面に出すもの |
| `subs`   | `model -> List (Sub msg)` | プログラムが待つイベント |

ランタイムは、キー入力やタイマーなどをメッセージに変えて、1つずつ`update`に渡します。そのたびに新しいモデルで`view`を呼び、前の画面との差分を描きます。画面を変える方法はこれだけです。

カウンターを作ります。

```
╭──────────────────────────────╮
│                              │
│ count = 2                    │
│ + / -: change   q: quit      │
│                              │
╰──────────────────────────────╯
```

```idris
module Main

import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style

%default covering

data AppMsg = Inc | Dec | Quit'

appUpdate : AppMsg -> Int -> (Int, Cmd AppMsg)
appUpdate Inc n = (n + 1, NoCmd)
appUpdate Dec n = (n - 1, NoCmd)
appUpdate Quit' n = (n, Quit)

appView : Int -> Node AppMsg
appView n =
  box [border Rounded, padding 1]
    [ styled (withAttr Bold plain) ("count = " ++ show n)
    , styled (withAttr Dim plain) "+ / -: change   q: quit"
    ]

appSubs : Int -> List (Sub AppMsg)
appSubs _ = [ OnInput key ]
  where
    key : Input -> Maybe AppMsg
    key (Press (KChar '+') _) = Just Inc
    key (Press (KChar '-') _) = Just Dec
    key (Press (KChar 'q') _) = Just Quit'
    key (Press (KChar 'c') mods) = if mods.ctrl then Just Quit' else Nothing
    key _ = Nothing

main : IO ()
main = do
  r <- runProgram (MkProgram (0, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("needs a terminal: " ++ show e)
    Right n => putStrLn ("final count: " ++ show n)
```

第1節の手順でビルドし、`+`と`-`を押してから`q`で終了してください。

仕組みは次のとおりです。

- **`OnInput f`**は購読の1つです。フォーカスされたウィジェットが取らなかったキー入力(と貼り付け)が、すべて`f`に渡されます。`Just msg`なら`update`にメッセージが届き、`Nothing`ならそのキーは無視されます。キーは`Press key mods`で、`key`は`KChar c`、`KEnter`、`KEscape`、`KUp`、`KF 1`などです。`mods`には`shift`、`ctrl`、`alt`のフラグがあります。
- **Ctrl-Cは、ただのキーです。** 端末はrawモードなので、プログラムは中断されません。Ctrl-Cは`ctrl`付きの`Press (KChar 'c')`として届き、その意味はプログラムが決めます。無視すると、利用者は抜けられなくなります。
- **`Quit`**はコマンドです。`update`がモデルと並べて返すと、ランタイムが止まります。`runProgram`は端末を元に戻してから`Right finalModel`を返すので、通常の画面に結果を印字できます。
- **`Left`**は、第1節の「端末でない」場合です。

> **名前の付け方。** 関数は`update`、`view`、`subs`ではなく、`appUpdate`、`appView`、`appSubs`と名付けてください。これらは`Program`のフィールド名で、`import TermUI.Program`すると見えるようになります。トップレベルに`update`を書くと、型エラーが分かりにくくなります。同じ理由で、ウィジェットを取り込むときはモデルとメッセージの型を`AppModel`、`AppMsg`と名付けてください。どのウィジェットのモジュールも、自分の`Model`と`Msg`を持っています。

## 4. レイアウト

termuiは、CSSのflexboxの小さな部分集合を実装しています。箱は子を**主軸**に沿って並べます。`box`(別名`column`)は下向き、`row`は横向きです。大きさの単位はすべて端末のセルです。

```idris
box [border Single, padding 1, gap 1]   -- 枠の中の縦並び
  [ text "title"
  , row [gap 2] [ text "a", text "b" ]  -- 横に並べて、間を2セル空ける
  , spacer                              -- 余った空間をすべて取る
  , text "footer"
  ]
```

最初に使うプロパティです。

| プロパティ | 効果 |
|------------|------|
| `border b` | `Single`、`Rounded`、`DoubleLine`、`Heavy`、`Ascii`、`NoBorder` |
| `borderColor c` | 枠の色 |
| `padding n`、`paddingXY x y` | 枠の内側の余白 |
| `margin n`、`marginXY x y` | 箱の外側の余白 |
| `gap n` | 子の間の間隔 |
| `width d`、`height d` | `Auto`(既定)、`Cells n`、親に対する割合の`Percent p` |
| `minWidth`、`maxWidth`、`minHeight`、`maxHeight` | 大きさの下限と上限 |
| `grow n`、`shrink n` | 余った空間を取る割合、足りないときに縮む割合 |
| `justify j` | 主軸方向の配置: `JStart`、`JCenter`、`JEnd`、`JBetween`、`JAround` |
| `align a` | 直角方向の配置: `Start`、`Center`、`End`、`Stretch`(既定) |
| `style s` | 箱のスタイル。背景は箱を塗りつぶし、残りは中身に継承される |
| `wrapChildren` | 子が収まらない行は、次の行へ折り返す |
| `absolute`、`top`、`left`、`right`、`bottom` | 箱を通常の流れから外して、位置を指定する |

経験則です。

- 箱の幅と高さには、枠とパディングが含まれます。マージンは外側です。
- 子は、まず自然な大きさを取ります。余った空間は`grow`で分けます。`grow 1`の子が1つなら、その子が全部取ります。`grow 1`と`grow 2`の子なら、1対2に分けます。足りない分は`shrink`で取り戻します。
- 主軸と直角の方向には、子が既定で引き伸ばされます。縦並びの中の箱は、`width`か`align`を指定しない限り、親の幅いっぱいになります。
- 箱より幅の広い文字列は、単語の区切りで折り返されます。折り返さずに切るには`truncated style "..."`、任意の文字で折り返すには`charWrapped`を使います。

### 重ね表示

`absolute`の箱は流れから外れ、兄弟を動かさず、兄弟の上に描かれます。画面全体を覆って、ダイアログを中央に置くには、次のように書きます。

```idris
box [absolute, top 0, left 0, right 0, bottom 0, align Center, justify JCenter]
  [ box [border DoubleLine, padding 1] [ text "Are you sure?" ] ]
```

```
┌────────────────────────────────┐
│                                │
│ main p╔═══════════════╗        │
│       ║               ║        │
│       ║ Are you sure? ║        │
│       ║               ║        │
│       ╚═══════════════╝        │
│                                │
└────────────────────────────────┘
```

上に描かれるように、子のリストの最後に置いてください。ビューはモデルの単なる関数なので、ダイアログの出し入れは`if`で書けます。

```idris
box [] ([ mainPart ] ++ (if m.help then [ helpDialog ] else []))
```

大きさの決め方まで含めた完全な規則は、[`design.md`](../design.md)の「Layout semantics」にあります(英語)。

## 5. 色と文字

`styled style "text"`は、`Style`を付けた文字列を描きます。改行すると次の行になります。`Style`は、すべてを継承する`plain`から始めて、足していきます。

```idris
withAttr Bold plain                          -- 太字
fgColor red (withAttr Underline plain)       -- 赤の下線付き
bgColor (RGB 0 40 80) plain                  -- 24ビット色の背景
```

- **属性:** `Bold`、`Dim`、`Italic`、`Underline`、`Inverse`、`Strike`。
- **色:** ANSIの8色の名前(`black`、`red`、`green`、`yellow`、`blue`、`magenta`、`cyan`、`white`)、明るい色の`bright red`など、256色パレットの`Indexed n`、`RGB r g b`。
- **継承:** 箱に`style s`で付けたスタイルは、中のすべてに流れます。色が`Inherit`のままなら親の色、`Default`は端末自身の色です。`withoutAttr`は、親が付けている属性を打ち消します。

**全角文字はそのまま使えます。** 幅は`wcwidth`に従います。日本語などの東アジアの全角文字や絵文字は2セルを取り、レイアウトもカーソルの移動もセル単位で数えます。結合文字は、同じ`text`の中で直前の文字と一緒に置く必要があります。

## 6. ウィジェットとフォーカス

キーは、まず`OnInput`ではなく、**フォーカスされた**ノードに届きます。フォーカスを受けられるノードが`focusable`で、入力欄やリストなどのウィジェットは自分を`focusable`で包んでいます。ランタイムは`focusable`を木の順に番号付けして、そのうち1つにフォーカスを置きます。TabとShift-Tabでフォーカスが移り、マウスのクリックでも移ります。フォーカスされたウィジェットが使わないキー(Tab、Escape、Ctrl-Cなど)は、`OnInput`の購読に回ります。

ウィジェットは、それ自体が小さなElmプログラムで、`Model`、`Msg`、`update`、ビューを持ちます。親はウィジェットのモデルを持ち、ウィジェットのメッセージを自分のメッセージで包み、ウィジェットの`update`に渡し返します。

ページの冒頭にあるToDoリストが、次のプログラムです。項目を足す入力欄とリストがあり、保存のふりをする間はスピナーが回ります。

```idris
module Main

import Data.List
import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Widget.Display
import TermUI.Widget.Select as S
import TermUI.Widget.TextInput as T

%default covering

record AppModel where
  constructor MkModel
  input : T.Model
  items : S.Model
  tick : Nat
  busy : Bool

data AppMsg = Edit T.Msg | Pick S.Msg | Add | Tick | Saved | Quit'

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate (Pick p) m = ({ items $= S.update p } m, NoCmd)
appUpdate Add m =
  case T.value m.input of
    "" => (m, NoCmd)
    s => ({ input := T.empty 30, busy := True, items $= S.setItems (m.items.items ++ [s]) } m,
          After 800 Saved)
appUpdate Tick m = ({ tick $= S } m, NoCmd)
appUpdate Saved m = ({ busy := False } m, NoCmd)
appUpdate Quit' m = (m, Quit)

appView : AppModel -> Node AppMsg
appView m =
  box [border Rounded, padding 1, gap 1]
    [ row [justify JBetween]
        [ styled (withAttr Bold plain) "todo"
        , if m.busy then spinner m.tick else text "saved"
        ]
    , row [gap 1] [ text "add:", box [border Single] [T.field Edit (Just Add) m.input] ]
    , box [border Single, height (Cells 7)] [S.list Pick m.items]
    , styled (withAttr Dim plain) "Tab: switch   Enter: add   Esc: quit"
    ]

appSubs : AppModel -> List (Sub AppMsg)
appSubs m =
  [ OnInput (\i => case i of
                     Press KEscape _ => Just Quit'
                     _ => Nothing)
  ] ++ (if m.busy then [Every "spin" 100 Tick] else [])

main : IO ()
main = do
  let m0 = MkModel (T.empty 30) (S.fromList 5 []) 0 False
  r <- runProgram (MkProgram (m0, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("needs a terminal: " ++ show e)
    Right m => putStrLn ("bye, " ++ show (length m.items.items) ++ " items")
```

文字を入力してEnterを押してください。Tabで入力欄とリストの間を移れ、リストでは上下キーで項目を選べます。

この例から取り出せることです。

- `import ... as T`で、ウィジェットごとの`Model`、`Msg`、`update`を区別します。
- `T.field Edit (Just Add) m.input`が入力欄のビューです。`Edit`は欄のメッセージを自分のメッセージに包みます。`Just Add`は欄でEnterを押したときに送るメッセージで、何もしないなら`Nothing`を渡します。欄はフォーカスを持っている間Enterを自分で取るので、`OnInput`には届きません。
- `appUpdate`では、ウィジェットのメッセージをそのウィジェットの`update`に渡します。`{ input $= T.update e } m`は、`m`の`input`フィールドに関数を適用します。
- **状態が、画面と、聞くイベントを決めます。** `spinner`も`Every`も`busy`の間だけ現れます。タイマーを開始・停止するコードはありません。ランタイムが、更新のたびに購読のリストを比べます。

### ウィジェットの棚

| モジュール | ウィジェット | 内容 |
|------------|--------------|------|
| `TermUI.Widget.TextInput` | `field` | 選択、取り消し、専用クリップボードを持つ1行の入力欄 |
| `TermUI.Widget.TextArea` | `area` | 複数行エディタ。ソフト折り返しも選べる |
| `TermUI.Widget.Select` | `list` | 1つを選べるスクロール付きのリスト |
| `TermUI.Widget.Scroll` | `viewer` | 読み取り専用のスクロール付きテキスト |
| `TermUI.Widget.Table` | `table` | 見出しが固定され、本体がスクロールする表 |
| `TermUI.Widget.Checkbox` | `checkbox` | `[x] label`。真偽値は親が持ち、メッセージを受けて反転する |
| `TermUI.Widget.Button` | `button` | `Framed`(枠あり)、`Flat`(枠なし)、`Link`(下線付きのハイパーリンク風) |
| `TermUI.Widget.MenuBar` | `menuBar` | タイトルの並ぶバーとドロップダウンメニュー。ルートの箱の最後に置き、最初の1行は空けておく |
| `TermUI.Widget.KeyGuide` | `keyGuide` | `F1 Help  F2 Save`のような1行。ヒントをクリックするとそのメッセージを送る。Fキーは`keyInput`で同じメッセージに変える |
| `TermUI.Widget.TabStrip` | `tabStrip`、`tabbed` | 1つが選ばれたタブ。`tabbed`は選ばれたタブの内容を入れる枠付きのペインも足す |
| `TermUI.Widget.Splitter` | `splitter` | 矢印キーやマウスのドラッグで境界を動かせる、2つのペイン |
| `TermUI.Widget.Display` | `spinner`、`progressBar`、`table` | フォーカスのない表示部品。`spinner`は自分で数えるtickで進む |

リスト、ビューア、表、エディタの高さは、モデルの一部です(`S.fromList 5 items`は5行を見せます)。そのため、ウィジェットとそのビューの高さはいつも一致します。各ウィジェットのキー割り当ては、[`design.md`](../design.md)の「Widgets」にあります。

同じ種類の`focusable`が実行中に出たり消えたりするときは、`keyed "name" node`で名前を付けてください。フォーカスは木の中の位置ではなく、その名前のウィジェットに付いたままになります。

## 7. コマンドと購読

`update`は、メッセージごとに新しいモデルと**`Cmd`**(ランタイムにしてほしいこと)を返します。`subs`は、どのイベントを聞くかを返します。

### コマンド

| コマンド | 意味 |
|----------|------|
| `NoCmd` | 何もしない |
| `Batch [c1, c2]` | 複数のコマンドを順に実行する |
| `Quit` | 止める。待っていたキューは捨てられる |
| `Emit msg` | すでに待っているものの後ろに、`update`へのメッセージを入れる |
| `After ms msg` | `ms`ミリ秒後にメッセージを送る |
| `Perform io` | `io : IO msg`をすぐ実行して、結果を送る。戻るまで画面は止まるので、短い処理に使う |
| `RunTask task` | `Control.Task`のタスクをプログラムと並行して走らせ、終わりのメッセージを送る。待っている間も画面は生きている |
| `RunTaskAs name task`、`CancelTask name` | 名前付きのタスク。同じ名前の新しいタスクが古いものを置き換える |
| `SetClipboard text` | デスクトップのクリップボードに文字列を入れる(OSC 52。無視する端末もある) |
| `Suspend` | シェルのCtrl-Zのように止まり、戻ったときに画面を描き直す |

時間のかかる処理(ネットワーク要求や大きなファイル)には`RunTask`を使います。`Control.Task`の`blocking`は、ブロックするかもしれない処理をワーカースレッドで実行し、結果をメッセージとして戻します。詳しくは`libs/rc2base/doc/task.md`を見てください。

### 購読

| 購読 | 意味 |
|------|------|
| `OnInput f` | フォーカスされたウィジェットが取らなかったキー入力と貼り付け |
| `OnMouse f` | すべてのマウスイベント。マウス報告を有効にする |
| `MouseFocus` | クリックでフォーカスが移り、ホイールはポインタの下のウィジェットに届く。マウス報告を有効にする |
| `OnResize f` | 画面の大きさ。開始時に1回と、変わるたびに |
| `Every key ms msg` | `ms`ミリ秒ごとに`msg`を送る。`key`はタイマーの名前 |
| `OnTerminate msg` | SIGINT、SIGTERM、SIGHUPをメッセージとして受ける。なければプログラムは終了する |

`subs`は、更新のたびにもう一度評価されます。`Every`がリストに現れるとタイマーが動き出し、リストから消えると止まります。

**順序。** メッセージは、送られた順に1つずつ処理されます。Aの処理が`Emit B`と`Emit C`を返すと、すでに待っているメッセージの後にBとCが続き、Bが出したメッセージはCの後ろに回ります。

**部品への分割。** プログラムを分けるには、部品ごとに`Model`、`Msg`、`update`、`view`、`subs`を持たせます。親は`mapNode`、`mapCmd`、`mapSub`で部品を埋め込み、部品のメッセージを親のメッセージで包みます。2つの部品が同じタイマーのキーを使うときは、部品の購読を`scopeSub "name"`で包みます。ウィジェットはこの方法で作られています。

## 8. マウス

マウス報告は、既定では無効です。有効にすると、端末自身の文字選択が使えなくなるためです。多くのプログラムが欲しい動きは、`subs`に**`MouseFocus`**を足すと得られます。クリックでポインタの下のウィジェットにフォーカスが移り、ホイールでスクロールし、入力欄やエディタをクリックするとカーソルがそこに移ります。ダブルクリックで単語、トリプルクリックで行を選択します。

生のイベントが欲しいときは`OnMouse`を使います。`MouseEvent`には、`button`、`action`、左上を0とする`column`と`row`、修飾キー、クリック回数があります。マウスイベントが`OnInput`に届くことはありません。

## 9. つまずきやすい点

- **Ctrl-Cはキーです。** 第3節を見てください。必ず処理してください。`kill`も同じように扱えるよう、`OnTerminate`も検討してください。
- **`main`のループは書きません。実行中に`putStrLn`もしません。** 標準出力へ書くと、画面が壊れます。伝えたいことはモデルに入れてビューに出すか、`runProgram`が戻った後に印字します。
- **`update`や`view`の中でブロックしないでください。** どちらもすぐに戻る必要があります。遅延には`After`、重い処理には`RunTask`を使います。
- **カーソルは描いた場所にありません。** 実際の端末カーソルは、隠れた位置に置かれたままです。ただしフォーカスされた入力欄では、入力メソッド(IME)が変換候補を横に出せるよう、カーソルがその位置に置かれます。ほかの場所に置くには、箱に`cursorHere`を付けます。
- **高さを保ちたい箱には、高さを決めてください。** `Auto`の高さは中身に合わせて縮みます。リストやビューアの高さはモデルが持ちますが、それを包む箱には`height`か`grow`が要ります。
- **`Every`のキーは少数の集合にしてください。** ランタイムは見たキーをすべて覚えています。増え続けるカウンターからキーを作ると、メモリを使い続けます。
- **`rc2`でコンパイルし、UTF-8のロケールで実行してください。** 全角文字を正しく扱うために、rc2のプログラムはUTF-8のロケールを必要とします。
- **強制終了すると、端末がrawモードのまま残ります。** `kill -9`やクラッシュでは、端末を復元できません。`reset`と打つと(入力が見えなくても)戻ります。

## 10. 次に読むもの

- [`examples/Demo.idr`](../../examples/Demo.idr): 入力欄、リスト、エディタ、スピナー、進捗バー、ダイアログを組み合わせた例です。`examples/rundemo.sh`で動かせます。
- [`examples/Editor.idr`](../../examples/Editor.idr): ヘルプビューア、クリップボード、Suspendを備えた小さなテキストエディタです。
- [`design.md`](../design.md)(英語): リファレンスです。レイアウトの規則、入力パーサー、差分の書き出し、各ウィジェットのキー割り当て、フォーカス・マウス・シグナルの扱いが載っています。
- `libs/rc2base/doc/task.md`: `RunTask`に使う`Control.Task`です。
- `tests/`: 各ディレクトリが1つの機能を動かして出力を確かめる小さなプログラムです。`render`、`layout`、`parseInput`といった純粋な関数を単独で使う例にもなります。
