||| A tour of termui in three tabs. "List" has a text field that adds items to
||| a list, a multi-line editor, a progress bar and a spinner. "Controls" has
||| check boxes and three kinds of button. "Panes" has splitters whose dividers
||| move with the arrow keys or the mouse. Around them are a menu bar (reach
||| it with Tab, then Down), tabs, and a function-key guide at the bottom.
||| Tab or a click moves the focus, Ctrl-C or Esc quits.
|||
||| Build: idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -o demo Demo.idr
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Widget.Button
import TermUI.Widget.Checkbox
import TermUI.Widget.Display
import TermUI.Widget.KeyGuide
import TermUI.Widget.MenuBar as M
import TermUI.Widget.Select as S
import TermUI.Widget.Splitter as P
import TermUI.Widget.TabStrip as Tab
import TermUI.Widget.TextArea as A
import TermUI.Widget.TextInput as T

%default covering

data AppMsg
  = Edit T.Msg | Pick S.Msg | Note A.Msg | Add | Spin | Help | Quit'
  | FromMenu M.Msg | FromTab Tab.Msg | FromSplit P.Msg | FromSplit2 P.Msg
  | GoTab Nat | ShowSpinner | ShowBar | Clicked String | Clear

record AppModel where
  constructor MkModel
  input : T.Model
  items : S.Model
  notes : A.Model
  tick : Nat
  help : Bool
  menu : M.Model AppMsg
  tabs : Tab.Model
  spinner' : Bool
  bar : Bool
  status : String
  split : P.Model
  split2 : P.Model

-- The function-key guide and the keys it stands for.
hints : List (Hint AppMsg)
hints = [MkHint 1 "Help" Help, MkHint 2 "Add" Add, MkHint 3 "Clear" Clear, MkHint 10 "Quit" Quit']

menus : M.Model AppMsg
menus = M.fromMenus
  [ MkMenu "File" [Item "Clear the list" Clear, Separator, Item "Quit" Quit']
  , MkMenu "View" [Item "List" (GoTab 0), Item "Controls" (GoTab 1), Item "Panes" (GoTab 2)]
  , MkMenu "Help" [Item "About" Help]
  ]

-- A dialog over the whole screen: a box out of the flow that covers its
-- parent and centres its child.
helpDialog : Node AppMsg
helpDialog =
  box [absolute, top 0, left 0, right 0, bottom 0, align Center, justify JCenter]
    [ box [border DoubleLine, padding 1, style (bgColor (Indexed 0) plain)]
        [ styled (withAttr Bold plain) "termui demo"
        , text "Tab / click       move between the parts"
        , text "Enter             add the item / a new line"
        , text "wheel, arrows     scroll the list"
        , text "menu bar          Tab to it, then Down"
        , text "dividers          arrows, or drag with the mouse"
        , text "F1                close this box"
        ] ]

listPage : AppModel -> Node AppMsg
listPage m =
  column [gap 1]
    [ row [justify JBetween]
        [ text "items"
        , if m.spinner' then spinner m.tick else text " "
        ]
    , row [gap 1] [ text "add:", box [border Single] [T.field Edit (Just Add) m.input] ]
    , row [gap 1]
        [ box [border Single, height (Cells 7)] [S.list Pick m.items]
        , box [border Single] [A.area Note m.notes]
        ]
    , if m.bar
         then row [gap 1] [ progressBar 20 (length m.items.items * 10), text (show (length m.items.items) ++ " items") ]
         else text (show (length m.items.items) ++ " items")
    ]

controlsPage : AppModel -> Node AppMsg
controlsPage m =
  column [gap 1]
    [ checkbox "Show the spinner" m.spinner' ShowSpinner
    , checkbox "Show the progress bar" m.bar ShowBar
    , row [gap 2]
        [ button Framed "Framed" (Clicked "the framed button")
        , button Flat "Flat" (Clicked "the flat button")
        , button Link "a link" (Clicked "the link")
        ]
    , text ("last pressed: " ++ (if m.status == "" then "nothing yet" else m.status))
    ]

panesPage : AppModel -> Node AppMsg
panesPage m =
  box [grow 1]
    [ splitter "split" FromSplit m.split
        (box [border Single] [ text "A splitter's first pane.", text "Focus the divider (Tab) and press the arrow keys, or drag it." ])
        (splitter "split2" FromSplit2 m.split2
           (box [border Single] [ text ("The first pane is " ++ show m.split.size ++ " cells wide.") ])
           (box [border Single] [ text ("This one is " ++ show m.split2.size ++ " rows high above.") ]))
    ]

appView : AppModel -> Node AppMsg
appView m =
  box []
    ([ column [grow 1]
         [ box [height (Cells 1)] []
         , tabbed FromTab m.tabs [listPage m, controlsPage m, panesPage m]
         , keyGuide hints
         ]
     ] ++ (if m.help then [helpDialog] else [])
       ++ [menuBar FromMenu m.menu])

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate (Pick p) m = ({ items $= S.update p } m, NoCmd)
appUpdate (Note n) m = ({ notes $= A.update n } m, NoCmd)
appUpdate Add m =
  let entered = T.value m.input in
  if entered == "" then (m, NoCmd)
  else ({ input := T.empty 30, items $= S.setItems (m.items.items ++ [entered]) } m, NoCmd)
appUpdate Clear m = ({ items $= S.setItems [] } m, NoCmd)
appUpdate Spin m = ({ tick $= S } m, NoCmd)
appUpdate Help m = ({ help $= not } m, NoCmd)
appUpdate Quit' m = (m, Quit)
appUpdate (FromMenu e) m =
  let (menu', chosen) = M.update e m.menu in
  ({ menu := menu' } m, maybe NoCmd Emit chosen)
appUpdate (FromTab e) m = ({ tabs $= Tab.update e } m, NoCmd)
appUpdate (FromSplit e) m = ({ split $= P.update e } m, NoCmd)
appUpdate (FromSplit2 e) m = ({ split2 $= P.update e } m, NoCmd)
appUpdate (GoTab n) m = ({ tabs := Tab.MkModel m.tabs.titles n } m, NoCmd)
appUpdate ShowSpinner m = ({ spinner' $= not } m, NoCmd)
appUpdate ShowBar m = ({ bar $= not } m, NoCmd)
appUpdate (Clicked what) m = ({ status := what } m, NoCmd)

appSubs : AppModel -> List (Sub AppMsg)
appSubs m =
  [ MouseFocus
  , OnInput (\i => case keyInput hints i of
                     Just msg => Just msg
                     Nothing => case i of
                                  Press KEscape _ => Just Quit'
                                  Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
                                  _ => Nothing)
  ]
  ++ (if m.spinner' then [Every "spin" 100 Spin] else [])
  ++ (if m.split.held then [OnMouse (\e => map FromSplit (releasing m.split e))] else [])
  ++ (if m.split2.held then [OnMouse (\e => map FromSplit2 (releasing m.split2 e))] else [])

main : IO ()
main = do
  let m0 = MkModel (T.empty 30) (S.fromList 5 []) (A.empty 36 5) 0 False menus
                   (Tab.fromTitles ["List", "Controls", "Panes"]) True True ""
                   (P.withLimits 8 60 (P.fromSize LeftRight 28)) (P.withLimits 2 10 (P.fromSize TopBottom 4))
  r <- runProgram (MkProgram (m0, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("termui demo needs a terminal: " ++ show e)
    Right m => putStrLn ("bye, " ++ show (length m.items.items) ++ " items")
