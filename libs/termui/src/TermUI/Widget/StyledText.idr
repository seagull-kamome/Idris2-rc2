||| Styled text: paragraphs of spans in different styles, wrapped to a width
||| and shown as a view, for chat logs, game messages and (later) a Markdown
||| viewer. A paragraph carries a prefix for its first line and one for the
||| others, which is all a hanging indent, a list bullet or a quote bar need,
||| and how its text is wrapped. Other formats come in by being turned into a
||| `StyledText`; see `TermUI.Widget.StyledText.Doc` for a pretty-printer
||| `Doc`. The layout needs the width: the program passes it, from the
||| window size it knows, and builds the view again when it changes.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.StyledText

import Data.List
import Data.List1
import Data.String
import TermUI.Kinsoku
import TermUI.Len
import TermUI.Node
import TermUI.Style
import TermUI.Width
import public TermUI.Widget.Span

%default covering

-------------------------------------------------------------------------------
-- The text

||| One paragraph: the text, how it is wrapped, and what starts its first line
||| and each of the others (a bullet and the blanks under it, say).
public export
record Para where
  constructor MkPara
  firstPrefix : List Span
  restPrefix : List Span
  wrapping : Wrap
  body : List Span

public export
StyledText : Type
StyledText = List Para

||| A paragraph of spans, wrapped at words, with no prefix.
public export
paragraph : List Span -> Para
paragraph = MkPara [] [] WrapWords

||| Plain text, a paragraph per line of the string.
public export
plainText : String -> StyledText
plainText s = map (\l => paragraph [MkSpan plain l]) (lines s)

-------------------------------------------------------------------------------
-- Layout

-- A character with its style.
CS : Type
CS = (Char, Style)

widthOf : List CS -> Len
widthOf = sum . map (charWidth . fst)

isSp : CS -> Bool
isSp c = fst c == ' '

cells : List Span -> List CS
cells = concatMap (\s => map (\c => (c, s.spanStyle)) (unpack s.spanText))

-- The cells as spans: runs of one style.
spansOf : List CS -> List Span
spansOf [] = []
spansOf ((c, st) :: rest) =
  let (same, other) = span (\x => snd x == st) rest
  in MkSpan st (pack (c :: map fst same)) :: spansOf other

trimEnd : List CS -> List CS
trimEnd = reverse . dropWhile isSp . reverse

-- The longest start of `cs` that fits in `lim`, at least one character, and
-- shorter where the rest would begin or the start end with a character the
-- line breaking rules forbid there.
takeFit : Len -> List CS -> (List CS, List CS)
takeFit lim cs =
  let (piece, more) = go 0 [] cs
  in if null more then (piece, more)
     else splitAt (holdBack (length piece) (map fst (take (S (length piece)) cs))) cs
  where
    go : Len -> List CS -> List CS -> (List CS, List CS)
    go _ acc [] = (reverse acc, [])
    go w acc (c :: rest) =
      let w' = w + charWidth (fst c)
      in if w' > lim && not (null acc) then (reverse acc, c :: rest) else go w' (c :: acc) rest

-- Cut into pieces of at most `first` cells, then `rest` cells.
cutAt : (first, rest : Len) -> List CS -> List (List CS)
cutAt _ _ [] = []
cutAt first rest cs =
  let (piece, more) = takeFit (max 1 first) cs
  in piece :: cutAt rest rest more

record Wrapping where
  constructor MkWrapping
  done : List (List CS)      -- finished lines, the last one first
  cur : List CS
  curW : Len

-- Greedy wrapping at spaces; a word longer than a line is cut.
wrapWords : (first, rest : Len) -> List CS -> List (List CS)
wrapWords first rest cs = finish (foldl step (MkWrapping [] [] 0) tokens)
  where
    tokens : List (List CS)
    tokens = map forget (groupBy (\a, b => isSp a == isSp b) cs)

    limit : Wrapping -> Len
    limit st = if null st.done then first else rest

    add : List CS -> Len -> Wrapping -> Wrapping
    add tok w st = MkWrapping st.done (st.cur ++ tok) (st.curW + w)

    flushWith : List CS -> Wrapping -> Wrapping
    flushWith p st = MkWrapping (p :: st.done) [] 0

    flush : Wrapping -> Wrapping
    flush st = flushWith (trimEnd st.cur) st

    -- All the pieces but the last are lines; the last goes on.
    joinCut : Wrapping -> List (List CS) -> Wrapping
    joinCut st [] = st
    joinCut st [last] = MkWrapping st.done last (widthOf last)
    joinCut st (p :: ps) = joinCut (flushWith p st) ps

    -- Spaces that start a line stay on the first line only, if they fit.
    -- A word that does not fit drops the blanks before it, goes to the next
    -- line if it fits there and the first line is the narrower one, and is
    -- cut if it fits nowhere.
    step : Wrapping -> List CS -> Wrapping
    step st tok =
      let w = widthOf tok in
      case tok of
        [] => st
        (t :: _) =>
          if isSp t
             then (if null st.cur then (if null st.done && w <= limit st then add tok w st else st)
                   else if st.curW + w <= limit st then add tok w st
                   else flush st)
             else if st.curW + w <= limit st then add tok w st
             else if not (null st.cur) && all isSp st.cur then step (MkWrapping st.done [] 0) tok
             else if null st.cur
                     then (if null st.done && w <= rest && rest > first
                              then step (flushWith [] st) tok
                              else case cutAt (limit st) rest tok of
                                     [] => st
                                     (p :: ps) => joinCut (flushWith p st) ps)
                     else step (flush st) tok

    finish : Wrapping -> List (List CS)
    finish st = reverse (if null st.cur && not (null st.done) then st.done else trimEnd st.cur :: st.done)

wrapLine : Wrap -> (first, rest : Len) -> List CS -> List (List CS)
wrapLine _ _ _ [] = [[]]
wrapLine WrapWords first rest cs = wrapWords first rest cs
wrapLine WrapChars first rest cs = cutAt first rest cs
wrapLine Truncate first _ cs = [fst (takeFit (max 1 first) cs)]

-- Cells split at the `\n`s.
logicalLines : List CS -> List (List CS)
logicalLines cs = forget (split (\c => fst c == '\n') cs)

||| The lines of one paragraph wrapped to `w` cells.
export
layoutPara : Len -> Para -> List (List Span)
layoutPara w p =
  let pf = widthOf (cells p.firstPrefix)
      pr = widthOf (cells p.restPrefix)
      logical = logicalLines (cells p.body)
  in concat (zipWith (line pf pr) [0 .. count logical `monus` 1] logical)
  where
    line : Len -> Len -> Len -> List CS -> List (List Span)
    line pf pr j cs =
      let firstW = (if j == 0 then w `monus` pf else w `monus` pr)
          wrapped = wrapLine p.wrapping firstW (w `monus` pr) cs
      in zipWith (\k, l => (if j == 0 && k == 0 then p.firstPrefix else p.restPrefix) ++ spansOf l)
                 [0 .. count wrapped `monus` 1] wrapped

||| The lines of the text wrapped to `w` cells, each as spans.
export
layoutLines : Len -> StyledText -> List (List Span)
layoutLines w = concatMap (layoutPara (nonneg w))

-------------------------------------------------------------------------------
-- View

||| One line of spans as a row; an empty line is one blank row.
export
lineView : List Span -> Node msg
lineView [] = box [height (Cells 1)] []
lineView ss = row [] (map (\s => Text s.spanStyle Truncate s.spanText) ss)

||| One node per line, wrapped to `w` cells; a scrolling widget can take them.
export
styledLines : Len -> StyledText -> List (Node msg)
styledLines w = map lineView . layoutLines w

||| The text wrapped to `w` cells as a column of lines.
export
styledText : Len -> StyledText -> Node msg
styledText w t = column [] (styledLines w t)

||| The text wrapped to the width the view is placed in, so a resize needs no
||| new view. It is built inside `withWidth`, so see there for what that
||| node cannot do.
export
styledView : StyledText -> Node msg
styledView t = withWidth (\w => styledText w t)
