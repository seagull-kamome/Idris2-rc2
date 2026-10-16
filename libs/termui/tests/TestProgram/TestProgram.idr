||| An Elm-style program run on a pseudo-terminal: focus moved with Tab and
||| Shift+Tab, a focused node taking its keys, a subscription, a delayed
||| command and a Perform. The keys are written to the pty by the program's
||| first command; the program ends itself by writing "q" to its own input when its
||| delayed message arrives. The terminal output (every frame the differ
||| produced) is printed with the escape sequences made visible.
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
import Text.Encoding.UTF8

%default covering

record Model where
  constructor MkModel
  count : Integer
  ticks : Nat
  keys : List String

data Msg = Inc | Dec | Tick | Typed String | Bump Integer | Stop | Noop

visible : List Bits8 -> String
visible bs = concatMap esc (decode bs)
  where
    esc : Char -> String
    esc '\ESC' = "<ESC>"
    esc '\n' = "<LF>"
    esc '\r' = "<CR>"
    esc c = if ord c >= 32 then singleton c else "<" ++ show (ord c) ++ ">"

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

button : String -> Msg -> Node Msg
button label msg =
  focusable
    (\focused => box [border (if focused then Rounded else Single), paddingXY 1 0]
                     [styled (if focused then withAttr Bold plain else plain) label])
    (\i => case i of
             Press KEnter _ => Just msg
             Press (KChar ' ') _ => Just msg
             _ => Nothing)

view : Model -> Node Msg
view m =
  column []
    [ text ("count " ++ show m.count ++ " ticks " ++ show m.ticks)
    , row [gap 1] [ button "-" Dec, button "+" Inc ]
    , text (unwords (reverse m.keys))
    ]

-- Enter on the first button, Tab, Enter on the second twice, a typed key,
-- Shift+Tab, Space on the first, Tab twice around the ring and Enter.
script : String
script = "\r\t\r\rx\ESC[Z \t\t\r"

program : (master : FileDesc) -> Program Model Msg
program master = MkProgram
  (MkModel 0 0 [], Perform (ignore (writeString master script) >> pure Noop))
  update
  view
  subs
  where
    update : Msg -> Model -> (Model, Cmd Msg)
    update Inc m = ({ count $= (+ 1) } m, NoCmd)
    update Dec m = ({ count $= (\c => c - 1) } m, NoCmd)
    update (Bump n) m = ({ count $= (+ n) } m, NoCmd)
    update (Typed k) m = ({ keys $= (k ::) } m, NoCmd)
    update Stop m = (m, Quit)
    update Noop m = (m, if m.ticks == 0 then After 100 Tick else NoCmd)
    update Tick m =
      ({ ticks $= S } m,
       Batch [ Perform (pure (Bump 100))
             , Perform (ignore (writeString master "q") >> pure Noop) ])

    subs : Model -> List (Sub Msg)
    subs _ = [ OnInput (\i => case i of
                                 Press (KChar 'q') _ => Just Stop
                                 Press (KChar c) m => if m.ctrl then Nothing else Just (Typed (singleton c))
                                 _ => Nothing) ]

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
  _ <- setWinSize master 24 6

  Right model <- runProgramOn slave slave (program master)
    | Left e => putStrLn ("runProgram: " ++ show e)
  putStrLn ("count=" ++ show model.count ++ " ticks=" ++ show model.ticks
            ++ " keys=" ++ show (reverse model.keys))
  out <- readUntil master "\ESC[?1049l"
  putStrLn (visible out)
