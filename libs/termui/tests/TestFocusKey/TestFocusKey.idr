||| A focus with a key stays with its widget when others appear or disappear
||| before it in the tree; without a key it stays with the index. Two text
||| fields (A, B) have a banner field before them that is shown and hidden while
||| B has the focus and keys are typed; the same program runs with and without
||| keys, on a pseudo-terminal as in TestApp.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.Bits
import Data.List
import Data.Maybe
import Data.String
import Text.Encoding.UTF8
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Termios
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Terminal
import TermUI.Widget.TextInput as T

%default covering

record AppModel where
  constructor MkModel
  useKeys : Bool
  banner : Bool
  fieldA, fieldB, fieldBanner : T.Model

data AppMsg = EditA T.Msg | EditB T.Msg | EditBanner T.Msg | Phase Nat | Wait Nat | Done

-- Tab moves the focus to B; "x"; the banner appears; "y"; the banner goes; "z".
chunks : List String
chunks = ["\t", "x", "", "y", "", "z", "\x03"]

appView : AppModel -> Node AppMsg
appView m =
  column []
    ( (if m.banner then [maybeKey "banner" (T.field EditBanner Nothing m.fieldBanner)] else [])
      ++ [maybeKey "a" (T.field EditA Nothing m.fieldA), maybeKey "b" (T.field EditB Nothing m.fieldB)] )
  where
    maybeKey : String -> Node AppMsg -> Node AppMsg
    maybeKey k n = if m.useKeys then keyed k n else n

appUpdate : (master : FileDesc) -> AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate _ (EditA e) m = ({ fieldA $= T.update e } m, NoCmd)
appUpdate _ (EditB e) m = ({ fieldB $= T.update e } m, NoCmd)
appUpdate _ (EditBanner e) m = ({ fieldBanner $= T.update e } m, NoCmd)
appUpdate master (Phase n) m =
  let m' = if n == 2 then { banner := True } m else if n == 4 then { banner := False } m else m
  in (m', Perform (ignore (writeString master (fromMaybe "" (getAt n chunks))) >> pure (Wait n)))
appUpdate master (Wait n) m = (m, After 80 (Phase (S n)))
appUpdate _ Done m = (m, Quit)

appSubs : AppModel -> List (Sub AppMsg)
appSubs _ =
  [ OnInput (\i => case i of
                     Press (KChar 'c') mods => if mods.ctrl then Just Done else Nothing
                     _ => Nothing) ]

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

runCase : Bool -> IO ()
runCase useKeys = do
  Right master <- posixOpenpt (2 .|. O_NOCTTY)
    | Left e => putStrLn ("posixOpenpt: " ++ show e)
  _ <- grantpt master
  _ <- unlockpt master
  Right name <- ptsname master
    | Left e => putStrLn ("ptsname: " ++ show e)
  Right slave <- openFile name (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open slave: " ++ show e)
  _ <- setWinSize master 30 6
  let prog = MkProgram
               (MkModel useKeys False (T.empty 10) (T.empty 10) (T.empty 10), Perform (pure (Phase 0)))
               (appUpdate master)
               appView
               appSubs
  Right m <- runProgramOn slave slave prog
    | Left e => putStrLn ("runProgram: " ++ show e)
  _ <- readUntil master "\ESC[?1049l"
  putStrLn ((if useKeys then "keyed:   " else "by index:") ++ " a=" ++ show (T.value m.fieldA)
            ++ " b=" ++ show (T.value m.fieldB) ++ " banner=" ++ show (T.value m.fieldBanner))

main : IO ()
main = do
  runCase True
  runCase False
