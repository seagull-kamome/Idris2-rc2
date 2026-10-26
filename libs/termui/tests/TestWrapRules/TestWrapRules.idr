||| Line breaking rules for Japanese text (kinsoku) in styled text, plain text
||| and the editor, and the number of rows the editor needs for wrapped lines.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import TermUI.Frame
import TermUI.Layout
import TermUI.Node
import TermUI.Style
import TermUI.Widget.StyledText
import TermUI.Widget.TextArea as A

%default covering

showNode : String -> Len -> Len -> Node () -> IO ()
showNode title w h n = do
  putStrLn ("-- " ++ title)
  f <- render n w h
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

styled : String -> Len -> String -> IO ()
styled title w s =
  showNode title w (count (layoutLines w [paragraph [spanOf plain s]])) (styledText w [paragraph [spanOf plain s]])

plainText : String -> Wrap -> Len -> String -> IO ()
plainText title wrap w s =
  let h = count (wrapText wrap w s)
  in showNode title w h (column [] [Text plain wrap s])

-- The editor with room for the whole text: the rows it shows and what it said it needs.
editor : Len -> String -> IO ()
editor cells s = do
  let m = A.setWrap True (A.fromString cells 1 s)
  let need = A.wrappedRows (cast cells) m
  putStrLn ("-- editor, " ++ show cells ++ " cells: needs " ++ show need ++ " rows")
  let m' = A.resize cells (cast need) m
  f <- render (the (Node ()) (A.view False m')) cells (cast need)
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

main : IO ()
main = do
  styled "a stop does not begin a line: the character before goes down" 10 "今日は天気、よい"
  styled "an opening bracket does not end a line" 10 "彼は言った「行く」"
  styled "the long vowel mark does not begin a line" 6 "あのコーヒーは"
  styled "at most three characters go down" 8 "ありがと。。。。。。"
  styled "latin words are left alone" 10 "hello, world. foo bar"
  plainText "plain text, words" WrapWords 10 "今日は天気、よい"
  plainText "plain text, characters" WrapChars 10 "彼は言った「行く」"
  editor 12 "aaaaaa bbbbbb cccccc"
  editor 12 "あいうえおかきくけこさ"
  editor 12 "今日は天気、よい\nok"
  editor 12 "short"
