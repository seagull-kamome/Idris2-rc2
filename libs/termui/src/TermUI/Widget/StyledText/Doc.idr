||| A pretty-printer `Doc` (contrib's Text.PrettyPrint.Prettyprinter) as
||| styled text. The `Doc` is laid out for the width, so `group`, `nest` and
||| `hang` break lines as they would on a page that wide, and its annotations
||| become styles; a line broken at an indent keeps that indent when it is
||| wrapped further.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.StyledText.Doc

import Data.List
import Data.Maybe
import Data.String
import Text.PrettyPrint.Prettyprinter.Doc
import TermUI.Len
import TermUI.Node
import TermUI.Style
import TermUI.Widget.StyledText

%default covering

-- The annotations in effect are a stack of styles, the innermost first; an
-- inner style wins over the outer ones.
record Walk where
  constructor MkWalk
  styles : List Style
  indent : Int
  spans : List Span          -- of the line so far, the last one first
  paras : List Para          -- the finished lines, the last one first

current : Walk -> Style
current w = fromMaybe plain (head' w.styles)

addText : String -> Walk -> Walk
addText t w = { spans $= (MkSpan (current w) t ::) } w

finishLine : Int -> Walk -> Walk
finishLine next w =
  let pad = [MkSpan plain (pack (replicate (cast w.indent) ' '))]
      lead = if w.indent > 0 && not (null w.spans) then pad else []
  in { indent := next, spans := [], paras $= (MkPara lead lead WrapWords (reverse w.spans) ::) } w

walk : Walk -> SimpleDocStream ann -> (ann -> Style) -> List Para
walk w SEmpty _ = reverse (if null w.spans then w.paras else (finishLine 0 w).paras)
walk w (SChar c rest) f = walk (addText (singleton c) w) (force rest) f
walk w (SText _ t rest) f = walk (addText t w) (force rest) f
walk w (SLine i rest) f = walk (finishLine i w) rest f
walk w (SAnnPush a rest) f = walk ({ styles $= (f a `over` current w ::) } w) rest f
walk w (SAnnPop rest) f = walk ({ styles $= drop 1 } w) rest f

||| The document laid out for `w` cells, its annotations turned into styles.
export
fromDoc : (ann -> Style) -> Len -> Doc ann -> StyledText
fromDoc f w doc =
  let stream = layoutPretty (MkLayoutOptions (AvailablePerLine (cast (max 1 w)) 1.0)) doc
  in walk (MkWalk [] 0 [] []) stream f
