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
  mouse : List String
  trace : List String
  tocks : List String

data Msg = Inc | Dec | Tick | Typed String | Bump Integer | SetCount Integer | Stop | Noop | Mouse' String | Order String | Tock String

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

-- Its handler is built from the model it was drawn with: two "+" in one read
-- count twice only if the handlers are refreshed after the first.
adder : Integer -> Node Msg
adder n =
  focusable
    (\focused => box [border (if focused then Rounded else Single)] [text "n"])
    (\i => case i of
             Press (KChar '+') _ => Just (SetCount (n + 1))
             _ => Nothing)

view : Model -> Node Msg
view m =
  column []
    [ text ("count " ++ show m.count ++ " ticks " ++ show m.ticks)
    , row [gap 1] [ button "-" Dec, button "+" Inc, adder m.count ]
    , text (unwords (reverse m.keys))
    ]

-- Enter on the first button, Tab, Enter on the second twice, a typed key,
-- Shift+Tab, Space on the first, Tab twice to the third (an Enter it ignores)
-- two "+" in one read and a click with the wheel turned.
script : String
script = "\r\t\r\rx\ESC[Z \t\t\r++\ESC[<0;5;3M\ESC[<0;5;3m\ESC[<65;1;1M"

program : (master : FileDesc) -> Program Model Msg
program master = MkProgram
  (MkModel 0 0 [] [] [] [], Perform (ignore (writeString master script) >> pure Noop))
  update
  view
  subs
  where
    update : Msg -> Model -> (Model, Cmd Msg)
    update Inc m = ({ count $= (+ 1) } m, NoCmd)
    update Dec m = ({ count $= (\c => c - 1) } m, NoCmd)
    update (Bump n) m = ({ count $= (+ n) } m, NoCmd)
    update (SetCount n) m = ({ count := n } m, NoCmd)
    update (Typed k) m = ({ keys $= (k ::) } m, NoCmd)
    update (Mouse' k) m = ({ mouse $= (k ::) } m, NoCmd)
    update Stop m = (m, Quit)
    update Noop m = (m, if m.ticks == 0 then Batch [After 300 Tick, Emit (Order "A")] else NoCmd)
    update (Order o) m =
      ({ trace $= (o ::) } m,
       case o of
         "A" => Batch [Emit (Order "B"), Emit (Order "C")]
         "B" => Emit (Order "D")
         _ => NoCmd)
    update (Tock k) m = ({ tocks $= (k ::) } m, NoCmd)
    update Tick m =
      ({ ticks $= S } m,
       Batch [ Perform (pure (Bump 100))
             , Perform (ignore (writeString master "qy") >> pure Noop) ])

    subs : Model -> List (Sub Msg)
    subs m = (if elem "a" m.tocks then [] else [scopeSub "a" (Every "t" 10 (Tock "a"))])
             ++ (if elem "b" m.tocks then [] else [scopeSub "b" (Every "t" 60 (Tock "b"))])
             ++ [ OnMouse (\e => Just (Mouse' (show e)))
             , OnInput (\i => case i of
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
            ++ " keys=" ++ show (reverse model.keys)
            ++ " mouse=" ++ show (reverse model.mouse))
  putStrLn ("trace=" ++ show (reverse model.trace) ++ " tocks=" ++ show (reverse model.tocks))
  out <- readUntil master "\ESC[?1049l"
  putStrLn (visible out)
