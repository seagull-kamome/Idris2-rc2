||| A tiny editor: a multi-line text area filling the screen, a status line
||| and a help viewer toggled with F1. Ctrl-C quits.
|||
||| Build: idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -o editor Editor.idr
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
import TermUI.Widget.Scroll as Sc
import TermUI.Widget.TextArea as A

%default covering

record AppModel where
  constructor MkModel
  text : A.Model
  help : Sc.Model
  showHelp : Bool

data AppMsg = Edit A.Msg | Scroll Sc.Msg | Resized Nat Nat | ToggleHelp | Quit'

helpLines : List String
helpLines =
  [ "Arrows, Home/End, PageUp/PageDown   move"
  , "Ctrl-Home / Ctrl-End                 start / end of the text"
  , "Ctrl-A / Ctrl-E                      start / end of the line"
  , "Ctrl-K / Ctrl-U                      delete to the end / start of the line"
  , "Enter                                new line"
  , "mouse                                click to place the cursor, wheel to move"
  , "F1                                   show / hide this help"
  , "Ctrl-C                               quit" ]

appView : AppModel -> Node AppMsg
appView m =
  column []
    [ box [grow 1] [ if m.showHelp then Sc.viewer 8 Scroll m.help else A.area Edit m.text ]
    , styled (withAttr Inverse plain)
        (" " ++ show (A.lineCount m.text) ++ " lines, " ++ show (strLength (A.value m.text)) ++ " characters  (F1: help)")
    ]

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ text $= A.update e } m, NoCmd)
appUpdate (Scroll s) m = ({ help $= Sc.update 8 s } m, NoCmd)
appUpdate (Resized cols rows) m = ({ text $= A.resize cols (rows `minus` 1) } m, NoCmd)
appUpdate ToggleHelp m = ({ showHelp $= not } m, NoCmd)
appUpdate Quit' m = (m, Quit)

appSubs : AppModel -> List (Sub AppMsg)
appSubs _ =
  [ MouseFocus
  , OnResize Resized
  , OnInput (\i => case i of
                     Press (KF 1) _ => Just ToggleHelp
                     Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
                     _ => Nothing) ]

main : IO ()
main = do
  r <- runProgram (MkProgram (MkModel (A.empty 78 20) (Sc.fromLines helpLines) False, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("termui editor needs a terminal: " ++ show e)
    Right m => putStrLn (A.value m.text)
