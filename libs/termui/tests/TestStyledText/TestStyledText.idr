||| Styled text: wrapping at words, long words, character wrapping, truncation,
||| prefixes, wide characters and styles, and a pretty-printer `Doc` as styled
||| text. A view is rendered to text; under a row that has styled cells a line
||| marks them: `^` bold, `r` red, `u` underlined.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import Text.PrettyPrint.Prettyprinter.Doc
import Text.PrettyPrint.Prettyprinter.Util
import TermUI.Frame
import TermUI.Node
import TermUI.Style
import TermUI.Widget.StyledText
import TermUI.Widget.StyledText.Doc

%default covering

mark : Cell -> Char
mark c =
  if c.style.fg == red && hasAttr Bold c.style then '*'
  else if c.style.fg == red then 'r'
  else if hasAttr Bold c.style then '^'
  else if hasAttr Underline c.style then 'u'
  else ' '

showText : String -> Len -> StyledText -> IO ()
showText title w t = do
  putStrLn ("-- " ++ title)
  let h = count (layoutLines w t)
  f <- render (the (Node ()) (styledText w t)) w h
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cs <- traverse (\x => getCell f x y) (if w <= 0 then [] else [0 .. w - 1])
               let m = pack (map mark cs)
               when (trim m /= "") $ putStrLn (" " ++ m))
            (zip [0 .. h - 1] ls)

bold, redS, ul : Style
bold = withAttr Bold plain
redS = fgColor red plain
ul = withAttr Underline plain

main : IO ()
main = do
  showText "words wrap at spaces" 10 (plainText "the quick brown fox jumps")
  showText "a hard line break and an empty line" 10 (plainText "one\n\ntwo")
  showText "a word longer than the line is cut" 5 (plainText "abcdefghijkl x")
  showText "spaces at the end of a line and at the start of the next go" 6 (plainText "ab    cd")
  showText "leading spaces of a paragraph stay" 8 (plainText "  ab cd")
  showText "a long word after the leading spaces drops them, no empty line" 5 (plainText "  abcdefgh")
  showText "leading spaces and a word that fits the next line" 5 (plainText "  abcd")
  showText "a word that fits the next line but not the narrow first one goes there" 10
    [MkPara [spanOf plain "[12:00] "] [] WrapWords [spanOf plain "hello wonderful"]]
  showText "a hard break under a prefix, wrapped further" 8
    [MkPara [spanOf plain "> "] [spanOf plain "  "] WrapWords [spanOf plain "aa bb cc\ndd ee ff"]]
  showText "a combining mark stays with its letter at the cut" 3 (plainText "abe\x301\&cd")
  showText "a wide character on a line one cell wide" 1 (plainText "日a")
  showText "wide characters count two cells" 6 (plainText "日本語のテキスト")
  showText "wide characters between words" 8 (plainText "ab 日本語 cd")
  showText "styles follow the text over a wrap" 8
    [paragraph [spanOf plain "aa ", spanOf bold "bb cc ", spanOf redS "dd ee"]]
  showText "a style across a hard break" 8 [paragraph [spanOf ul "x\ny"]]
  showText "a bullet and a hanging indent" 12
    [MkPara [spanOf plain "- "] [spanOf plain "  "] WrapWords [spanOf plain "alpha beta gamma delta"]]
  showText "a quote bar on every line" 10
    [MkPara [spanOf redS "| "] [spanOf redS "| "] WrapWords [spanOf plain "to be or not to be"]]
  showText "characters wrap anywhere" 5 [MkPara [] [] WrapChars [spanOf plain "ab cd efghij"]]
  showText "truncate cuts the line" 5 [MkPara [] [] Truncate [spanOf plain "abcdefghij"]]
  showText "empty text" 5 []
  showText "a paragraph per line of a string" 20 (plainText "first\nsecond")

  putStrLn "-- layoutLines"
  let ls = layoutLines 8 [paragraph [spanOf bold "ab ", spanOf bold "cd", spanOf plain " ef gh ij"]]
  putStrLn (show (map (map (\s => (s.spanText, hasAttr Bold s.spanStyle))) ls))
  putStrLn (show (map (map (\s => s.spanText)) (layoutLines 0 (plainText "a b"))))

  putStrLn "-- Doc"
  let d : Doc Style
      d = hsep [annotate bold "Name:", pretty "value"] <+> line
          <+> hang 2 (reflow "a long sentence that is wrapped by the pretty printer at the width")
  showText "a document at width 24" 24 (fromDoc id 24 d)
  showText "the same document at width 14" 14 (fromDoc id 14 d)
  showText "an empty document" 10 (fromDoc id 10 neutral)
  showText "a trailing line break adds no line" 10 (fromDoc id 10 (pretty "x" <+> line))
  showText "a blank line in the middle stays" 10 (fromDoc id 10 (pretty "x" <+> line <+> line <+> pretty "y"))
  showText "wide characters in a document" 8 (fromDoc id 8 (pretty "日本語日本語"))
  let g : Doc Style
      g = group (vsep [annotate redS "one", annotate (withAttr Underline plain) "two"])
  showText "a group fits on a line at 20" 20 (fromDoc id 20 g)
  showText "a group breaks at 6" 6 (fromDoc id 6 g)
  showText "nested annotations: the inner style wins over the outer" 20
    (fromDoc id 20 (annotate bold (pretty "out " <+> annotate redS (pretty "in") <+> pretty " out")))
  showText "a line indented by the document keeps its indent when it is wrapped further" 12
    (fromDoc id 12 (nest 4 (line' <+> pretty "aaaa bbbb cccc dddd")))

  putStrLn "-- a view that wraps to the width it is placed in"
  let t = plainText "the quick brown fox jumps over the lazy dog"
  for_ [12, 20] $ \w => do
    f <- render (the (Node ()) (styledView t)) w 6
    ls <- frameLines f
    traverse_ (\l => putStrLn ("|" ++ l)) ls
  fb <- render (the (Node ()) (box [border Single] [styledView t])) 16 6
  lb <- frameLines fb
  traverse_ (\l => putStrLn ("|" ++ l)) lb
  fr <- render (the (Node ()) (row [] [box [shrink 0] [text "> "], styledView t])) 16 6
  lr <- frameLines fr
  traverse_ (\l => putStrLn ("|" ++ l)) lr
