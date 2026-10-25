||| The canvas: what is drawn into it reads back, and how it lands in a frame
||| (cut by its box, wide characters cut by an edge or by what is drawn over
||| them, the marks under it) is checked by rendering to text.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import TermUI.Canvas
import TermUI.Frame
import TermUI.Node
import TermUI.Output
import TermUI.Style

%default covering

draw : Node () -> Len -> Len -> IO Frame
draw = render

show' : String -> String
show' s = concatMap esc (unpack s)
  where
    esc : Char -> String
    esc '\ESC' = "<ESC>"
    esc c = singleton c

dump : String -> Node () -> Len -> Len -> IO ()
dump title v w h = do
  putStrLn ("-- " ++ title)
  f <- draw v w h
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

main : IO ()
main = do
  c <- newCanvas 6 3
  putString c 0 0 plain "hello"
  putCell c 5 2 '#' plain
  fillRect c 1 1 3 1 '.' plain
  dump "drawing" (canvas c) 8 4

  putStrLn "-- reading back"
  r <- newCanvas 4 2
  putCell r 1 1 'q' (withAttr Bold (fgColor (RGB 9 8 7) (bgColor (Indexed 200) plain)))
  (g, st) <- cellAt r 1 1
  putStrLn (show (g, st))
  (g', st') <- cellAt r 0 0
  putStrLn (show (g', st' == settle plain))
  (g'', _) <- cellAt r 9 9
  putStrLn (show g'')

  w <- newCanvas 6 2
  putString w 0 0 plain "日本a"
  dump "wide characters" (canvas w) 6 2
  putCell w 1 0 'X' plain
  dump "half of a wide character overwritten" (canvas w) 6 2
  putCell w 5 1 'あ' plain
  putCell w 4 1 'あ' plain
  dump "a wide character at the right edge is a blank, inside it is kept" (canvas w) 6 2
  (cont, _) <- cellAt w 5 1
  putStrLn (show (cont == continuation))

  f4 <- newCanvas 5 2
  fillRect f4 0 0 5 1 'あ' plain
  fillRect f4 1 1 2 1 'あ' plain
  dump "a wide character fills as many times as fit, a blank where one cell is left" (canvas f4) 5 2
  putCell f4 0 1 'z' plain
  putCell f4 (-1) 1 'あ' plain
  putCell f4 (-3) 1 'x' plain
  dump "a wide character half off the left edge blanks the first cell" (canvas f4) 5 2

  dump "cut by the box" (box [] [box [width (Cells 4), height (Cells 2)] [canvas c]]) 8 4
  cw <- newCanvas 4 1
  putString cw 0 0 plain "ab日"
  dump "a wide character cut by the box is a blank" (box [] [box [width (Cells 3)] [canvas cw]]) 6 1
  dump "in a bordered box" (box [border Single] [canvas cw]) 8 3
  dump "beside text" (row [] [text "<", canvas cw, text ">"]) 8 1

  o <- newCanvas 2 1
  putString o 0 0 plain "ab"
  dump "over a wide character: its first half" (box [] [text "あいう", box [absolute, left 1] [canvas o]]) 6 1
  dump "over a wide character: its second half" (box [] [text "あいう", box [absolute, left 3] [canvas o]]) 6 1
  q <- newCanvas 1 1
  putCell q 0 0 'Q' plain
  dump "over a combining mark" (box [] [text "e\x301xyz", box [absolute, left 0] [canvas q]]) 6 1
  fq <- draw (box [] [text "e\x301xyz", box [absolute, left 0] [canvas q]]) 6 1
  cq <- getCell fq 0 0
  putStrLn (show (length cq.combining))

  two <- newCanvas 2 2
  putString two 0 0 plain "QR"
  putString two 0 1 plain "ST"
  dump "over combining marks in two rows" (box [] [text "e\x301x\ne\x301y", box [absolute, left 0] [canvas two]]) 3 2
  fq2 <- draw (box [] [text "e\x301x\ne\x301y", box [absolute, left 0] [canvas two]]) 3 2
  cq2 <- getCell fq2 0 1
  putStrLn (show (length cq2.combining))
  keep <- draw (box [] [text "xe\x301", box [absolute, left 0] [canvas q]]) 3 1
  ck <- getCell keep 1 0
  putStrLn (show (length ck.combining))

  putStrLn "-- styles reach the terminal"
  s <- newCanvas 2 1
  putCell s 0 0 'r' (fgColor red plain)
  putCell s 1 0 'g' (bgColor (RGB 1 2 3) (withAttr Underline plain))
  fs <- draw (canvas s) 2 1
  ds <- diffFrames Nothing fs
  putStrLn (show' ds)
  s2 <- newCanvas 2 1
  putCell s2 0 0 'r' (fgColor red plain)
  putCell s2 1 0 'G' (bgColor (RGB 1 2 3) (withAttr Underline plain))
  fs2 <- draw (canvas s2) 2 1
  d2 <- diffFrames (Just fs) fs2
  putStrLn (show' d2)

  putStrLn "-- clear"
  clear c (bgColor (Indexed 4) plain)
  fc <- draw (canvas c) 6 3
  cc <- getCell fc 2 1
  putStrLn (show (cc.glyph, cc.style.bg))

  putStrLn "-- empty and negative canvases"
  e <- newCanvas (-3) 2
  putStrLn (show (e.canvasWidth, e.canvasHeight))
  putCell e 0 0 'x' plain
  dump "an empty canvas takes no room" (row [] [text "a", canvas e, text "b"]) 4 1
