||| The Markdown viewer: blocks that fold (the cursor, a click, all at once),
||| a heading folding its section, text added to the last segment while it
||| arrives, themes that say what folds and what starts folded, and a resize.
||| The window is drawn as text; under a row with a mark in reverse a line
||| says `R`. The state is printed as (top, follow, lines).
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import TermUI.Frame
import TermUI.Len
import TermUI.Markdown.Theme
import TermUI.Node
import TermUI.Style
import TermUI.Widget.MarkdownView as V
import TermUI.Widget.Scrolling as Sc

%default covering

state : V.Model -> String
state m = show (m.top, m.follow, V.lineCount m)

draw : String -> V.Model -> IO ()
draw title m = do
  putStrLn ("-- " ++ title ++ " " ++ state m)
  f <- render (the (Node ()) (V.view m)) m.width m.rows
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cs <- traverse (\x => getCell f x y) (if m.width <= 0 then [] else [0 .. m.width - 1])
               let marks = pack (map (\c => if hasAttr Inverse c.style then 'R' else ' ') cs)
               when (trim marks /= "") $ putStrLn (" " ++ marks))
            (zip [0 .. m.rows `monus` 1] ls)

doc : String
doc = "# Title\n\nintro text\n\n```c\nint a;\nint b;\n```\n\n- x\n- y\n\n## Sub\n\nunder sub\n\n# Next\n\nlast"

run : List V.ViewMsg -> V.Model -> V.Model
run ms m = foldl (flip V.update) m ms

main : IO ()
main = do
  let m0 = V.addSegment doc (V.empty defaultTheme 14 30)
  draw "start: everything open" (V.update (V.Scroll Sc.ToStart) m0)
  let m1 = run [V.Scroll Sc.ToStart, V.NextUnit] m0
  draw "the cursor on the first unit" m1
  let m2 = run [V.NextUnit, V.Toggle] m1
  draw "the code block folded" m2
  draw "the list is the next unit; the paragraph between is skipped" (run [V.NextUnit] m2)
  draw "the heading folded: its section, the lower heading too, goes" (run [V.PrevUnit, V.Toggle] m2)
  draw "the code block toggled twice is as it was" (run [V.Toggle] m2)
  draw "the cursor does not go past the last unit" (run [V.NextUnit, V.NextUnit, V.NextUnit, V.NextUnit, V.NextUnit, V.NextUnit] m1)
  draw "all folded" (run [V.FoldAll, V.Scroll Sc.ToStart] m0)
  draw "the cursor was on the code block, now out of sight: next goes to the first unit" (run [V.NextUnit, V.NextUnit, V.FoldAll, V.Scroll Sc.ToStart, V.NextUnit] m0)
  draw "a toggle with the cursor out of sight does nothing" (run [V.NextUnit, V.NextUnit, V.FoldAll, V.Scroll Sc.ToStart, V.Toggle] m0)
  draw "all open again" (run [V.FoldAll, V.UnfoldAll, V.Scroll Sc.ToStart] m0)
  let m4 = run [V.Scroll Sc.ToStart, V.Click 4 1] m0
  draw "a click in the gutter on the code block (row 4)" m4
  draw "a click below the window does nothing" (run [V.Scroll Sc.ToStart, V.Click 14 1, V.Click 20 1] m0)
  draw "a click outside the gutter does nothing" (run [V.Scroll Sc.ToStart, V.Click 4 10] m0)
  -- a second segment, then text added to it while it arrives
  let s0 = V.addSegment "# ai\n\n" (V.empty defaultTheme 8 30)
  let s1 = V.extendSegment "Here is code:\n\n```py\nprint(1)" s0
  draw "arriving: the fence is not closed yet" s1
  draw "nothing added" (V.extendSegment "" s1)
  let s2 = V.extendSegment "\n```\n\nand more" s1
  draw "the fence closed, following the end" s2
  let s3 = V.addSegment "## you\n\nthanks" s2
  draw "another segment" s3
  let s4 = run [V.Scroll Sc.ToStart, V.NextUnit, V.Toggle] s3
  draw "the first message folded into its heading" s4
  let s5 = V.extendSegment " a lot" s4
  draw "added to the last segment while the first is folded" s5
  -- a theme: code starts folded, lists do not fold, quotes cannot be folded
  let th = { fold := (\k => case k of
                              KCode => Closed
                              KBullets => NoFold
                              KQuote => NoFold
                              _ => Open) } defaultTheme
  let t0 = V.addSegment "intro\n\n```sh\nls\nrm\n```\n\n- a\n- b\n\n> quoted" (V.empty th 12 30)
  draw "code starts folded, the list and the quote have no mark" t0
  draw "the code block opened with a click" (run [V.Scroll Sc.ToStart, V.Click 2 0] t0)
  -- no unit folds: no gutter
  let n0 = V.addSegment "# H\n\ntext" (V.empty ({ fold := const NoFold } defaultTheme) 5 20)
  draw "nothing folds: no gutter" n0
  -- a resize wraps again
  draw "narrow" (V.resize 14 14 m0)
  -- the window keeps the block at its row when it is folded
  let big = V.addSegment (joinBy "\n\n" (map (\k => "para " ++ show k) [1 .. 12]) ++ "\n\n```\na\nb\nc\n```\n\nend") (V.empty defaultTheme 6 24)
  let b1 = run [V.Scroll Sc.ToStart, V.Scroll (Sc.LineDown 20), V.NextUnit] big
  draw "scrolled down, the unit picked" b1
  draw "folded: the window stays at the mark" (V.update V.Toggle b1)
