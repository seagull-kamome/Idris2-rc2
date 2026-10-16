||| The widgets: the editing and selection logic is checked through `update`,
||| the drawing by rendering to text; a second line of `^` marks the cells
||| drawn inverse.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.Maybe
import TermUI.Frame
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Display
import TermUI.Widget.Select as S
import TermUI.Widget.TextInput as T

%default covering

draw : Node () -> Nat -> Nat -> IO ()
draw v w h = do
  f <- render v w h
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

-- The text of a one-line view and, below it, a `^` under each inverse cell.
drawMarked : Node () -> Nat -> IO ()
drawMarked v w = do
  f <- render v w 1
  ls <- frameLines f
  cells <- traverse (\x => getCell f x 0) (take w [0 .. w])
  let marks = pack (map (\c => if hasAttr Inverse c.style then '^' else ' ') cells)
  traverse_ (\l => putStrLn ("|" ++ l)) ls
  putStrLn ("|" ++ pack (reverse (dropWhile (== ' ') (reverse (unpack marks)))))

-- The cursor is shown as a bar.
shown : T.Model -> String
shown m = pack (reverse m.before) ++ "|" ++ pack m.after

keys : List Input -> T.Model -> T.Model
keys [] m = m
keys (i :: is) m = keys is (maybe m (\msg => T.update msg m) (T.keyMsg i))

press : Char -> Input
press c = Press (KChar c) noMods

key : Key -> Input
key k = Press k noMods

ctrl : Char -> Input
ctrl c = Press (KChar c) (MkMods False True False)

typed : String -> T.Model -> T.Model
typed s = keys (map press (unpack s))

main : IO ()
main = do
  putStrLn "-- text input: editing"
  let m1 = typed "hello" (T.empty 8)
  putStrLn (shown m1)
  let m2 = keys [key KLeft, key KLeft, press 'X'] m1
  putStrLn (shown m2)
  putStrLn (shown (keys [key KHome] m2))
  putStrLn (shown (keys [key KEnd] (keys [key KHome] m2)))
  putStrLn (shown (keys [key KBackspace] m2))
  putStrLn (shown (keys [key KDelete] (keys [key KHome] m2)))
  putStrLn (shown (keys [ctrl 'a', ctrl 'k'] m2))
  putStrLn (shown (keys [key KLeft, ctrl 'u'] m2))
  putStrLn (shown (keys [Paste "a\nb\tc"] (T.empty 8)))
  putStrLn (shown (T.fromString 8 "a\nb\ESCc"))
  putStrLn ("value=" ++ T.value m2)
  putStrLn "-- text input: edges"
  putStrLn (shown (keys [key KBackspace, key KDelete, key KLeft, key KRight, ctrl 'k', ctrl 'u'] (T.empty 8)))
  putStrLn ("ignored: " ++ show (map (isJust . T.keyMsg)
    [ key KEnter, key KTab, key KEscape, ctrl 'c', press 'x'
    , Press (KChar 'x') (MkMods False False True), Press (KChar 'a') (MkMods False True True) ]))
  putStrLn "-- text input: drawing"
  drawMarked (T.view True m2) 10
  drawMarked (T.view False m2) 10
  drawMarked (T.view True (keys [key KHome] m2)) 10
  putStrLn "-- text input: scrolling (8 cells)"
  let long = T.fromString 8 "hello world!"
  drawMarked (T.view True long) 10
  drawMarked (T.view True (keys [key KLeft, key KLeft, key KLeft] long)) 10
  drawMarked (T.view True (keys (replicate 6 (key KLeft)) long)) 10
  drawMarked (T.view True (keys (replicate 12 (key KLeft)) long)) 10
  putStrLn "-- text input: wide and zero-width characters"
  let wide = T.fromString 8 "あいうえおかきく"
  drawMarked (T.view True wide) 10
  drawMarked (T.view True (keys (replicate 3 (key KLeft)) wide)) 10
  drawMarked (T.view True (keys [key KHome] wide)) 10
  let comb = keys [key KLeft, key KLeft] (T.fromString 8 "e\x301x")
  putStrLn (show (length comb.before) ++ " before, cursor on U+" ++ show (map ord (take 1 comb.after)))
  drawMarked (T.view True comb) 10
  putStrLn "-- text input: very narrow"
  drawMarked (T.view True (T.fromString 1 "abc")) 3
  drawMarked (T.view True (T.fromString 0 "abc")) 3
  putStrLn "-- select"
  let items = S.fromList ["one", "two", "three", "four", "five"]
  putStrLn (show (current items))
  let down = S.update 3 Down
  let s3 = down (down (down (down items)))
  putStrLn (show (current s3) ++ " top=" ++ show s3.top)
  let s5 = S.update 3 Down s3
  putStrLn (show (current s5) ++ " top=" ++ show s5.top)
  let up = S.update 3 Up s5
  putStrLn (show (current up) ++ " top=" ++ show up.top)
  putStrLn (show (current (S.update 3 First s5)) ++ " top=" ++ show (S.update 3 First s5).top)
  putStrLn (show (current (S.update 3 PageDown items)))
  putStrLn (show (current (S.update 3 PageUp items)))
  putStrLn (show (current (S.update 3 Down (S.fromList []))))
  putStrLn "-- select: items replaced"
  let shrunk = S.setItems ["a", "b"] s5
  putStrLn (show (current shrunk) ++ " top=" ++ show shrunk.top)
  let stale = { items := ["a", "b"] } s5
  let fixed = S.update 3 Up stale
  putStrLn (show (current fixed) ++ " top=" ++ show fixed.top)
  putStrLn (show (current (S.setItems ["one", "two", "three", "four", "five", "six"] s3)))
  putStrLn "-- select: window"
  let zero = S.update 0 Down items
  putStrLn (show (current zero) ++ " top=" ++ show zero.top)
  draw (S.view 3 True ({ selected := 4, top := 0 } items)) 10 3
  draw (S.view 3 True s3) 10 3
  draw (S.view 3 False s3) 10 3
  draw (S.view 0 True s3) 10 1
  putStrLn ("keys: " ++ show (map (isJust . S.keyMsg)
    [ key KUp, key KDown, key KPageUp, key KPageDown, key KHome, key KEnd, key KEnter, key KTab
    , Press KUp (MkMods False False True), Press KDown (MkMods False True False), press 'j' ]))
  putStrLn "-- display"
  draw (spinner 0) 3 1
  draw (spinner 13) 3 1
  draw (progressBar 10 0) 12 1
  draw (progressBar 10 45) 12 1
  draw (progressBar 10 250) 12 1
  draw (progressBar 20 50) 12 2
  draw (progressBar 0 50) 3 1
  draw (table [("name", 6), ("size", 4)] [["alpha", "12"], ["bravo-long", "7"]]) 12 3
  draw (table [("a", 3), ("b", 3)] [["1", "2", "3"], ["4"], []]) 8 4
  draw (table [("a", 3)] []) 8 2
