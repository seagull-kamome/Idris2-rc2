||| The log view: appended text is wrapped and kept as lines, the window
||| follows the end until it is scrolled up, and a resize wraps again. The
||| window is rendered to text; the state is printed as (top, follow, lines).
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.Seq.Unsized
import TermUI.Frame
import TermUI.Node
import TermUI.Style
import TermUI.Widget.LogView
import TermUI.Widget.StyledText

%default covering

say : Style -> String -> String -> Para
say st who what = MkPara [spanOf st (who ++ " ")] [spanOf plain "  "] WrapWords [spanOf plain what]

state : Model -> String
state m = show (top m, follow m, lineCount m)

draw : String -> Model -> IO ()
draw title m = do
  putStrLn ("-- " ++ title ++ " " ++ state m)
  f <- render (the (Node ()) (view m)) (width m) (rows m)
  ls <- frameLines f
  traverse_ (\l => putStrLn ("|" ++ l)) ls

bold : Style
bold = withAttr Bold plain

main : IO ()
main = do
  let m0 = empty 3 16
  draw "empty" m0
  let m1 = append [say bold "ann" "hello there"] m0
  draw "one message" m1
  let m2 = append [say bold "bob" "hi, how are you today", say bold "ann" "fine"] m1
  draw "it wraps and follows the end" m2
  let m3 = update (LineUp 2) m2
  draw "scrolled up: not following" m3
  let m4 = append [say bold "bob" "good"] m3
  draw "appended while scrolled up: the window stays" m4
  let m5 = update ToEnd m4
  draw "to the end: following again" m5
  let m6 = update ToStart m5
  draw "to the start" m6
  let m7 = update PageDown m6
  draw "a page down" m7
  let m8 = resize 4 10 m5
  draw "narrower: wrapped again, still at the end" m8
  let m9 = resize 4 10 m6
  draw "narrower, at the start" m9
  let m10 = resize 6 16 m2
  draw "taller: the end stays in view" m10
  let m11 = resize 5 16 m6
  draw "scrolled to the start, then the window grows to hold all: following again" m11
  draw "and a new message follows" (append [say bold "ann" "yes"] m11)
  let m12 = resize 2 16 (update (LineDown 1) m6)
  draw "shorter window, not following: the position stays" m12
  draw "a log shorter than the window ignores scrolling" (update PageDown (update ToEnd (append [say bold "x" "y"] (empty 5 16))))
  draw "a zero-row window" (resize 0 16 m2)
  draw "a width of one wraps a character a line" (append [paragraph [spanOf plain "ab"]] (empty 3 1))
  draw "a wide character, an empty paragraph and a hard break" (append [paragraph [spanOf plain "日本\nb"], paragraph []] (empty 6 9))

  let whole = append [say bold "bot" "one two three four five six seven eight nine ten"] (empty 4 16)
      pieces = foldl (\acc, w => extendLast [spanOf plain w] acc)
                     (append [MkPara [spanOf bold "bot "] [spanOf plain "  "] WrapWords []] (empty 4 16))
                     ["one ", "two ", "three ", "four ", "five ", "six ", "seven ", "eight ", "nine ", "ten"]
  draw "text that arrives in pieces: extendLast" pieces
  putStrLn (show (toList (lines pieces) == toList (lines whole)))
  let more = extendLast [spanOf plain " eleven twelve"] (append [say bold "ann" "next"] pieces)
  draw "extending the last paragraph leaves the ones before" more
  draw "extending an empty log starts a paragraph" (extendLast [spanOf plain "hi"] (empty 2 16))
  let scrolled = update (LineUp 1) (extendLast [spanOf plain " more words that wrap around"] pieces)
  draw "extending while scrolled up: the window stays" (extendLast [spanOf plain " and more"] scrolled)
  draw "a different width wraps all of it again" (resize 4 9 more)

  let multi = append [say bold "a" "one", say bold "b" "two three four five six"] (empty 4 16)
  draw "extending after several paragraphs were appended at once" (extendLast [spanOf plain " seven eight nine"] multi)
  let rew = resize 4 12 multi
  draw "extending after a rewrap" (extendLast [spanOf plain " seven eight nine"] rew)
  putStrLn (show (toList (lines (extendLast [spanOf plain " seven eight nine"] rew)) == toList (lines (append [say bold "a" "one", say bold "b" "two three four five six seven eight nine"] (empty 4 12)))))
  draw "extending an empty last paragraph" (extendLast [spanOf plain "now"] (append [say bold "a" "x", paragraph []] (empty 4 16)))
  draw "extending a truncated paragraph cuts at the width" (extendLast [spanOf plain " defghijklmnopq"] (append [MkPara [] [] Truncate [spanOf plain "abc"]] (empty 2 10)))
  putStrLn (show (map (map (\s => s.spanText)) (toList (lines (append [paragraph [spanOf plain "ab"]] (empty 3 1))))))

  -- text with line breaks that arrives in pieces, as a model sends it
  let base = append [MkPara [spanOf bold "you  "] [spanOf plain "     "] WrapWords [spanOf plain "question here"], MkPara [spanOf bold "ai   "] [spanOf plain "     "] WrapWords []] (empty 5 30)
      nl = foldl (\acc, w => extendLast [spanOf plain w] acc) base ["Hello", ",", "\n", "second", " line\n", "\n", "third"]
  draw "pieces with line breaks" nl
  putStrLn (show (map (map (\s => s.spanText)) (toList (lines nl))))
  let whole2 = append [MkPara [spanOf bold "you  "] [spanOf plain "     "] WrapWords [spanOf plain "question here"], MkPara [spanOf bold "ai   "] [spanOf plain "     "] WrapWords [spanOf plain "Hello,\nsecond line\n\nthird"]] (empty 5 30)
  putStrLn (show (toList (lines nl) == toList (lines whole2)))
