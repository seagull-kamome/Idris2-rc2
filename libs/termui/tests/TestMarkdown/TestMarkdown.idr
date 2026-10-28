||| The Markdown reader and its rendering: the blocks read from several texts,
||| the texts as drawn (with a line of marks under a row that has styled
||| cells), a text cut at every length (the blocks before the last one stay),
||| and a theme with other marks.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import TermUI.Frame
import TermUI.Len
import TermUI.Markdown
import TermUI.Markdown.Render
import TermUI.Markdown.Theme
import TermUI.Node
import TermUI.Style
import TermUI.Widget.StyledText

%default covering

dumpI : Inline -> String
dumpI (IText s) = show s
dumpI (IEmph k) = "em(" ++ joinBy " " (map dumpI k) ++ ")"
dumpI (IStrong k) = "strong(" ++ joinBy " " (map dumpI k) ++ ")"
dumpI (IStrike k) = "strike(" ++ joinBy " " (map dumpI k) ++ ")"
dumpI (ICode s) = "code(" ++ show s ++ ")"
dumpI (ILink k u) = "link(" ++ joinBy " " (map dumpI k) ++ " -> " ++ u ++ ")"
dumpI IBreak = "BR"

dumpB : Nat -> Block -> List String
dumpB d b = map (\l => pack (replicate (2 * d) ' ') ++ l) (go b)
  where
    go : Block -> List String
    go (Heading n k) = ["h" ++ show n ++ " " ++ joinBy " " (map dumpI k)]
    go (Paragraph k) = ["p " ++ joinBy " " (map dumpI k)]
    go (CodeBlock info ls) = ("code [" ++ info ++ "]") :: map (\l => "  | " ++ l) ls
    go (Quote bs) = "quote" :: concatMap (dumpB 1) bs
    go (Bullets items) = concatMap (\it => "item -" :: concatMap (dumpB 1) it) items
    go (Numbered n items) = ("numbered from " ++ show n) :: concatMap (\it => "item #" :: concatMap (dumpB 1) it) items
    go Rule = ["rule"]
    go (Styled _) = ["styled"]
    go (StyledDoc _) = ["styled doc"]

dump : String -> IO ()
dump src = do
  putStrLn "-- parse"
  traverse_ putStrLn (concatMap (dumpB 0) (parse src))

mark : Cell -> Char
mark c =
  if hasAttr Bold c.style then '^'
  else if hasAttr Italic c.style then '/'
  else if hasAttr Strike c.style then '~'
  else if hasAttr Underline c.style then 'u'
  else if c.style.fg == yellow then 'y'
  else if c.style.fg == red then 'r'
  else if c.style.bg == Indexed 236 then '#'
  else ' '

show' : String -> MdTheme -> Len -> String -> IO ()
show' title th w src = do
  putStrLn ("-- " ++ title)
  let t = renderMarkdown th w src
  let h = count (layoutLines w t)
  f <- render (the (Node ()) (markdown th src)) w h
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cs <- traverse (\x => getCell f x y) (if w <= 0 then [] else [0 .. w - 1])
               let m = pack (map mark cs)
               when (trim m /= "") $ putStrLn (" " ++ m))
            (zip [0 .. h `monus` 1] ls)

blocksText : String -> List String
blocksText src = map (joinBy "/" . dumpB 0) (parse src)

-- Cuts of the text at every length: the blocks before the last two of a cut
-- are the first blocks of the whole text.
stable : String -> IO ()
stable src = do
  let whole = blocksText src
  let bad = filter (\k => let cut = blocksText (pack (take k (unpack src)))
                           in not (isPrefixOf (take (length cut `minus` 2) cut) whole))
                   [0 .. length (unpack src)]
  putStrLn ("-- cuts: " ++ show (length (unpack src) + 1) ++ ", unstable: " ++ show (length bad))
  traverse_ (\k => putStrLn ("   at " ++ show k ++ ": " ++ show (pack (take k (unpack src))) ++ "\n      " ++ show (blocksText (pack (take k (unpack src)))))) bad

sample : String
sample = "# Title\n\nSome *emphasis*, **strong**, ~~gone~~ and `code` in a line that wraps over rows.\n\n## Lists\n\n- one\n- two\n  - nested a\n  - nested b\n- three\n\n1. first\n2. second\n10. tenth\n\n> quoted text\n> - with a list\n\n```idris\nmain : IO ()\nmain = putStrLn \"hi\"\n```\n\n---\nend"

boxed : MdTheme
boxed = { box := (\k => case k of
                          KHeading _ => { margin := MkEdges 1 0 0 0, padding := MkEdges 0 0 1 0 } noBox
                          KParagraph => { margin := MkEdges 1 3 2 4 } noBox
                          KQuote => { padding := MkEdges 0 0 0 2 } noBox
                          KCode => { margin := MkEdges 1 0 1 2, padding := MkEdges 1 1 1 1, fill := bgColor (Indexed 236) plain } noBox
                          _ => noBox) } defaultTheme

main : IO ()
main = do
  dump sample
  show' "sample" defaultTheme 40 sample
  dump "Mixed: a_b_c and 2 * 3 * 4, **bold *and em***, \\*not\\*, [a link](http://x.org/p), <https://y.org>, see https://z.org/a.\nsecond line  \nhard break\nstill\\\nbackslash"
  dump "[outer [inner]](u) [no target] [open](http://x"
  dump "```\nno closing fence\n- not a list"
  dump "- a\n\n  para in a\n- b\nlazy\n\n+ other marker\n3) paren\n4) list"
  dump "text\n- list cuts the paragraph\n2. not a list start"
  dump "|a|b|\n|-|-|\n|1|2|"
  dump "see [d](http://x.org for details (maybe) ok [w](https://en.wikipedia.org/wiki/Foo_(bar)) [t](http://x \"title\") [u](http://y 'k') z"
  dump "a\r\nb  \r\nc"
  show' "tabs and a quote theme" ({ quoteText := fgColor red plain } defaultTheme) 30 "a\tb `c\td`\n\n> q `x` [l](u)\n\n```\n```\n\nb"
  dump "#nospace\n####### seven\n## closing ##\n#"
  show' "japanese" defaultTheme 12 "# 見出し\n\n今日は天気、よい。「行こう」と言った。\n\n- 箇条書きの項目、とても長い文章になっています。"
  show' "another theme" (record' defaultTheme) 30 "# Head\n\n- item\n  1. deep\n\n> quote\n\n```c\nint x;\n```"
  show' "margin and padding by kind" boxed 30 "# Head\n\ntext one\n\ntext two that wraps over the narrow margins\n\n> quote\n\n```c\nint x;\n```\n\nend"
  show' "a quote, then code" boxed 30 "> quote\n\n```c\nint x;\n```"
  show' "margins collapse: the larger counts" ({ gap := 0 } boxed) 30 "text one\n\ntext two"
  show' "nested: a quote and a list item keep their own boxes" boxed 30 "> text in a quote\n>\n> more\n\n- item\n\n  second paragraph of the item"
  show' "a box wider than the width does not break" ({ box := const (MkBox (MkEdges 0 20 0 20) (MkEdges 0 20 0 20) plain) } defaultTheme) 10 "text\n\n```\ncode\n```"
  show' "negative sizes count as zero" ({ box := const (MkBox (MkEdges (-1) (-2) (-3) (-4)) noEdges plain) } defaultTheme) 20 "a\n\nb"
  stable sample
  stable "text\n#include <x>\n---Note\n***Note:*** done\n- a\n#x"
  stable "see [d](http://x.org for details (maybe) ok [w](https://en.wikipedia.org/wiki/Foo_(bar)) [t](http://x \"title\") z"
  stable "- a\n- b\n\n```\ncode\n```\n> q\n> r\n\npara *em* [l](u)"
 where
  record' : MdTheme -> MdTheme
  record' th = { headingMark := const "", bullet := const "* ", quoteBar := "> ", showLang := False
               , codeIndent := 3, fold := const Closed, rule := "=" } th
