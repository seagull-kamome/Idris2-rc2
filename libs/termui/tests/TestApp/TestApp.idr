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
import Data.String
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
    [ box [border Single] [T.field 12 Edit m.input]
    , box [border Single, height (Cells 5)] [S.list 3 Pick m.items]
    ]

appUpdate : (FileDesc -> IO ()) -> AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate _ (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate _ (Pick p) m = ({ items $= S.update 3 p } m, NoCmd)
appUpdate _ Add m =
  let v = T.value m.input in
  if v == "" then (m, NoCmd)
  else ({ input := T.empty, items := S.fromList (m.items.items ++ [v]) } m, NoCmd)
appUpdate _ Go m = (m, NoCmd)
appUpdate _ Done m = (m, Quit)

appSubs : AppModel -> List (Sub AppMsg)
appSubs _ =
  [ OnInput (\i => case i of
                     Press KEnter _ => Just Add
                     Press (KChar 'c') mods => if mods.ctrl then Just Done else Nothing
                     _ => Nothing) ]

-- Two items typed, a third pasted; Tab to the list; Down twice and Up once.
-- The Enter after "zz" is typed while the list has the focus, so the field
-- sees nothing of it.
script : String
script = "ab\rcd\r\ESC[200~x y\nz\ESC[201~\r\t\ESC[B\ESC[B\ESC[Azz\r\x03"

main : IO ()
main = do
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
               (MkModel T.empty (S.fromList []) 0, Perform (ignore (writeString master script) >> pure Go))
               (appUpdate (const (pure ())))
               appView
               appSubs
  Right m <- runProgramOn slave slave prog
    | Left e => putStrLn ("runProgram: " ++ show e)
  putStrLn ("items=" ++ show m.items.items ++ " selected=" ++ show (S.current m.items)
            ++ " field=" ++ show (T.value m.input))
