||| The layout EDSL: a view is a tree of `Node`s built from `box` and `text`,
||| tuned with `Prop`s (`box [direction Row, grow 1, padding 1] [...]`).
||| Sizes are in terminal cells. A box's width and height are those of its
||| border box (border and padding included); margins lie outside it.
||| The semantics follow a small subset of CSS flexbox, see
||| libs/termui/doc/design.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Node

import TermUI.Input
import public TermUI.Len
import TermUI.Style

%default total

-------------------------------------------------------------------------------
-- Property types

public export
record Edges where
  constructor MkEdges
  top, right, bottom, left : Len

public export
noEdges : Edges
noEdges = MkEdges 0 0 0 0

public export
data Dim = Auto | Cells Len | Percent Len

public export
data Direction = Row | Column

||| Placement on the cross axis.
public export
data Align = Start | Center | End | Stretch

||| Distribution of leftover space on the main axis.
public export
data Justify = JStart | JCenter | JEnd | JBetween | JAround

public export
data Border = NoBorder | Single | Rounded | DoubleLine | Heavy | Ascii

||| How a text that is wider than its box is handled.
public export
data Wrap = WrapWords | WrapChars | Truncate

public export
record Props where
  constructor MkProps
  pDirection : Direction
  pWidth, pHeight : Dim
  pGrow, pShrink : Len
  pPadding, pMargin : Edges
  pGap : Len
  pBorder : Border
  pBorderStyle : Style
  pStyle : Style
  pAlign : Align
  pJustify : Justify
  pCursor : Bool          -- the real terminal cursor goes to this box
  pTag : Maybe Nat        -- set by the runtime on focusable nodes
  pMinWidth, pMaxWidth, pMinHeight, pMaxHeight : Maybe Len
  pWrap : Bool            -- a row goes on in a new line when its children do not fit
  pAbsolute : Bool        -- out of the flow of its parent, placed by the offsets below
  pTop, pRight, pBottom, pLeft : Maybe Len
  pMarginPct : Edges      -- margins in percent of the width of the parent, added to `pMargin`

public export
defaultProps : Props
defaultProps = MkProps Column Auto Auto 0 1 noEdges noEdges 0 NoBorder plain plain Stretch JStart False Nothing
                       Nothing Nothing Nothing Nothing False False Nothing Nothing Nothing Nothing noEdges

-------------------------------------------------------------------------------
-- Tree

public export
data Node : Type -> Type where
  Text : Style -> Wrap -> String -> Node msg
  Box : Props -> List (Node msg) -> Node msg
  ||| A node the runtime can give the keyboard focus to. The body is built
  ||| knowing whether it has the focus, and the handler sees the keys that
  ||| arrive while it has. Focusables are visited in tree order by Tab and
  ||| Shift+Tab.
  ||| It may have a key (`keyed`): the runtime then finds the focus again by the
  ||| key when focusables appear or disappear before it.
  Focusable : Maybe String -> (focused : Bool -> Node msg) -> (Input -> Maybe msg) -> Node msg

-------------------------------------------------------------------------------
-- Builders

||| A property modifier.
public export
0 Prop : Type
Prop = Props -> Props

public export
box : List Prop -> List (Node msg) -> Node msg
box ps = Box (foldl (flip ($)) defaultProps ps)

public export
direction : Direction -> Prop
direction d p = { pDirection := d } p

public export
row : List Prop -> List (Node msg) -> Node msg
row ps = box (direction Row :: ps)

public export
column : List Prop -> List (Node msg) -> Node msg
column = box

||| Styled text; `\n` starts a new line.
public export
styled : Style -> String -> Node msg
styled s = Text s WrapWords

public export
text : String -> Node msg
text = styled plain

||| An empty box that takes the leftover space.
public export
spacer : Node msg
spacer = Box ({ pGrow := 1 } defaultProps) []

public export
width, height : Dim -> Prop
width d p = { pWidth := d } p
height d p = { pHeight := d } p

public export
grow, shrink : Len -> Prop
grow n p = { pGrow := n } p
shrink n p = { pShrink := n } p

public export
gap : Len -> Prop
gap n p = { pGap := n } p

||| The same padding on all four sides.
public export
padding : Len -> Prop
padding n p = { pPadding := MkEdges n n n n } p

||| Vertical and horizontal padding.
public export
paddingXY : (x : Len) -> (y : Len) -> Prop
paddingXY x y p = { pPadding := MkEdges y x y x } p

public export
margin : Len -> Prop
margin n p = { pMargin := MkEdges n n n n } p

public export
marginXY : (x : Len) -> (y : Len) -> Prop
marginXY x y p = { pMargin := MkEdges y x y x } p

||| Margins in percent of the content width of the parent (on all four sides,
||| as in CSS), added to the margins in cells. A parent that is sized by its
||| children does not count them.
public export
marginPercent : Len -> Prop
marginPercent n p = { pMarginPct := MkEdges n n n n } p

public export
marginPercentXY : (x : Len) -> (y : Len) -> Prop
marginPercentXY x y p = { pMarginPct := MkEdges y x y x } p

public export
border : Border -> Prop
border b p = { pBorder := b } p

public export
borderColor : Color -> Prop
borderColor c p = { pBorderStyle := fgColor c p.pBorderStyle } p

||| The box's own style: its background fills the box and the rest is
||| inherited by the descendants.
public export
style : Style -> Prop
style s p = { pStyle := s } p

public export
align : Align -> Prop
align a p = { pAlign := a } p

public export
justify : Justify -> Prop
justify j p = { pJustify := j } p

||| Text cut at the edge of its box instead of wrapped.
public export
truncated : Style -> String -> Node msg
truncated s = Text s Truncate

||| Text wrapped at any character, not only at spaces.
public export
charWrapped : Style -> String -> Node msg
charWrapped s = Text s WrapChars

||| A node that takes the keyboard focus; see `Focusable`.
public export
focusable : (focused : Bool -> Node msg) -> (Input -> Maybe msg) -> Node msg
focusable = Focusable Nothing

||| Give the focusable at the top of a node a key. The focus stays with the
||| widget of that key when others come or go before it in the tree (without
||| a key the focus is the index of the widget). Keys should differ; a node that
||| is not a focusable is returned as it is.
public export
keyed : String -> Node msg -> Node msg
keyed k (Focusable _ body h) = Focusable (Just k) body h
keyed _ n = n

||| Change the messages of a view; a parent uses it to embed a child's view.
export covering
mapNode : (a -> b) -> Node a -> Node b
mapNode _ (Text s w str) = Text s w str
mapNode f (Box p kids) = Box p (map (mapNode f) kids)
mapNode f (Focusable k body h) = Focusable k (\b => mapNode f (body b)) (\i => map f (h i))

||| Mark the box as the place of the terminal's own cursor: the runtime puts
||| the cursor at its top left corner, which is where an input method shows its
||| candidate window.
public export
cursorHere : Prop
cursorHere p = { pCursor := True } p

||| The border box is at least / at most this many cells wide / high.
public export
minWidth, maxWidth, minHeight, maxHeight : Len -> Prop
minWidth n p = { pMinWidth := Just n } p
maxWidth n p = { pMaxWidth := Just n } p
minHeight n p = { pMinHeight := Just n } p
maxHeight n p = { pMaxHeight := Just n } p

||| A row whose children do not fit in its width goes on in a new line (lines
||| are `gap` apart); a column whose children do not fit in its height goes on
||| in a new column. A wrapping column needs a height (and a width, if it is to
||| be placed by its parent's other children) of its own.
public export
wrapChildren : Prop
wrapChildren p = { pWrap := True } p

||| Take the box out of the flow of its parent: it does not take part in the
||| layout of its siblings and is placed in the content box of its parent by
||| `top`, `right`, `bottom` and `left` (a side not given is free). Boxes drawn
||| later are drawn over it, and over the siblings it overlaps.
public export
absolute : Prop
absolute p = { pAbsolute := True } p

public export
top, right, bottom, left : Len -> Prop
top n p = { pTop := Just n } p
right n p = { pRight := Just n } p
bottom n p = { pBottom := Just n } p
left n p = { pLeft := Just n } p
