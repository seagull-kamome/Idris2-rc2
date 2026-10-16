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

  dump "min width of a box"
    (row [] [ box [minWidth 8, border Single] [text "a"], box [border Single] [text "b"] ]) 20 3
  dump "max width of a growing box (the rest is not handed on)"
    (row [] [ box [grow 1, maxWidth 6, border Ascii] [], box [grow 1, border Ascii] [] ]) 20 3
  dump "max width over a fixed width, min over a max"
    (row [] [ box [width (Cells 12), maxWidth 5, border Ascii] [], box [width (Cells 2), minWidth 4, border Ascii] [] ]) 20 3
  dump "min and max height of a column's children"
    (column [] [ box [minHeight 3, border Single] [text "x"], box [maxHeight 2, border Single] [text "a", text "b", text "c"], text "end" ]) 12 8
  dump "a row that wraps"
    (row [wrapChildren, gap 1] (map (\w => box [border Single] [text w]) ["ab", "cd", "ef", "gh", "ij"])) 14 8
  dump "a wrapping row has the height of its lines"
    (column [] [ row [wrapChildren] (map (\w => box [border Single] [text w]) ["ab", "cd", "ef", "gh"]), text "end" ]) 12 8
  dump "wrapping lines: gap, justify and align"
    (row [wrapChildren, gap 1, justify JEnd, align Center] [ box [border Single, height (Cells 3)] [text "a"], box [border Single] [text "bb"], box [border Single] [text "cc"], box [border Single] [text "dd"] ]) 14 8
  dump "a child too wide for its line has a line of its own"
    (row [wrapChildren] [ text "ab", box [width (Cells 20)] [text "long"], text "cd" ]) 10 4
  dump "absolute: top-left offsets over the flow"
    (box [] [ text "the flow goes on", text "under the box", box [absolute, top 1, left 4, border Single] [text "pop"] ]) 20 6
  dump "absolute: right and bottom"
    (box [] [ text "x", box [absolute, right 1, bottom 0, border Single] [text "end"] ]) 12 5
  dump "absolute: all four sides stretch it"
    (box [] [ text "background text", box [absolute, top 1, right 2, bottom 1, left 2, border Rounded] [text "box"] ]) 14 6
  dump "absolute: a covering box centres its child"
    (box [] [ text "behind", box [absolute, top 0, left 0, right 0, bottom 0, align Center, justify JCenter] [box [border Single] [text "dialog"]] ]) 14 7
  dump "absolute boxes do not take room"
    (column [gap 1] [ text "one", box [absolute, top 5, left 0] [text "away"], text "two" ]) 8 6
  dump "absolute: percent size, minimum"
    (box [] [ box [absolute, left 1, top 1, width (Percent 50), minHeight 3, border Single] [text "half"] ]) 20 6

  dump "a combining mark stays with its character" (text "e\x301\&ab") 6 1
  dump "a mark after a wide character" (text "あ\x301\&い") 6 1
  dump "a mark at the start is dropped" (text "\x301\&ab") 6 1
  dump "a mark that starts another text has nothing to join there and is dropped" (row [] [text "e", text "\x301\&x"]) 6 1
  dump "zero-width joiner and variation selector are dropped" (text "a\x200D\&b\xFE0F\&c") 6 1
  dump "marks stack" (text "a\x301\&\x302\&b") 6 1

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
  putStrLn "-- diff: combining marks"
  fm <- draw (text "e\x301x") 3 1
  dm <- diffFrames Nothing fm
  putStrLn (show' dm)
  putStrLn "-- diff: bg + attrs + rgb"
  f3 <- draw (box [style (bgColor (RGB 1 2 3) (withAttr Bold plain))] [styled (fgColor (Indexed 200) plain) "x"]) 2 1
  d4 <- diffFrames Nothing f3
  putStrLn (show' d4)
