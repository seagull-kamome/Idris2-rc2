||| The widgets: the editing and selection logic is checked through `update`,
||| the drawing by rendering to text; a second line of `^` marks the cells
||| drawn inverse.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import Data.Maybe
import TermUI.Frame
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Display
import TermUI.Widget.Scroll as Sc
import TermUI.Widget.Scrolling as Sc
import TermUI.Widget.Select as S
import TermUI.Widget.Table as Tb
import TermUI.Widget.TextArea as A
import TermUI.Widget.TextInput as T

%default covering

draw : Node () -> Nat -> Nat -> IO ()
draw v w h = do
  f <- render v w h
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

-- The rows of a view and, below each row that has inverse cells, a `^` under
-- every one of them.
drawMarked : Node () -> Nat -> Nat -> IO ()
drawMarked v w h = do
  f <- render v w h
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cells <- traverse (\x => getCell f x y) (take w [0 ..])
               let marks = pack (map (\c => if hasAttr Inverse c.style then '^' else ' ') cells)
               when (any (== '^') (unpack marks)) $
                 putStrLn ("|" ++ pack (reverse (dropWhile (== ' ') (reverse (unpack marks))))))
            (zip [0 .. length ls] ls)

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

click : MouseButton -> Nat -> Nat -> Input
click b c r = Mouse (MkMouseEvent b ButtonDown c r noMods)

-- The text of the editor with a bar at the cursor.
areaText : A.Model -> String
areaText m = joinBy "\n" (map pack (reverse m.above ++ [reverse m.before ++ ['|'] ++ m.after] ++ m.below))

areaKeys : List Input -> A.Model -> A.Model
areaKeys [] m = m
areaKeys (i :: is) m = areaKeys is (maybe m (\msg => A.update msg m) (A.keyMsg i))

typedArea : String -> A.Model -> A.Model
typedArea s = areaKeys (map (\c => if c == '\n' then key KEnter else press c) (unpack s))

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
  drawMarked (T.view True m2) 10 1
  drawMarked (T.view False m2) 10 1
  drawMarked (T.view True (keys [key KHome] m2)) 10 1
  putStrLn "-- text input: scrolling (8 cells)"
  let long = T.fromString 8 "hello world!"
  drawMarked (T.view True long) 10 1
  drawMarked (T.view True (keys [key KLeft, key KLeft, key KLeft] long)) 10 1
  drawMarked (T.view True (keys (replicate 6 (key KLeft)) long)) 10 1
  drawMarked (T.view True (keys (replicate 12 (key KLeft)) long)) 10 1
  putStrLn "-- text input: wide and zero-width characters"
  let wide = T.fromString 8 "あいうえおかきく"
  drawMarked (T.view True wide) 10 1
  drawMarked (T.view True (keys (replicate 3 (key KLeft)) wide)) 10 1
  drawMarked (T.view True (keys [key KHome] wide)) 10 1
  let comb = keys [key KLeft, key KLeft] (T.fromString 8 "e\x301x")
  putStrLn (show (length comb.before) ++ " before, cursor on U+" ++ show (map ord (take 1 comb.after)))
  drawMarked (T.view True comb) 10 1
  putStrLn "-- text input: very narrow"
  drawMarked (T.view True (T.fromString 1 "abc")) 3 1
  drawMarked (T.view True (T.fromString 0 "abc")) 3 1
  putStrLn "-- select"
  let items = S.fromList 3 ["one", "two", "three", "four", "five"]
  putStrLn (show (current items))
  let down = S.update Down
  let s3 = down (down (down (down items)))
  putStrLn (show (current s3) ++ " top=" ++ show s3.top)
  let s5 = S.update Down s3
  putStrLn (show (current s5) ++ " top=" ++ show s5.top)
  let up = S.update Up s5
  putStrLn (show (current up) ++ " top=" ++ show up.top)
  putStrLn (show (current (S.update First s5)) ++ " top=" ++ show (S.update First s5).top)
  putStrLn (show (current (S.update PageDown items)))
  putStrLn (show (current (S.update PageUp items)))
  putStrLn (show (current (S.update Down (S.fromList 3 []))))
  putStrLn "-- select: items replaced"
  let shrunk = S.setItems ["a", "b"] s5
  putStrLn (show (current shrunk) ++ " top=" ++ show shrunk.top)
  let stale = { items := ["a", "b"] } s5
  let fixed = S.update Up stale
  putStrLn (show (current fixed) ++ " top=" ++ show fixed.top)
  putStrLn (show (current (S.setItems ["one", "two", "three", "four", "five", "six"] s3)))
  putStrLn "-- select: window"
  let zero = S.update Down (S.resize 0 items)
  putStrLn (show (current zero) ++ " top=" ++ show zero.top)
  draw (S.view True ({ selected := 4, top := 0 } items)) 10 3
  draw (S.view True s3) 10 3
  draw (S.view False s3) 10 3
  draw (S.view True (S.resize 0 s3)) 10 1
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

  putStrLn "-- clicks"
  let field = T.fromString 8 "hello"
  putStrLn (shown (keys [click LeftButton 2 0] field))
  putStrLn (shown (keys [click LeftButton 40 0] (keys [key KHome] field)))
  putStrLn (shown (keys [click RightButton 2 0] field))
  let wideField = T.fromString 8 "あいう"
  putStrLn (shown (keys [click LeftButton 3 0] wideField))
  putStrLn (shown (keys [click LeftButton 2 0] wideField))
  let list = S.fromList 3 ["one", "two", "three", "four", "five"]
  putStrLn (show (S.current (S.update (ClickRow 2) list)))
  putStrLn (show (S.current (S.update (ClickRow 9) list)))
  let scrolledList = S.update Down (S.update Down (S.update Down (S.update Down list)))
  putStrLn (show (S.current (S.update (ClickRow 0) scrolledList)) ++ " top=" ++ show scrolledList.top)
  putStrLn (show (map (isJust . S.keyMsg) [click LeftButton 0 1, click RightButton 0 1, Mouse (MkMouseEvent WheelDown ButtonDown 0 0 noMods)]))
  putStrLn "-- scroll view"
  let doc = Sc.fromLines 4 (map (\i => "line " ++ show i) (the (List Nat) [1 .. 10]))
  draw (Sc.view doc) 12 4
  let d2 = Sc.update PageDown doc
  putStrLn ("top=" ++ show d2.top)
  draw (Sc.view d2) 12 4
  putStrLn ("top=" ++ show (Sc.update ToEnd doc).top ++ " " ++ show (Sc.update (LineDown 99) doc).top ++ " " ++ show (Sc.update (LineUp 5) d2).top)
  draw (Sc.view (Sc.update ToEnd doc)) 12 4
  draw (Sc.view (Sc.fromLines 4 ["a", "b"])) 12 4
  putStrLn (show (map (isJust . Sc.keyMsg) [key KUp, key KPageDown, Mouse (MkMouseEvent WheelDown ButtonDown 0 0 noMods), press 'x', ctrl 'c']))
  putStrLn "-- text area: editing"
  let a0 = A.empty 20 4
  let a1 = typedArea "hello\nworld\n!" a0
  putStrLn (areaText a1)
  putStrLn (areaText (areaKeys [key KUp] a1))
  putStrLn (areaText (areaKeys [key KUp, key KUp, key KHome] a1))
  putStrLn (areaText (areaKeys [key KBackspace] a1))
  putStrLn (areaText (areaKeys [key KBackspace, key KBackspace] a1))
  putStrLn (areaText (areaKeys [key KUp, key KUp, key KEnd, key KDelete] a1))
  putStrLn (areaText (areaKeys [key KUp, key KUp, key KRight, key KRight, key KRight, key KRight, key KRight, key KRight] a1))
  putStrLn (areaText (areaKeys [key KLeft, key KLeft, key KLeft] a1))
  putStrLn (areaText (areaKeys [key KUp, key KUp, key KEnd, key KDown, key KDown] a1))
  putStrLn (areaText (areaKeys [Press KHome (MkMods False True False)] a1))
  putStrLn (areaText (areaKeys [Press KHome (MkMods False True False), Press KEnd (MkMods False True False)] a1))
  putStrLn (areaText (areaKeys [key KUp, ctrl 'k'] a1))
  putStrLn (areaText (areaKeys [Paste "a\r\nb\rc\td"] a0))
  putStrLn (areaText (areaKeys [key KLeft, Paste "X\nY"] (typedArea "ab" a0)))
  putStrLn (show (A.value a1) ++ " " ++ show (lineCount a1))
  putStrLn (show (A.value (A.fromString 20 4 "one\ntwo\r\nthree")))
  putStrLn "-- text area: columns are kept on vertical moves"
  let b1 = typedArea "abcdef\nxy\n123456" a0
  putStrLn (areaText (areaKeys [key KUp] b1))
  putStrLn (areaText (areaKeys [key KUp, key KUp] b1))
  putStrLn (areaText (areaKeys [key KUp, key KUp, key KDown, key KDown] b1))
  putStrLn (areaText (areaKeys [key KUp, key KRight, key KUp] b1))
  putStrLn "-- text area: scrolling and drawing"
  let long = typedArea "l1\nl2\nl3\nl4\nl5\nl6" (A.empty 12 3)
  putStrLn ("top=" ++ show long.top)
  drawMarked (A.view True long) 12 3
  draw (A.view True long) 12 3
  let up2 = areaKeys [key KUp, key KUp, key KUp, key KUp, key KUp] long
  putStrLn ("top=" ++ show up2.top)
  draw (A.view True up2) 12 3
  let paged = areaKeys [key KPageUp] long
  putStrLn ("top=" ++ show paged.top ++ " " ++ show (areaText paged))
  let wideLine = typedArea "0123456789abcdefghij" (A.empty 8 2)
  putStrLn ("left=" ++ show wideLine.left)
  drawMarked (A.view True wideLine) 8 2
  let narrow = areaKeys [key KHome] wideLine
  putStrLn ("left=" ++ show narrow.left)
  draw (A.view True narrow) 8 2
  putStrLn "-- text area: clicks"
  let c1 = typedArea "hello\nworld\nfoo" (A.empty 20 3)
  putStrLn (areaText (areaKeys [click LeftButton 2 0] c1))
  putStrLn (areaText (areaKeys [click LeftButton 3 1] c1))
  putStrLn (areaText (areaKeys [click LeftButton 40 1] c1))
  putStrLn (areaText (areaKeys [click LeftButton 1 9] c1))
  putStrLn (show (map (isJust . A.keyMsg) [click RightButton 1 1, Mouse (MkMouseEvent WheelUp ButtonDown 0 0 noMods), key KTab, ctrl 'c', Press (KChar 'x') (MkMods False False True)]))
  putStrLn "-- review: document start, left, top, bar column, pages"
  putStrLn (areaText (areaKeys [Press KHome (MkMods False True False)] (typedArea "hello" a0)))
  let ds = areaKeys [Press KHome (MkMods False True False), key KDown] (areaKeys [key KUp, key KRight, key KRight, key KRight] (typedArea "abcdef\nxy" a0))
  putStrLn (areaText ds)
  let ln = typedArea (pack (replicate 30 'a') ++ "\nabc") (A.empty 12 4)
  let ln1 = areaKeys [key KUp, key KEnd, key KDown] (A.resize 12 4 (areaKeys [key KUp] (typedArea (pack (replicate 30 'a') ++ "\nabc") (A.empty 12 4))))
  putStrLn ("left=" ++ show ln.left ++ " after moving to the short line left=" ++ show ln1.left)
  drawMarked (A.view True ln1) 12 4
  let six = typedArea "1\n2\n3\n4\n5\n6" (A.empty 12 5)
  putStrLn ("top=" ++ show six.top)
  let five = areaKeys [key KHome, key KBackspace] six
  putStrLn ("lines=" ++ show (lineCount five) ++ " top=" ++ show five.top)
  let text3 = typedArea "hello\nworld\nfoo" (A.empty 20 3)
  putStrLn (areaText (areaKeys [click LeftButton 19 0] text3))
  putStrLn (areaText (areaKeys [click LeftButton 18 0] text3))
  let nine = typedArea "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9" (A.empty 12 3)
  putStrLn ("top=" ++ show nine.top)
  let pg = areaKeys [key KPageUp] nine
  putStrLn ("top=" ++ show pg.top ++ " " ++ show (areaText pg))
  let pg2 = areaKeys [key KPageUp, key KPageDown] nine
  putStrLn ("top=" ++ show pg2.top ++ " " ++ show (areaText pg2))
  let pg3 = areaKeys [key KPageDown] (areaKeys [Press KHome (MkMods False True False)] nine)
  putStrLn ("top=" ++ show pg3.top ++ " " ++ show (areaText pg3))
  putStrLn (show (A.value (A.fromString 20 4 "a\n")) ++ " " ++ show (A.value (areaKeys [Paste ""] a0)))
  putStrLn (show (map (\r => (S.current (S.update (ClickRow r) (S.fromList 5 ["a", "b"])))) [0, 1, 4]))
  putStrLn "-- review: a very long line"
  let huge = A.fromString 80 24 (pack (replicate 100000 'x'))
  putStrLn (show huge.left ++ " " ++ show (areaKeys [Press (KChar 'a') (MkMods False True False)] huge).left ++ " " ++ show (areaKeys [Press (KChar 'e') (MkMods False True False)] (areaKeys [Press (KChar 'a') (MkMods False True False)] huge)).left)
  let hugeField = T.fromString 80 (pack (replicate 100000 'x'))
  putStrLn (show hugeField.offset)
  putStrLn "-- select: the window is in the model"
  let five = S.fromList 3 ["one", "two", "three", "four", "five"]
  let atEnd = S.update Last five
  putStrLn (show (current atEnd) ++ " rows=" ++ show atEnd.rows ++ " top=" ++ show atEnd.top)
  let bigger = S.resize 5 atEnd
  putStrLn ("resize 5: top=" ++ show bigger.top)
  let smaller = S.resize 2 atEnd
  putStrLn ("resize 2: top=" ++ show smaller.top ++ " " ++ show (current smaller))
  draw (S.view True smaller) 10 2
  draw (S.view True bigger) 10 5
  let grown = S.setItems ["a", "b", "c", "d", "e", "f", "g", "h"] atEnd
  putStrLn (show (current grown) ++ " rows=" ++ show grown.rows ++ " top=" ++ show grown.top)
  putStrLn "-- select: the bar is not part of the list"
  draw (S.list (const ()) five) 10 3
  putStrLn "-- table that scrolls"
  let rowsData = map (\i => ["row " ++ show i, show (i * 10)]) (the (List Nat) [1 .. 7])
  let tb = Tb.fromRows [("name", 6), ("size", 4)] 3 rowsData
  draw (Tb.view tb) 12 4
  let tb2 = Tb.update PageDown tb
  putStrLn ("top=" ++ show tb2.top)
  draw (Tb.view tb2) 12 4
  let tb3 = Tb.update ToEnd tb
  putStrLn ("top=" ++ show tb3.top)
  draw (Tb.view tb3) 12 4
  putStrLn ("top=" ++ show (Tb.update (LineDown 99) tb).top ++ " " ++ show (Tb.update (LineUp 9) tb3).top)
  let tb4 = Tb.resize 5 tb3
  putStrLn ("resize 5: top=" ++ show tb4.top)
  draw (Tb.view tb4) 12 6
  draw (Tb.view (Tb.fromRows [("a", 3)] 3 [["1"]])) 6 4
  draw (Tb.table (const ()) tb) 12 4
