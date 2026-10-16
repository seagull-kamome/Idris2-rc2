||| The layout engine: places a `Node` tree into a rectangle of cells.
||| Pure and independent of any terminal, so it is tested on its own.
||| Algorithm and its simplifications: libs/termui/doc/design.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Layout

import Data.List
import Data.List1
import Data.Maybe
import Data.Nat
import Data.String
import TermUI.Node
import TermUI.Style
import TermUI.Width

-- Recursion goes through `map` over the children, which the totality
-- checker cannot follow.
%default covering

-------------------------------------------------------------------------------
-- Result

public export
record Rect where
  constructor MkRect
  x, y, w, h : Nat

public export
data Laid
  = LText Rect Style (List String)
  | LBox Rect Props (List Laid)

-------------------------------------------------------------------------------
-- Helpers

ndiv : Nat -> Nat -> Nat
ndiv _ Z = 0
ndiv a n@(S _) = divNatNZ a n ItIsSucc

hEdges, vEdges : Edges -> Nat
hEdges e = e.left + e.right
vEdges e = e.top + e.bottom

borderWidth : Border -> Nat
borderWidth NoBorder = 0
borderWidth _ = 1

||| The content box of a border box: inside border and padding.
export
innerRect : Props -> Rect -> Rect
innerRect p r =
  let bw = borderWidth p.pBorder in
  MkRect (r.x + bw + p.pPadding.left) (r.y + bw + p.pPadding.top)
         (r.w `minus` (2 * bw + hEdges p.pPadding))
         (r.h `minus` (2 * bw + vEdges p.pPadding))

-------------------------------------------------------------------------------
-- Text

takeCells : Nat -> List Char -> (List Char, List Char)
takeCells _ [] = ([], [])
takeCells w (c :: cs) =
  let cw = charWidth c in
  if cw <= w
     then let (a, b) = takeCells (w `minus` cw) cs in (c :: a, b)
     else ([], c :: cs)

charChunks : Nat -> Nat -> List Char -> List (List Char)
charChunks _ Z cs = [cs]
charChunks w (S fuel) cs =
  case takeCells w cs of
    (a, []) => [a]
    ([], c :: rest) => [c] :: charChunks w fuel rest
    (a, b) => a :: charChunks w fuel b

wordChunks : Nat -> Nat -> List Char -> List (List Char)
wordChunks _ Z cs = [cs]
wordChunks w (S fuel) cs =
  case takeCells w cs of
    (a, []) => [a]
    (a, b@(n :: _)) =>
      if n == ' '
         then a :: wordChunks w fuel (dropWhile (== ' ') b)
         else case break (== ' ') (reverse a) of
                (after, _ :: before) =>
                  if all (== ' ') before
                     then hard a b
                     else reverse (dropWhile (== ' ') before)
                            :: wordChunks w fuel (reverse after ++ b)
                _ => hard a b
  where
    hard : List Char -> List Char -> List (List Char)
    hard [] (c :: rest) = [c] :: wordChunks w fuel rest
    hard a b = a :: wordChunks w fuel b

||| The lines of a text laid out in `maxW` cells. A trailing newline does
||| not start a further line.
export
wrapText : Wrap -> Nat -> String -> List String
wrapText wrap maxW s =
  if maxW == 0 then [] else concatMap fit (sourceLines (forget (split (== '\n') s)))
  where
    sourceLines : List String -> List String
    sourceLines ls = if length ls > 1 && last' ls == Just "" then reverse (drop 1 (reverse ls)) else ls

    fit : String -> List String
    fit line =
      let cs = unpack line in
      case wrap of
        Truncate => [pack (fst (takeCells maxW cs))]
        WrapChars => map pack (charChunks maxW (length cs + 1) cs)
        WrapWords => map pack (wordChunks maxW (length cs + 1) cs)

-------------------------------------------------------------------------------
-- Flex distribution

-- `amt` split in proportion to the weights; the remainder goes to the first
-- entries with a non-zero weight.
distribute : Nat -> List Nat -> List Nat
distribute amt ws =
  let tw = sum ws in
  if tw == 0
     then map (const 0) ws
     else let shares = map (\w => ndiv (amt * w) tw) ws in
          spread (amt `minus` sum shares) (zip ws shares)
  where
    spread : Nat -> List (Nat, Nat) -> List Nat
    spread _ [] = []
    spread Z ((_, b) :: xs) = b :: spread Z xs
    spread (S r) ((w, b) :: xs) =
      if w > 0 then (b + 1) :: spread r xs else b :: spread (S r) xs

-- Items that would shrink below zero are fixed at zero and their share of
-- the deficit is redistributed among the others.
shrinkAll : Nat -> Nat -> List (Nat, Nat) -> List Nat
shrinkAll Z _ ks = map fst ks
shrinkAll (S fuel) deficit ks =
  let cuts = distribute deficit (map (\(b, s) => b * s) ks)
      sat = zipWith (\(b, _), c => c > b) ks cuts
  in if not (any id sat)
        then zipWith (\(b, _), c => b `minus` c) ks cuts
        else shrinkAll fuel
               (deficit `minus` sum (map (\((b, _), _) => b) (filter snd (zip ks sat))))
               (zipWith (\k, s => if s then (0, 0) else k) ks sat)

||| Main-axis sizes of the items given `(base, grow, shrink)` and the room.
flex : Nat -> List (Nat, Nat, Nat) -> List Nat
flex room ks =
  let bases = map (\(b, _, _) => b) ks
      tot = sum bases
  in if tot <= room
        then zipWith (+) bases (distribute (room `minus` tot) (map (\(_, g, _) => g) ks))
        else shrinkAll (length ks + 1) (tot `minus` room)
                       (map (\(b, _, s) => (b, s)) ks)

||| Offset of the first item and the extra space before each following one.
justifyOffsets : Justify -> Nat -> Nat -> (Nat, List Nat)
justifyOffsets j free n =
  let none : List Nat
      none = replicate (n `minus` 1) 0
  in case j of
       JStart => (0, none)
       JCenter => (ndiv free 2, none)
       JEnd => (free, none)
       JBetween => if n < 2 then (0, none) else (0, distribute free (replicate (n `minus` 1) 1))
       JAround => let per = ndiv free n in (ndiv per 2, replicate (n `minus` 1) per)

-- Positions along the main axis given the sizes (margin included).
mainPositions : Props -> Nat -> List Nat -> List Nat
mainPositions p room sizes =
  let n = length sizes
      free = room `minus` (sum sizes + p.pGap * (n `minus` 1))
      (start, extras) = justifyOffsets p.pJustify free n
  in go start sizes (map (+ p.pGap) extras)
  where
    go : Nat -> List Nat -> List Nat -> List Nat
    go _ [] _ = []
    go at (s :: ss) steps = at :: go (at + s + fromMaybe 0 (head' steps)) ss (drop 1 steps)

-------------------------------------------------------------------------------
-- Children

record Kid msg where
  constructor MkKid
  node : Node msg
  margin : Edges
  kw, kh : Dim
  kgrow, kshrink : Nat

kidOf : Node msg -> Kid msg
kidOf k@(Text _ _ _) = MkKid k noEdges Auto Auto 0 1
kidOf k@(Box p _) = MkKid k p.pMargin p.pWidth p.pHeight p.pGrow p.pShrink

dimSize : Nat -> Dim -> Maybe Nat
dimSize _ Auto = Nothing
dimSize _ (Cells n) = Just n
dimSize room (Percent q) = Just (ndiv (room * q) 100)

-- Outer widths (margin included) of the children of a row in `iw` cells;
-- `nat` measures a node for a given available width.
rowSizes : (Node msg -> Nat -> (Nat, Nat)) -> Props -> Nat -> List (Kid msg) -> List Nat
rowSizes nat p iw ks =
  let bases = map (\k => hEdges k.margin + fromMaybe (fst (nat k.node (iw `minus` hEdges k.margin)))
                                                     (dimSize iw k.kw)) ks
      room = iw `minus` (p.pGap * (length ks `minus` 1))
  in flex room (zip3 bases (map kgrow ks) (map kshrink ks))

-- Widths (margin excluded) of the children of a column in `iw` cells.
columnWidths : (Node msg -> Nat -> (Nat, Nat)) -> Props -> Nat -> List (Kid msg) -> List Nat
columnWidths nat p iw = map width
  where
    width : Kid msg -> Nat
    width k =
      let mh = hEdges k.margin in
      case dimSize iw k.kw of
        Just n => n
        Nothing => case p.pAlign of
                     Stretch => iw `minus` mh
                     _ => fst (nat k.node (iw `minus` mh))

-------------------------------------------------------------------------------
-- Natural size

-- Size of the border box when at most `maxW` cells of width are available.
natural : Node msg -> Nat -> (Nat, Nat)
natural (Text _ wrap s) maxW =
  let ls = wrapText wrap maxW s in
  (foldl max 0 (map stringWidth ls), length ls)
natural (Box p kids) maxW =
  let bw = borderWidth p.pBorder
      bx = 2 * bw + hEdges p.pPadding
      by = 2 * bw + vEdges p.pPadding
      avail = case p.pWidth of
                Cells n => min n maxW
                _ => maxW
      iw = avail `minus` bx
      ks = map kidOf kids
      gaps = p.pGap * (length ks `minus` 1)
      (cw, ch) = case p.pDirection of
        Row =>
          let sizes = rowSizes natural p iw ks in
          ( sum sizes + gaps
          , foldl max 0 (zipWith (\k, sz =>
              snd (natural k.node (sz `minus` hEdges k.margin)) + vEdges k.margin) ks sizes) )
        Column =>
          let widths = columnWidths natural p iw ks in
          ( foldl max 0 (zipWith (\k, cwid => cwid + hEdges k.margin) ks widths)
          , sum (zipWith (\k, cwid => snd (natural k.node cwid) + vEdges k.margin) ks widths) + gaps )
      w = case p.pWidth of
            Cells k => k
            _ => min maxW (cw + bx)
      h = case p.pHeight of
            Cells k => k
            _ => ch + by
  in (w, h)

-------------------------------------------------------------------------------
-- Placement

crossOffset : Align -> Nat -> Nat
crossOffset Center free = ndiv free 2
crossOffset End free = free
crossOffset _ _ = 0

||| Place a node in the border box `r`.
export
place : Node msg -> Rect -> Laid
place (Text s wrap str) r = LText r s (wrapText wrap r.w str)
place (Box p kids) r =
  let i = innerRect p r
      ks = map kidOf kids
  in LBox r p $ case p.pDirection of
       Row => placeRow p i ks
       Column => placeColumn p i ks
  where
    placeRow : Props -> Rect -> List (Kid msg) -> List Laid
    placeRow p i ks =
      let sizes = rowSizes natural p i.w ks
          xs = mainPositions p i.w sizes
      in zipWith3 (\k, sz, px =>
           let mw = sz `minus` hEdges k.margin
               mv = vEdges k.margin
               ch = case dimSize i.h k.kh of
                      Just n => n
                      Nothing => case p.pAlign of
                                   Stretch => i.h `minus` mv
                                   _ => snd (natural k.node mw)
               off = crossOffset p.pAlign (i.h `minus` (ch + mv))
           in place k.node (MkRect (i.x + px + k.margin.left) (i.y + off + k.margin.top) mw ch))
         ks sizes xs

    placeColumn : Props -> Rect -> List (Kid msg) -> List Laid
    placeColumn p i ks =
      let widths = columnWidths natural p i.w ks
          bases = zipWith (\k, cw => vEdges k.margin + fromMaybe (snd (natural k.node cw))
                                                                 (dimSize i.h k.kh)) ks widths
          room = i.h `minus` (p.pGap * (length ks `minus` 1))
          sizes = flex room (zip3 bases (map kgrow ks) (map kshrink ks))
          ys = mainPositions p i.h sizes
      in zipWith3 (\(k, cw), sz, py =>
           let mh = sz `minus` vEdges k.margin
               off = crossOffset p.pAlign (i.w `minus` (cw + hEdges k.margin))
           in place k.node (MkRect (i.x + off + k.margin.left) (i.y + py + k.margin.top) cw mh))
         (zip ks widths) sizes ys

||| Lay out a view in a screen of `w` x `h` cells.
export
layout : Node msg -> (w : Nat) -> (h : Nat) -> Laid
layout n w h = place n (MkRect 0 0 w h)
