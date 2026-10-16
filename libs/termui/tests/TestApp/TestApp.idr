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
import Data.Maybe
import Data.List1
import Data.String
import Text.Encoding.UTF8
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
import TermUI.Widget.TextArea as A
import TermUI.Widget.TextInput as T

%default covering

record AppModel where
  constructor MkModel
  input : T.Model
  items : S.Model
  notes : A.Model

data AppMsg = Edit T.Msg | Pick S.Msg | Note A.Msg | Add | Phase Nat | Wait Nat | Done

chunks : List String
chunks =
  [ "ab\r", "cd\r", "\ESC[200~x y\nz\ESC[201~\r", "e1\re2\r", "zz"
  , "\t", "\r", "\ESC[B\ESC[B\ESC[B\ESC[B\ESC[A", "\ESC[Z!"
  , "\ESC[<0;3;6M", "\ESC[<65;3;6M\ESC[<64;3;6M\ESC[<64;3;6M", "\ESC[<0;3;2M", "!"
  , "\ESC[<0;4;12M", "ab\rcd", "\ESC[<0;3;12M", "X", "\x03" ]

appView : AppModel -> Node AppMsg
appView m =
  column [gap 1]
    [ box [border Single] [T.field Edit (Just Add) m.input]
    , box [border Single, height (Cells 5)] [S.list Pick m.items]
    , box [border Single] [A.area Note m.notes]
    ]

appUpdate : (master : FileDesc) -> AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate _ (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate _ (Pick p) m = ({ items $= S.update p } m, NoCmd)
appUpdate _ (Note n) m = ({ notes $= A.update n } m, NoCmd)
appUpdate _ Add m =
  let v = T.value m.input in
  if v == "" then (m, NoCmd)
  else ({ input := T.empty 12, items $= S.setItems (m.items.items ++ [v]) } m, NoCmd)
appUpdate master (Phase n) m = (m, Perform (ignore (writeString master (fromMaybe "" (getAt n chunks))) >> pure (Wait n)))
appUpdate master (Wait n) m = (m, After 80 (Phase (S n)))
appUpdate _ Done m = (m, Quit)

appSubs : AppModel -> List (Sub AppMsg)
appSubs _ =
  [ MouseFocus
  , OnInput (\i => case i of
                     Press (KChar 'c') mods => if mods.ctrl then Just Done else Nothing
                     _ => Nothing) ]

-- Five items: two typed, one pasted (its line break becomes a space), two
-- typed again. "zz" stays in the field: the Enter that follows Tab goes to the
-- list, which ignores it. Down four times and Up once scroll the window
-- (3 lines) over the 5 items; Shift+Tab returns to the field, where "!" is
-- appended. Then the mouse: a click in the list focuses it and selects the first
-- visible line, the wheel moves the selection (down once, up twice), a click in
-- the field puts the cursor between the two z, where "!" is inserted. Last the
-- notes (a multi-line editor lower down the screen): a click focuses it, two
-- lines are typed, a click on the first puts the cursor after its first letter,
-- where "X" is inserted; Ctrl-C quits.


-- The tty layer hands output written to the slave to the master
-- asynchronously: read until the marker has arrived.
readUntil : FileDesc -> String -> IO (List Bits8)
readUntil master marker = go []
  where
    want : List Bits8
    want = encode (unpack marker)

    go : List Bits8 -> IO (List Bits8)
    go acc =
      if isSuffixOf want acc
         then pure acc
         else do
           Right more <- readBytes master
             | Left _ => pure acc
           if null more then pure acc else go (acc ++ more)

-- The terminal cursor positions the program asked for, in order, with the
-- cursor visibility that followed: ESC [ row ; col H ESC [ ? 2 5 h/l.
cursorMoves : String -> List String
cursorMoves out = dedup (pairs (forget (split (== '\ESC') out)))
  where
    pairs : List String -> List String
    pairs (a :: b :: rest) =
      if isSuffixOf ['H'] (unpack a) && isPrefixOf (unpack "[?25") (unpack b) && isPrefixOf ['['] (unpack a)
         then (pack (drop 1 (unpack a)) ++ " " ++ pack (take 1 (drop 4 (unpack b)))) :: pairs (b :: rest)
         else pairs (b :: rest)
    pairs _ = []

    dedup : List String -> List String
    dedup (a :: b :: rest) = if a == b then dedup (b :: rest) else a :: dedup (b :: rest)
    dedup xs = xs

main : IO ()
main = do
  Right devnull <- openFile "/dev/null" (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open /dev/null: " ++ show e)
  r0 <- runProgramOn devnull devnull (MkProgram (MkModel (T.empty 12) (S.fromList 3 []) (A.empty 20 3), NoCmd) (appUpdate devnull) appView appSubs)
  putStrLn ("not a terminal: " ++ either show (const "ran") r0)
  Right master <- posixOpenpt (2 .|. O_NOCTTY)
    | Left e => putStrLn ("posixOpenpt: " ++ show e)
  _ <- grantpt master
  _ <- unlockpt master
  Right name <- ptsname master
    | Left e => putStrLn ("ptsname: " ++ show e)
  Right slave <- openFile name (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open slave: " ++ show e)
  _ <- setWinSize master 30 20
  let prog = MkProgram
               (MkModel (T.empty 12) (S.fromList 3 []) (A.empty 20 3), Perform (pure (Phase 0)))
               (appUpdate master)
               appView
               appSubs
  Right m <- runProgramOn slave slave prog
    | Left e => putStrLn ("runProgram: " ++ show e)
  out <- readUntil master "\ESC[?1049l"
  putStrLn ("cursor: " ++ show (cursorMoves (pack (decode out))))
  putStrLn ("items=" ++ show m.items.items ++ " selected=" ++ show (S.current m.items) ++ " top=" ++ show m.items.top
            ++ " field=" ++ show (T.value m.input) ++ " notes=" ++ show (A.value m.notes))
