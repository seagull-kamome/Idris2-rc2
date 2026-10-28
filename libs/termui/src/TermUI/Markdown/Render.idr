||| Markdown blocks as styled text, by a theme and for a width. Nesting (quotes,
||| lists) is done with the prefixes of the paragraphs, so wrapping keeps the
||| bar or the indent of the block on every row.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Markdown.Render

import Data.List
import TermUI.Len
import TermUI.Markdown
import TermUI.Markdown.Theme
import TermUI.Node
import TermUI.Style
import TermUI.Width
import TermUI.Widget.StyledText

%default covering

||| The kind of a block, for a theme.
export
kindOf : Block -> Kind
kindOf (Heading n _) = KHeading n
kindOf (Paragraph _) = KParagraph
kindOf (CodeBlock _ _) = KCode
kindOf (Quote _) = KQuote
kindOf (Bullets _) = KBullets
kindOf (Numbered _ _) = KNumbered
kindOf Rule = KRule
kindOf (Styled _) = KStyled
kindOf (StyledDoc _) = KStyled

||| `n` blanks.
export
blanks : Len -> String
blanks n = pack (replicate (cast n) ' ')

-- The text of inlines, without styles.
plainOf : List Inline -> String
plainOf = concatMap one
  where
    one : Inline -> String
    one (IText s) = s
    one (IEmph k) = plainOf k
    one (IStrong k) = plainOf k
    one (IStrike k) = plainOf k
    one (ICode s) = s
    one (ILink k _) = plainOf k
    one IBreak = " "

-- A tab in running text is a blank: it has no width of its own.
spreadTabs : String -> String
spreadTabs s = pack (map (\c => if c == '\t' then ' ' else c) (unpack s))

||| Inlines as spans, over a base style.
export
inlineSpans : MdTheme -> Style -> List Inline -> List Span
inlineSpans th base = concatMap one
  where
    one : Inline -> List Span
    one (IText s) = [spanOf base (spreadTabs s)]
    one (IEmph k) = inlineSpans th (th.emph `over` base) k
    one (IStrong k) = inlineSpans th (th.strong `over` base) k
    one (IStrike k) = inlineSpans th (th.strike `over` base) k
    one (ICode s) = [spanOf (th.inlineCode `over` base) (spreadTabs s)]
    one (ILink k url) =
      inlineSpans th (th.link `over` base) k
      ++ (if th.showUrl && plainOf k /= url then [spanOf (th.linkUrl `over` base) (" (" ++ url ++ ")")] else [])
    one IBreak = [spanOf base "\n"]

-- A paragraph that is a row of nothing.
gapPara : Para
gapPara = MkPara [] [] WrapWords []

-- A line of code with its tabs spread and padded with blanks to `w` cells.
codeLine : Len -> String -> String
codeLine w s =
  let t = pack (concatMap (\c => if c == '\t' then unpack "    " else [c]) (unpack s))
      n = stringWidth t
  in if n < w then t ++ blanks (w `monus` n) else t

||| Every paragraph of a block behind a prefix: `first` for the first row of the
-- first paragraph, `rest` for the others.
export
behind : (first, rest : List Span) -> StyledText -> StyledText
behind _ _ [] = []
behind first rest (p :: ps) =
  { firstPrefix := first ++ p.firstPrefix, restPrefix := rest ++ p.restPrefix } p
  :: map (\q => { firstPrefix := rest ++ q.firstPrefix, restPrefix := rest ++ q.restPrefix } q) ps

-- The same prefix on every row, empty paragraphs too.
everyRow : List Span -> StyledText -> StyledText
everyRow pre = map (\p => { firstPrefix := pre ++ p.firstPrefix, restPrefix := pre ++ p.restPrefix } p)

-- The width of spans.
widthOfSpans : List Span -> Len
widthOfSpans = sum . map (stringWidth . spanText)

-- The edges with no negative size, and none so large that their sum could wrap.
clampEdges : Edges -> Edges
clampEdges e = MkEdges (side e.top) (side e.right) (side e.bottom) (side e.left)
  where
    side : Len -> Len
    side n = min 65535 (nonneg n)

noSpace : Edges -> Bool
noSpace e = e.top <= 0 && e.right <= 0 && e.bottom <= 0 && e.left <= 0

||| The top margin of a block, in rows.
export
marginTop : MdTheme -> Block -> Nat
marginTop th b = cast (clampEdges (th.box (kindOf b)).margin).top

||| The bottom margin of a block, in rows.
export
marginBottom : MdTheme -> Block -> Nat
marginBottom th b = cast (clampEdges (th.box (kindOf b)).margin).bottom

||| The blank rows between two neighbouring blocks: the largest of the theme's
||| `gap` and the margins that face each other.
export
gapBetween : MdTheme -> (prev, next : Block) -> Nat
gapBetween th prev next = max th.gap (max (marginBottom th prev) (marginTop th next))

-- `n` rows of top or bottom padding.
padRows : (vertical : Bool) -> (width : Len) -> Para -> (n : Len) -> StyledText
padRows vertical width row n = if vertical && width > 0 then replicate (cast n) row else []

-- The paragraphs wrapped to `w` cells, one paragraph a row, so that what is on
-- the right of them can be kept free: the row is then padded with `fill` to
-- `full` cells when `paint` is set.
wrapRows : (w : Len) -> (full : Len) -> (paint : Bool) -> (fill : Style) -> StyledText -> StyledText
wrapRows w full paint fill = concatMap (map row . layoutPara w)
  where
    row : List Span -> Para
    row ss =
      let used = widthOfSpans ss
          tail = if paint && full > used then [spanOf fill (blanks (full `monus` used))] else []
      in MkPara [] [] Truncate (ss ++ tail)

||| What `render` makes for the width that is left inside the box of a kind of
||| block in `avail` cells: behind the left margin and padding, with the rows of
||| the top and bottom padding added (not with `vertical` off, for a block shown
||| as one line). A text is wrapped to the width inside the box, and its rows are
||| filled up to the padding when there is padding on the right. Margins and
||| padding that do not leave a cell for the block are not used on the sides.
export
boxAround : MdTheme -> Kind -> (avail : Len) -> (vertical : Bool) -> (Len -> StyledText) -> StyledText
boxAround th k avail vertical render =
  let b = th.box k
  in if noSpace b.margin && noSpace b.padding then render avail
     else
       let m0 = clampEdges b.margin
           p0 = clampEdges b.padding
           roomy = m0.left + m0.right + p0.left + p0.right < avail
           m = if roomy then m0 else { left := 0, right := 0 } m0
           p = if roomy then p0 else { left := 0, right := 0 } p0
           outer = avail `monus` (m.left + m.right)
           inner = outer `monus` (p.left + p.right)
           marginPre = if m.left > 0 then [spanOf plain (blanks m.left)] else []
           pre = marginPre ++ (if p.left > 0 then [spanOf b.fill (blanks p.left)] else [])
           padRow = MkPara marginPre marginPre Truncate [spanOf b.fill (blanks outer)]
           body0 = render inner
           body = if m.right + p.right > 0 then wrapRows inner (inner + p.right) (p.right > 0) b.fill body0 else body0
       in padRows vertical outer padRow p.top ++ (if null pre then body else everyRow pre body)
          ++ padRows vertical outer padRow p.bottom

mutual
  ||| The paragraphs of one block with its margin and padding, in a space
  ||| `avail` cells wide, a list in it `depth` lists deep.
  export
  renderBlock : MdTheme -> (depth : Nat) -> (avail : Len) -> Block -> StyledText
  renderBlock th depth avail b = boxAround th (kindOf b) avail True (\w => renderBare th depth w b)

  ||| The paragraphs of one block without its margin and padding.
  export
  renderBare : MdTheme -> (depth : Nat) -> (avail : Len) -> Block -> StyledText
  renderBare th _ _ (Paragraph k) = [MkPara [] [] WrapWords (inlineSpans th th.paragraph k)]
  renderBare th _ _ (Heading n k) =
    let mark = th.headingMark n
        st = th.heading n
    in [MkPara [spanOf st mark] [spanOf st (blanks (stringWidth mark))] WrapWords
             (inlineSpans th st k)]
  renderBare th _ avail (CodeBlock lang ls) =
    let w = avail `monus` th.codeIndent
        indent = [spanOf th.codeBlock (blanks th.codeIndent)]
        label = if th.showLang && lang /= ""
                   then [MkPara indent indent WrapChars [spanOf (th.codeLabel `over` th.codeBlock) (codeLine w lang)]]
                   else []
        rows = if null ls && null label then [""] else ls
    in label ++ map (\l => MkPara indent indent WrapChars [spanOf th.codeBlock (codeLine w l)]) rows
  renderBare th depth avail (Quote bs) =
    let bar = [spanOf th.quoteBarStyle th.quoteBar]
        inner = renderBlocks th depth (avail `monus` stringWidth th.quoteBar) bs
    in everyRow bar (map (\p => { body $= map (\s => { spanStyle := s.spanStyle `over` th.quoteText } s) } p) inner)
  renderBare th depth avail (Bullets items) =
    let marker = th.bullet depth
    in concat (map (item th depth avail (spanOf th.markerStyle marker) (stringWidth marker)) items)
  renderBare th depth avail (Numbered start items) =
    let markers = zipWith (\i, _ => th.number (start + i)) [0 .. length items `minus` 1] items
        width = foldl max 0 (map stringWidth markers)
        padded = map (\m => m ++ blanks (width `monus` stringWidth m)) markers
    in concat (zipWith (\m, it => item th depth avail (spanOf th.markerStyle m) width it) padded items)
  renderBare _ _ _ (Styled ps) = ps
  renderBare _ _ avail (StyledDoc f) = f avail
  renderBare th _ avail Rule =
    let unit' = max 1 (stringWidth th.rule)
        n = avail `div` unit'
    in [MkPara [] [] Truncate [spanOf th.ruleStyle (concat (replicate (cast (max 1 n)) th.rule))]]

  -- A list item: its blocks behind the marker, a nested list not set apart.
  item : MdTheme -> (depth : Nat) -> (avail : Len) -> Span -> Len -> List Block -> StyledText
  item th depth avail marker width bs =
    let inner = renderItemBlocks th (S depth) (avail `monus` width) bs
    in case inner of
         [] => [MkPara [marker] [spanOf plain (blanks width)] WrapWords []]
         _ => behind [marker] [spanOf plain (blanks width)] inner

  renderItemBlocks : MdTheme -> (depth : Nat) -> (avail : Len) -> List Block -> StyledText
  renderItemBlocks th depth avail = go []
    where
      go : List Block -> List Block -> StyledText
      go _ [] = []
      go before (b :: bs) =
        let sep = case (before, b) of
                    ([], _) => []
                    (_, Bullets _) => []
                    (_, Numbered _ _) => []
                    (prev :: _, _) => replicate (gapBetween th prev b) gapPara
        in sep ++ renderBlock th depth avail b ++ go (b :: before) bs

  ||| The paragraphs of blocks one after the other, `gap` blank rows apart.
  export
  renderBlocks : MdTheme -> (depth : Nat) -> (avail : Len) -> List Block -> StyledText
  renderBlocks th depth avail [] = []
  renderBlocks th depth avail (b :: bs) =
    replicate (marginTop th b) gapPara ++ renderBlock th depth avail b ++ rest b bs
    where
      rest : Block -> List Block -> StyledText
      rest _ [] = []
      rest prev (x :: xs) =
        replicate (gapBetween th prev x) gapPara ++ renderBlock th depth avail x ++ rest x xs

||| A Markdown text as styled text for a width.
export
renderMarkdown : MdTheme -> Len -> String -> StyledText
renderMarkdown th w src = renderBlocks th 0 w (parse src)

||| A Markdown text as a view, wrapped to the width it is placed in.
export
markdown : MdTheme -> String -> Node msg
markdown th src =
  let bs = parse src
  in withWidth (\w => styledText w (renderBlocks th 0 w bs))
