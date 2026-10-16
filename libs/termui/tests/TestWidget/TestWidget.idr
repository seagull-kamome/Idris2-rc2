||| The widgets: the editing and selection logic is checked through `update`,
||| the drawing by rendering to text.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.Maybe
import Data.String
import TermUI.Frame
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Display
import TermUI.Widget.Select
import TermUI.Widget.TextInput as T

%default covering

draw : Node () -> Nat -> Nat -> IO ()
draw v w h = do
  f <- render v w h
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

-- The cell holding the cursor is bracketed so that it shows in plain text.
shown : T.Model -> String
shown m = pack (reverse m.before) ++ "|" ++ pack m.after

keys : List Input -> T.Model -> T.Model
keys [] m = m
keys (i :: is) m = keys is (maybe m (\msg => T.update msg m) (T.keyMsg i))

press : Char -> Input
press c = Press (KChar c) noMods

main : IO ()
main = do
  putStrLn "-- text input: editing"
  let m1 = keys (map press (unpack "hello")) T.empty
  putStrLn (shown m1)
  let m2 = keys [Press KLeft noMods, Press KLeft noMods, press 'X'] m1
  putStrLn (shown m2)
  putStrLn (shown (keys [Press KHome noMods] m2))
  putStrLn (shown (keys [Press KEnd noMods] (keys [Press KHome noMods] m2)))
  putStrLn (shown (keys [Press KBackspace noMods] m2))
  putStrLn (shown (keys [Press KDelete noMods] (keys [Press KHome noMods] m2)))
  putStrLn (shown (keys [Press (KChar 'a') (MkMods False True False), Press (KChar 'k') (MkMods False True False)] m2))
  putStrLn (shown (keys [Press KLeft noMods, Press (KChar 'u') (MkMods False True False)] m2))
  putStrLn (shown (keys [Paste "a\nb\tc"] T.empty))
  putStrLn ("value=" ++ T.value m2)
  putStrLn ("Enter/Tab/Alt+x ignored: " ++ show (map (isJust . T.keyMsg) [Press KEnter noMods, Press KTab noMods, Press (KChar 'x') (MkMods False False True)]))
  putStrLn "-- text input: drawing"
  draw (T.view 8 True m2) 10 1
  draw (T.view 8 False m2) 10 1
  draw (T.view 5 True m1) 10 1
  draw (T.view 5 True (keys [Press KHome noMods] m1)) 10 1
  putStrLn "-- select"
  let items = fromList ["one", "two", "three", "four", "five"]
  putStrLn (show (current items))
  let down = update 3 Down
  let s3 = down (down (down (down items)))
  putStrLn (show (current s3) ++ " top=" ++ show s3.top)
  let s5 = update 3 Down s3
  putStrLn (show (current s5) ++ " top=" ++ show s5.top)
  putStrLn (show (current (update 3 Down s5)))
  let up = update 3 Up s5
  putStrLn (show (current up) ++ " top=" ++ show up.top)
  putStrLn (show (current (update 3 First s5)) ++ " top=" ++ show (update 3 First s5).top)
  putStrLn (show (current (update 3 PageDown items)))
  putStrLn (show (current (update 3 Down (fromList []))))
  draw (view 3 True s3) 10 3
  draw (view 3 False s3) 10 3
  putStrLn "-- display"
  draw (spinner 0) 3 1
  draw (spinner 13) 3 1
  draw (progressBar 10 0) 12 1
  draw (progressBar 10 45) 12 1
  draw (progressBar 10 250) 12 1
  draw (table [("name", 6), ("size", 4)] [["alpha", "12"], ["bravo-long", "7"]]) 12 3
