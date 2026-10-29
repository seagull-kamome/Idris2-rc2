||| A Markdown viewer: texts shown a window at a time with a scroll bar, in
||| which blocks fold. The texts are segments (a message of a chat, a page):
||| each is read on its own, and the last one can be added to
||| (`extendSegment`), so only that segment is read and laid out again while a
||| reply arrives. Which blocks can be folded, and which start folded, is the
||| theme's (`fold`). A gutter on the left holds a mark on the first row of
||| each block that can be folded (`openMark`, `closedMark`). The units that fold
||| are the blocks of the top level of a segment: a heading folds the blocks
||| up to the next heading of its level or a higher one, or the end of the
||| segment; the others fold into a line. The cursor (`NextUnit`, `PrevUnit`)
||| picks the unit that `Toggle` folds or opens; it is drawn as the mark in
||| reverse (the first row of the unit, if the theme has no marks). A click folds
||| or opens a unit on its mark, on its first row or on any of its rows, as the
||| theme says (`foldClick`). See libs/termui/doc/design.md ("Markdown").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.MarkdownView

import Data.List
import Data.Seq.RC2 as Q
import TermUI.Input
import TermUI.Len
import TermUI.Markdown
import TermUI.Markdown.Render
import TermUI.Markdown.Theme
import TermUI.Node
import TermUI.Style
import TermUI.Width
import TermUI.Widget.Scrolling as Sc
import TermUI.Widget.ScrollBar
import TermUI.Widget.StyledText

%default covering

||| What the viewer is told: scrolling (`TermUI.Widget.Scrolling`), moving the
||| cursor over the blocks that fold, folding or opening the block under it,
||| all of them, and a click at a row and a column of the window.
public export
data ViewMsg
  = Scroll Sc.Msg
  | NextUnit
  | PrevUnit
  | Toggle
  | FoldAll
  | UnfoldAll
  | Click Len Len

-- A segment: its blocks (read from `text` if `isText`, else given), which of
-- them are folded, for how many of them the theme has said whether they start
-- folded, and how many lines it takes.
record Seg where
  constructor MkSeg
  isText : Bool
  text : String
  blocks : List Block
  folded : List Nat
  known : Nat
  nLines : Nat

-- The unit (the segment and the block) that a line belongs to, and whether it is the
-- first line of the unit, where its mark is.
record Owner where
  constructor MkOwn
  unit : (Nat, Nat)
  head : Bool

public export
record Model where
  constructor MkModel
  theme : MdTheme
  rows : Len
  width : Len                       -- the scroll bar included
  segs : Seq Seg
  lines : Seq (List Span)
  owners : Seq (Maybe Owner)        -- the unit a click on the line folds
  top : Len
  follow : Bool
  cursor : Maybe (Nat, Nat)

-------------------------------------------------------------------------------
-- Units

indexed : List a -> List (Nat, a)
indexed = go 0
  where
    go : Nat -> List a -> List (Nat, a)
    go _ [] = []
    go i (x :: xs) = (i, x) :: go (S i) xs

canFold : Fold -> Bool
canFold NoFold = False
canFold _ = True

startsFolded : Fold -> Bool
startsFolded Closed = True
startsFolded _ = False

allKinds : List Kind
allKinds = [KHeading 1, KHeading 2, KHeading 3, KHeading 4, KHeading 5, KHeading 6, KParagraph, KCode, KQuote, KBullets, KNumbered, KRule, KStyled]

-- The gutter is as wide as the marks, and absent if nothing folds.
gutter : MdTheme -> Len
gutter th =
  if any (canFold . th.fold) allKinds then max (stringWidth th.openMark) (stringWidth th.closedMark) else 0

isUnit : MdTheme -> Block -> Bool
isUnit th b = canFold (th.fold (kindOf b))

-- The theme says how the blocks not seen before start.
settleDefaults : MdTheme -> Seg -> Seg
settleDefaults th seg =
  let n = length seg.blocks
      from = min seg.known n
      closed = map fst (filter (\ib => startsFolded (th.fold (kindOf (snd ib)))) (drop from (indexed seg.blocks)))
  in { folded := filter (< n) seg.folded ++ closed, known := n } seg

newSeg : MdTheme -> String -> Seg
newSeg th text = settleDefaults th (MkSeg True text (parse text) [] 0 0)

setLines : Nat -> Seg -> Seg
setLines n seg = { nLines := n } seg

setBlocks : List Block -> Seg -> Seg
setBlocks bs seg = { blocks := bs } seg

setText : String -> Seg -> Seg
setText t seg = { text := t, blocks := parse t } seg

moreBody : List Span -> Para -> Para
moreBody spans p = { body $= (++ spans) } p

givenSeg : MdTheme -> List Block -> Seg
givenSeg th bs = settleDefaults th (MkSeg False "" bs [] 0 0)

-------------------------------------------------------------------------------
-- Layout

textWidth : Len -> Len
textWidth w = w `monus` 1

-- The first line with the colours reversed.
reverseHead : List (List Span) -> List (List Span)
reverseHead [] = []
reverseHead (l :: rest) = map (\sp => { spanStyle := withAttr Inverse sp.spanStyle } sp) l :: rest

-- A block folded: a line, behind its left margin and padding and without the
-- rows of padding. What marks it as folded is part of the line, so that it is
-- wrapped with the rest.
collapsed : MdTheme -> Len -> Block -> StyledText
collapsed th w b = boxAround th (kindOf b) w False (\iw => line iw b)
  where
    line : Len -> Block -> StyledText
    line _ (CodeBlock lang ls) =
      [MkPara [] [] Truncate
         [spanOf (th.foldStyle `over` th.codeBlock) ("``` " ++ lang ++ "  (" ++ show (length ls) ++ " lines)")]]
    line iw blk =
      case renderBare th 0 iw blk of
        [] => []
        (p :: _) => [{ body $= (++ [spanOf th.foldStyle " ..."]) } p]

-- The lines of a segment with the units that a click on them folds: the first
-- line of a unit, where its mark is, and for `OnBlock` the others. A segment
-- after the first starts with the gap.
layoutSeg : MdTheme -> (w : Len) -> (cursor : Maybe (Nat, Nat)) -> (idx : Nat) -> Seg
          -> (List (List Span), List (Maybe Owner))
layoutSeg th w cursor idx seg = go Nothing (if idx > 0 then Just 0 else Nothing) (indexed seg.blocks)
  where
    gw : Len
    gw = gutter th

    contentW : Len
    contentW = w `monus` gw

    markSpan : Bool -> Bool -> Bool -> Span
    markSpan unit isFolded selected =
      if not unit then spanOf plain (blanks gw)
      else let mark = if isFolded then th.closedMark else th.openMark
               padded = mark ++ blanks (gw `monus` stringWidth mark)
           in spanOf (if selected then withAttr Inverse th.foldStyle else th.foldStyle) padded

    -- `before` is the bottom margin of the block shown before, if there is one
    go : (hiding : Maybe Nat) -> (before : Maybe Nat) -> List (Nat, Block)
       -> (List (List Span), List (Maybe Owner))
    go _ _ [] = ([], [])
    go hiding before ((i, b) :: rest) =
      let level = case b of
                    Heading n _ => Just n
                    _ => Nothing
          hidden = case (hiding, level) of
                     (Just h, Just n) => n > h
                     (Just _, Nothing) => True
                     (Nothing, _) => False
      in if hidden then go hiding before rest
         else
           let unit = isUnit th b
               isFolded = unit && elem i seg.folded
               paras = if isFolded then collapsed th contentW b else renderBlock th 0 contentW b
               mark = markSpan unit isFolded (cursor == Just (idx, i))
               blankG = spanOf plain (blanks gw)
               laid = concatMap (layoutPara w) (if gw == 0 then paras else behind [mark] [blankG] paras)
               -- with no gutter the cursor is shown by the first row being reversed
               ls = if gw == 0 && unit && cursor == Just (idx, i) then reverseHead laid else laid
               gapRows = the Nat (case before of
                                    Nothing => marginTop th b
                                    Just pb => max th.gap (max pb (marginTop th b)))
               gapLines = the (List (List Span)) (replicate gapRows [])
               others = if unit && th.foldClick == OnBlock then Just (MkOwn (idx, i) False) else Nothing
               own = (case ls of
                        [] => []
                        (_ :: more) => (if unit then Just (MkOwn (idx, i) True) else Nothing) :: map (const others) more)
               (restLs, restOs) = go (if isFolded then level else Nothing) (Just (marginBottom th b)) rest
           in (gapLines ++ ls ++ restLs, map (const Nothing) gapLines ++ own ++ restOs)

||| The number of lines laid out.
export
lineCount : Model -> Len
lineCount m = cast (Q.length m.lines)

lastTop : Model -> Len
lastTop m = lineCount m `monus` m.rows

-- After the text changed: at the end if the window followed it, else the same
-- line, kept in range.
settle : Model -> Model
settle m =
  let top' : Len
      top' = if m.follow then lastTop m else min m.top (lastTop m)
  in { top := top', follow := top' >= lastTop m } m

-- Every segment laid out again.
layoutAll : Model -> Model
layoutAll m =
  let (ls, os, segs', _) = foldl step (Q.empty, Q.empty, Q.empty, 0) (toList m.segs)
  in { lines := ls, owners := os, segs := segs' } m
  where
    step : (Seq (List Span), Seq (Maybe Owner), Seq Seg, Nat) -> Seg
         -> (Seq (List Span), Seq (Maybe Owner), Seq Seg, Nat)
    step (ls, os, ss, idx) seg =
      let (sl, so) = layoutSeg m.theme (textWidth m.width) m.cursor idx seg
      in (Q.(++) ls (Q.fromList sl), Q.(++) os (Q.fromList so), ss `snoc` setLines (length sl) seg, S idx)

-- The first line of segment `k`, which is `seg`. The last one is found from the
-- number of lines of the log; the others by adding up those before it.
segStart : Nat -> Seg -> Model -> Nat
segStart k seg m =
  if S k == Q.length m.segs
     then Q.length m.lines `minus` seg.nLines
     else foldl (\a, s => a + s.nLines) 0 (toList (Q.take k m.segs))

-- Only segment `k` laid out again, and the lines after it moved.
relayout : Nat -> Model -> Model
relayout k m =
  case Q.index k m.segs of
    Nothing => m
    Just seg =>
      let (sl, so) = layoutSeg m.theme (textWidth m.width) m.cursor k seg
          start = segStart k seg m
          stop = start + seg.nLines
          seg' = setLines (length sl) seg
      in { segs := Q.(++) (Q.take k m.segs) (Q.(++) (Q.singleton seg') (Q.drop (S k) m.segs))
         , lines := Q.(++) (Q.take start m.lines) (Q.(++) (Q.fromList sl) (Q.drop stop m.lines))
         , owners := Q.(++) (Q.take start m.owners) (Q.(++) (Q.fromList so) (Q.drop stop m.owners)) } m

-------------------------------------------------------------------------------
-- The text

||| An empty viewer in a window `rows` high and `width` wide.
export
empty : MdTheme -> (rows, width : Len) -> Model
empty th rows width = MkModel th (nonneg rows) (nonneg width) Q.empty Q.empty Q.empty 0 True Nothing

-- A segment added at the end.
pushSeg : Seg -> Model -> Model
pushSeg seg m =
  let idx = Q.length m.segs
      (sl, so) = layoutSeg m.theme (textWidth m.width) m.cursor idx seg
  in settle ({ segs $= (`snoc` setLines (length sl) seg)
             , lines $= (\ls => Q.(++) ls (Q.fromList sl))
             , owners $= (\os => Q.(++) os (Q.fromList so)) } m)

||| Add a segment of Markdown text at the end.
export
addSegment : String -> Model -> Model
addSegment text m = pushSeg (newSeg m.theme text) m

||| Add text to the end of the last segment if that is Markdown text, else as
||| a segment of its own. Only that segment is read and laid out again.
export
extendSegment : String -> Model -> Model
extendSegment "" m = m
extendSegment more m =
  case Q.viewr m.segs of
    Just (before, seg) =>
      if seg.isText
         then let full = seg.text ++ more
                  seg' = settleDefaults m.theme (setText full seg)
              in settle (relayout (Q.length before) ({ segs := before `snoc` seg' } m))
         else addSegment more m
    Nothing => addSegment more m

||| Add a segment of paragraphs that are given, with the styles, prefixes and
||| wrapping they carry, at the end.
export
addStyled : StyledText -> Model -> Model
addStyled [] m = m
addStyled t m = pushSeg (givenSeg m.theme [Styled t]) m

||| Add a segment of paragraphs made for the width they are shown in (see
||| `TermUI.Widget.StyledText.Doc.fromDoc`), which are made again when the
||| window changes its width.
export
addDoc : (Len -> StyledText) -> Model -> Model
addDoc f m = pushSeg (givenSeg m.theme [StyledDoc f]) m

||| Add spans to the end of the last paragraph of the last segment if that is
||| made of given paragraphs, else as a segment of its own. Only that
||| paragraph is wrapped again.
export
extendStyled : List Span -> Model -> Model
extendStyled spans m =
  case Q.viewr m.segs of
    Just (before, seg) =>
      (case (seg.isText, reverse seg.blocks) of
         (False, Styled ps :: others) =>
           let ps' = case reverse ps of
                       [] => [paragraph spans]
                       (p :: more) => reverse (moreBody spans p :: more)
               seg' = setBlocks (reverse (Styled ps' :: others)) seg
           in settle (relayout (Q.length before) ({ segs := before `snoc` seg' } m))
         _ => addStyled [paragraph spans] m)
    Nothing => addStyled [paragraph spans] m

-------------------------------------------------------------------------------
-- Folding

-- The units on view, in order.
units : Model -> List (Nat, Nat)
units m = mapMaybe (\o => o >>= \w => if w.head then Just w.unit else Nothing) (toList m.owners)

indexOf : Eq a => a -> List a -> Maybe Nat
indexOf x = go 0
  where
    go : Nat -> List a -> Maybe Nat
    go _ [] = Nothing
    go i (y :: ys) = if x == y then Just i else go (S i) ys

lineOf : (Nat, Nat) -> Model -> Maybe Nat
lineOf u m = indexOf (Just u) (map (\o => o >>= \w => if w.head then Just w.unit else Nothing) (toList m.owners))

-- The window shows the line.
reveal : Nat -> Model -> Model
reveal line m =
  let l : Len
      l = cast line
      top' = if l < m.top then l else if l >= m.top + m.rows then (l + 1) `monus` m.rows else m.top
      top'' = min top' (lastTop m)
  in { top := top'', follow := top'' >= lastTop m } m

mapFolded : (List Nat -> List Nat) -> Seg -> Seg
mapFolded f seg = { folded := f seg.folded } seg

-- Segment `s` with `f` applied to the blocks it has folded.
withFolded : Nat -> (List Nat -> List Nat) -> Model -> Model
withFolded s f m =
  case Q.index s m.segs of
    Nothing => m
    Just seg => relayout s ({ segs := Q.(++) (Q.take s m.segs) (Q.(++) (Q.singleton (mapFolded f seg)) (Q.drop (S s) m.segs)) } m)

-- Fold or open a unit, the window keeping the unit at the row it was at.
toggleUnit : (Nat, Nat) -> Model -> Model
toggleUnit (s, i) m =
  let before = lineOf (s, i) m
      m' = withFolded s (\fs => if elem i fs then filter (/= i) fs else i :: fs) m
      shift : Len
      shift = case (before, lineOf (s, i) m') of
                (Just a, Just b) => cast b - cast a
                _ => 0
      top' = max 0 (min (m.top + shift) (lastTop m'))
  in { top := top', follow := m.follow && top' >= lastTop m' } m'

-- Every unit folded, or none.
setAll : Bool -> Model -> Model
setAll fold m =
  let th = m.theme
      segs' = Q.fromList (map (\seg => mapFolded (const (if fold then map fst (filter (isUnit th . snd) (indexed seg.blocks)) else [])) seg) (toList m.segs))
      m' = layoutAll ({ segs := segs' } m)
  in { top := min m'.top (lastTop m'), follow := False } m'

-- The cursor on a unit: only the segments it leaves and enters are laid out again.
setCursor : Maybe (Nat, Nat) -> Model -> Model
setCursor c m =
  let touched = nub (mapMaybe (map fst) [m.cursor, c])
  in foldl (flip relayout) ({ cursor := c } m) touched

-- The cursor on another unit, the window showing it.
moveCursor : Bool -> Model -> Model
moveCursor forward m =
  let us = units m
      -- a cursor on a unit that is out of sight (in a folded section) is none
      cur = case m.cursor of
              Just c => if elem c us then Just c else Nothing
              Nothing => Nothing
      chosen : Maybe (Nat, Nat)
      chosen = case cur of
                 Nothing => if forward then head' us else last' us
                 Just c =>
                   if forward then head' (drop 1 (dropWhile (/= c) us))
                   else last' (takeWhile (/= c) us)
  in case chosen of
       Nothing => m
       Just c =>
         let m' = setCursor (Just c) m
         in maybe m' (\l => reveal l m') (lineOf c m')

-- Whether a click folds the unit: the first line of it or not, in the gutter or
-- not, left of the scroll bar or not.
hits : FoldClick -> (first, inGutter, inText : Bool) -> Bool
hits OnMark first inGutter _ = first && inGutter
hits OnFirstRow first _ inText = first && inText
hits OnBlock _ _ inText = inText

||| Handle a message.
export
update : ViewMsg -> Model -> Model
update (Scroll s) m =
  let top' = scrollTop m.rows (lineCount m) m.top s
  in { top := top', follow := top' >= lastTop m } m
update NextUnit m = moveCursor True m
update PrevUnit m = moveCursor False m
update Toggle m = maybe m (\c => if elem c (units m) then toggleUnit c m else m) m.cursor
update FoldAll m = setAll True m
update UnfoldAll m = setAll False m
update (Click row col) m =
  if row >= m.rows then m
  else case Q.index (cast (m.top + row)) m.owners of
         Just (Just w) =>
           if hits m.theme.foldClick w.head (col < gutter m.theme) (col < textWidth m.width)
              then (let m' = toggleUnit w.unit (setCursor (Just w.unit) m)
                    -- a click on a row below the first one: the unit shrinks to its first
                    -- row, which may be above the window
                    in if w.head then m' else maybe m' (\l => reveal l m') (lineOf w.unit m'))
              else m
         _ => m

||| The same viewer in a window of another size; it is laid out again if the
||| width changed.
export
resize : (rows, width : Len) -> Model -> Model
resize rows width m =
  let m' = { rows := nonneg rows, width := nonneg width } m
      m'' = if m'.width == m.width then m' else layoutAll m'
      top' = if m.follow then lastTop m'' else min m''.top (lastTop m'')
  in { top := top', follow := top' >= lastTop m'' } m''

-------------------------------------------------------------------------------
-- View

||| The window with the scroll bar on its right.
export
view : Model -> Node msg
view m =
  let first = min m.top (lastTop m)
      shown = Q.take (cast m.rows) (Q.drop (cast first) m.lines)
  in box [direction Row, height (Cells m.rows), width (Cells m.width)]
       [ box [grow 1] (map lineView (toList shown))
       , scrollBar m.rows (lineCount m) first
       ]

||| The keys: the scrolling keys, `n` and `p` for the next and previous block
||| that folds, Enter or Space to fold or open the one under the cursor, `-`
||| and `+` to fold and open all.
export
keyMsg : Input -> Maybe ViewMsg
keyMsg (Press key mods) =
  if mods.alt || mods.ctrl then Nothing
  else case key of
         KEnter => Just Toggle
         KChar ' ' => Just Toggle
         KChar 'n' => Just NextUnit
         KChar 'p' => Just PrevUnit
         KChar '-' => Just FoldAll
         KChar '+' => Just UnfoldAll
         KChar '=' => Just UnfoldAll
         _ => Scroll <$> Sc.keyMsg (Press key mods)
keyMsg i = Scroll <$> Sc.keyMsg i

||| The mouse for a viewer whose window has its top left at the cell (`top`,
||| `left`) of the screen: the wheel scrolls and a press of the left button
||| folds or opens a block where the theme's `foldClick` says (by default in
||| the gutter).
export
mouseMsg : (top, left : Len) -> MouseEvent -> Maybe ViewMsg
mouseMsg top left e =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) =>
      if e.row >= top && e.column >= left then Just (Click (e.row `monus` top) (e.column `monus` left)) else Nothing
    _ => Scroll <$> Sc.keyMsg (Mouse e)

||| The viewer as a focusable node, so that the keys and the wheel reach it.
export
viewer : (wrap : ViewMsg -> msg) -> Model -> Node msg
viewer wrap m = focusable (\_ => view m) (\i => map wrap (keyMsg i))
