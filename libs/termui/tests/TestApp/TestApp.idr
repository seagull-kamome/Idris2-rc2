||| The widgets together in a program on a pseudo-terminal: a text field adds
||| items to a list on Enter, Tab moves the focus to the list, the arrow keys
||| move the selection and Ctrl-C quits. The keys are written by the first
||| command, as in TestProgram.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.Bits
import Data.List
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Termios
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Terminal
import TermUI.Widget.Select as S
import TermUI.Widget.TextInput as T

%default covering

record AppModel where
  constructor MkModel
  input : T.Model
  items : S.Model
  pasted : Nat

data AppMsg = Edit T.Msg | Pick S.Msg | Add | Go | Done

appView : AppModel -> Node AppMsg
appView m =
  column [gap 1]
    [ box [border Single] [T.field Edit (Just Add) m.input]
    , box [border Single, height (Cells 5)] [S.list 3 Pick m.items]
    ]

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate (Pick p) m = ({ items $= S.update 3 p } m, NoCmd)
appUpdate Add m =
  let v = T.value m.input in
  if v == "" then (m, NoCmd)
  else ({ input := T.empty 12, items $= S.setItems (m.items.items ++ [v]) } m, NoCmd)
appUpdate Go m = (m, NoCmd)
appUpdate Done m = (m, Quit)

appSubs : AppModel -> List (Sub AppMsg)
appSubs _ =
  [ OnInput (\i => case i of
                     Press (KChar 'c') mods => if mods.ctrl then Just Done else Nothing
                     _ => Nothing) ]

-- Five items: two typed, one pasted (its line break becomes a space), two
-- typed again. "zz" stays in the field: the Enter that follows Tab goes to the
-- list, which ignores it. Down four times and Up once scroll the window
-- (3 lines) over the 5 items; Shift+Tab returns to the field, where "!" is
-- appended; Ctrl-C quits.
script : String
script = "ab\rcd\r\ESC[200~x y\nz\ESC[201~\re1\re2\rzz\t\r\ESC[B\ESC[B\ESC[B\ESC[B\ESC[A\ESC[Z!\x03"

main : IO ()
main = do
  Right devnull <- openFile "/dev/null" (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open /dev/null: " ++ show e)
  r0 <- runProgramOn devnull devnull (MkProgram (MkModel (T.empty 12) (S.fromList []) 0, NoCmd) appUpdate appView appSubs)
  putStrLn ("not a terminal: " ++ either show (const "ran") r0)
  Right master <- posixOpenpt (2 .|. O_NOCTTY)
    | Left e => putStrLn ("posixOpenpt: " ++ show e)
  _ <- grantpt master
  _ <- unlockpt master
  Right name <- ptsname master
    | Left e => putStrLn ("ptsname: " ++ show e)
  Right slave <- openFile name (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open slave: " ++ show e)
  _ <- setWinSize master 30 12
  let prog = MkProgram
               (MkModel (T.empty 12) (S.fromList []) 0, Perform (ignore (writeString master script) >> pure Go))
               appUpdate
               appView
               appSubs
  Right m <- runProgramOn slave slave prog
    | Left e => putStrLn ("runProgram: " ++ show e)
  putStrLn ("items=" ++ show m.items.items ++ " selected=" ++ show (S.current m.items) ++ " top=" ++ show m.items.top
            ++ " field=" ++ show (T.value m.input))
