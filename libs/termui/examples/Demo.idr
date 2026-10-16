||| A small demo of termui: a text field adds items to a list, the list can
||| be walked with the arrow keys, a progress bar follows the number of items
||| and a spinner runs on a timer. Tab moves between the field and the list,
||| Enter in the field adds an item, Ctrl-C or Esc quits.
|||
||| Build: idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -o demo Demo.idr
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
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

data AppMsg = Edit T.Msg | Pick S.Msg | Add | Spin | Quit'

appView : AppModel -> Node AppMsg
appView m =
  box [border Rounded, padding 1, gap 1]
    [ row [justify JBetween]
        [ styled (withAttr Bold plain) "termui demo"
        , spinner m.tick
        ]
    , row [gap 1] [ text "add:", box [border Single] [T.field 30 Edit m.input] ]
    , box [border Single, height (Cells 7)] [S.list 5 Pick m.items]
    , row [gap 1] [ progressBar 20 (length m.items.items * 10), text (show (length m.items.items) ++ " items") ]
    , styled (withAttr Dim plain) "Tab: switch   Enter: add   Esc: quit"
    ]

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate (Pick p) m = ({ items $= S.update 5 p } m, NoCmd)
appUpdate Add m =
  let text = T.value m.input in
  if text == "" then (m, NoCmd)
  else ({ input := T.empty, items := S.fromList (m.items.items ++ [text]) } m, NoCmd)
appUpdate Spin m = ({ tick $= S } m, NoCmd)
appUpdate Quit' m = (m, Quit)

appSubs : AppModel -> List (Sub AppMsg)
appSubs _ =
  [ Every 1 100 Spin
  , OnInput (\i => case i of
                     Press KEnter _ => Just Add
                     Press KEscape _ => Just Quit'
                     Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
                     _ => Nothing)
  ]

main : IO ()
main = do
  r <- runProgram (MkProgram (MkModel T.empty (S.fromList []) 0, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("termui demo needs a terminal: " ++ show e)
    Right m => putStrLn ("bye, " ++ show (length m.items.items) ++ " items")
