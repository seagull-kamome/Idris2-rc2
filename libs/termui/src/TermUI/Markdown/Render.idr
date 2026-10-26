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

mutual
  ||| The paragraphs of one block, in a space `avail` cells wide, a list in it
  ||| `depth` lists deep.
  export
  renderBlock : MdTheme -> (depth : Nat) -> (avail : Len) -> Block -> StyledText
  renderBlock th _ _ (Paragraph k) = [MkPara [] [] WrapWords (inlineSpans th th.paragraph k)]
  renderBlock th _ _ (Heading n k) =
    let mark = th.headingMark n
        st = th.heading n
    in [MkPara [spanOf st mark] [spanOf st (blanks (stringWidth mark))] WrapWords
             (inlineSpans th st k)]
  renderBlock th _ avail (CodeBlock lang ls) =
    let w = avail `monus` th.codeIndent
        indent = [spanOf th.codeBlock (blanks th.codeIndent)]
        label = if th.showLang && lang /= ""
                   then [MkPara indent indent WrapChars [spanOf (th.codeLabel `over` th.codeBlock) (codeLine w lang)]]
                   else []
        rows = if null ls && null label then [""] else ls
    in label ++ map (\l => MkPara indent indent WrapChars [spanOf th.codeBlock (codeLine w l)]) rows
  renderBlock th depth avail (Quote bs) =
    let bar = [spanOf th.quoteBarStyle th.quoteBar]
        inner = renderBlocks th depth (avail `monus` stringWidth th.quoteBar) bs
    in everyRow bar (map (\p => { body $= map (\s => { spanStyle := s.spanStyle `over` th.quoteText } s) } p) inner)
  renderBlock th depth avail (Bullets items) =
    let marker = th.bullet depth
    in concat (map (item th depth avail (spanOf th.markerStyle marker) (stringWidth marker)) items)
  renderBlock th depth avail (Numbered start items) =
    let markers = zipWith (\i, _ => th.number (start + i)) [0 .. length items `minus` 1] items
        width = foldl max 0 (map stringWidth markers)
        padded = map (\m => m ++ blanks (width `monus` stringWidth m)) markers
    in concat (zipWith (\m, it => item th depth avail (spanOf th.markerStyle m) width it) padded items)
  renderBlock th _ avail Rule =
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
                    _ => replicate th.gap gapPara
        in sep ++ renderBlock th depth avail b ++ go (b :: before) bs

  ||| The paragraphs of blocks one after the other, `gap` blank rows apart.
  export
  renderBlocks : MdTheme -> (depth : Nat) -> (avail : Len) -> List Block -> StyledText
  renderBlocks th depth avail [] = []
  renderBlocks th depth avail (b :: bs) =
    renderBlock th depth avail b
    ++ concatMap (\x => replicate th.gap gapPara ++ renderBlock th depth avail x) bs

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
