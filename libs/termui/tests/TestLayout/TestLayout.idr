||| Layout and painting: views are rendered to plain text and compared.
||| Diff output: the escape sequences are printed visibly.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import TermUI.Frame
import TermUI.Node
import TermUI.Output
import TermUI.Style

%default covering

draw : Node () -> Nat -> Nat -> IO Frame
draw = render

show' : String -> String
show' s = concatMap esc (unpack s)
  where
    esc : Char -> String
    esc '\ESC' = "<ESC>"
    esc c = singleton c

dump : String -> Node () -> Nat -> Nat -> IO ()
dump title v w h = do
  putStrLn ("-- " ++ title)
  f <- draw v w h
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

main : IO ()
main = do
  dump "border + text" (box [border Single] [text "hello"]) 9 3
  dump "rounded, padding" (box [border Rounded, padding 1] [text "ab"]) 8 5
  dump "row: grow splits the rest"
    (row [] [ box [border Ascii, grow 1] [text "a"], box [border Ascii, grow 2] [text "b"] ]) 18 3
  dump "row: fixed + spacer + gap"
    (row [gap 1] [ text "L", spacer, text "R" ]) 10 1
  dump "column: gap and justify end"
    (column [gap 1, justify JEnd] [ text "one", text "two" ]) 5 6
  dump "justify between / center cross"
    (row [justify JBetween, align Center, height (Cells 3)] [ text "x", text "y", text "z" ]) 9 3
  dump "word wrap" (box [width (Cells 10)] [text "the quick brown fox"]) 10 4
  dump "hard break of a long word" (text "abcdefghijkl") 5 3
  dump "truncate" (Text plain Truncate "truncated text") 8 1
  dump "wide characters" (box [border Single] [text "日本語ab"]) 10 3
  dump "wide char cut by the edge" (text "あいう") 5 1
  dump "shrink" (row [] [ box [border Single, width (Cells 8)] [], box [border Single, width (Cells 8)] [] ]) 10 3
  dump "percent + margin" (row [] [ box [width (Percent 50), border Single] [], box [margin 1, grow 1, border Single] [] ]) 20 5
  dump "clip to the box"
    (column [] [ box [border Single, width (Cells 6), height (Cells 3), align Start] [text "overflowing"], text "tail" ]) 8 5

  dump "row of wrapping texts keeps the height"
    (column [] [ row [] [ text "aaaa bbbb", text "cccc dddd" ], text "end" ]) 9 4
  dump "leading spaces" (text "  abcdefgh") 5 3
  dump "trailing newline" (text "abc\n") 5 3
  dump "shrink: a rigid sibling cannot absorb" (row [] [ box [border Single, width (Cells 4)] [], box [shrink 0, border Single, width (Cells 100)] [] ]) 10 3
  dump "shrink saturates, the rest is redistributed"
    (row [] [ box [width (Cells 10), shrink 5, border Single] [], box [width (Cells 30), border Single] [] ]) 20 3
  dump "justify around" (row [justify JAround] [ text "a", text "b" ]) 10 1
  dump "child does not overwrite the parent border"
    (column [] [ box [border Single, width (Cells 6), height (Cells 3)] [ box [width (Cells 10), border Single] [] ] ]) 8 4
  dump "truncated and char-wrapped"
    (column [] [ truncated plain "truncated", charWrapped plain "wrap me please" ]) 6 4
  dump "zero-size screen" (text "x") 0 0

  putStrLn "-- diff: first frame"
  let hot = fgColor red plain
  let v1 = column [] [ styled hot "hi", text "yo" ]
  f1 <- draw v1 4 2
  d1 <- diffFrames Nothing f1
  putStrLn (show' d1)
  putStrLn "-- diff: unchanged"
  d2 <- diffFrames (Just f1) f1
  putStrLn ("[" ++ d2 ++ "]")
  putStrLn "-- diff: one cell changed"
  f2 <- draw (column [] [ styled hot "hi", text "yO" ]) 4 2
  d3 <- diffFrames (Just f1) f2
  putStrLn (show' d3)
  putStrLn "-- diff: bg + attrs + rgb"
  f3 <- draw (box [style (bgColor (RGB 1 2 3) (withAttr Bold plain))] [styled (fgColor (Indexed 200) plain) "x"]) 2 1
  d4 <- diffFrames Nothing f3
  putStrLn (show' d4)
