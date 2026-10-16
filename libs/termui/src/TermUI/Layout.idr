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

-- The lines of a text; a trailing newline does not start a further line.
textLines : String -> List String
textLines s =
  let ls = forget (split (== '\n') s) in
  if length ls > 1 && last' ls == Just "" then reverse (drop 1 (reverse ls)) else ls

||| The lines of a text laid out in `maxW` cells.
export
wrapText : Wrap -> Nat -> String -> List String
wrapText wrap maxW s =
  if maxW == 0 then [] else concat (map fit (textLines s))
  where
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

-- `n` held between the bounds; the maximum is applied first, so the minimum wins.
clampBy : Maybe Nat -> Maybe Nat -> Nat -> Nat
clampBy lo hi n = maybe id max lo (maybe id min hi n)

record Kid msg where
  constructor MkKid
  node : Node msg
  margin : Edges
  kw, kh : Dim
  kgrow, kshrink : Nat
  clampW, clampH : Nat -> Nat

kidOf : Node msg -> Kid msg
kidOf k@(Text _ _ _) = MkKid k noEdges Auto Auto 0 1 id id
kidOf k@(Box p _) =
  MkKid k p.pMargin p.pWidth p.pHeight p.pGrow p.pShrink
        (clampBy p.pMinWidth p.pMaxWidth) (clampBy p.pMinHeight p.pMaxHeight)
kidOf (Focusable body _) = kidOf (body False)

-- Out of the flow of its parent?
isAbsolute : Node msg -> Bool
isAbsolute (Box p _) = p.pAbsolute
isAbsolute (Focusable body _) = isAbsolute (body False)
isAbsolute _ = False

-- The width a node wants when nothing limits it, text not wrapped: the
-- width of the border box. Linear in the size of the subtree, and what the
-- layout uses to decide widths, so that `natural` calls each child once.
maxContent : Node msg -> Nat
maxContent (Focusable body _) = maxContent (body False)
maxContent (Text _ _ s) = foldl max 0 (map stringWidth (textLines s))
maxContent (Box p kids) =
  let bx = 2 * borderWidth p.pBorder + hEdges p.pPadding
      ks = map kidOf (filter (not . isAbsolute) kids)
      wants = map (\k => maxContent k.node + hEdges k.margin) ks
      gaps = p.pGap * (length ks `minus` 1)
      content = case p.pDirection of
                  Row => sum wants + gaps
                  Column => foldl max 0 wants
      w = case p.pWidth of
            Cells n => n
            _ => content + bx
  in clampBy p.pMinWidth p.pMaxWidth w

dimSize : Nat -> Dim -> Maybe Nat
dimSize _ Auto = Nothing
dimSize _ (Cells n) = Just n
dimSize room (Percent q) = Just (ndiv (room * q) 100)

-- The items cut into lines of at most `room` cells, `gap` cells apart.
breakLines : Nat -> Nat -> List (a, Nat) -> List (List (a, Nat))
breakLines gap room items = go items [] 0
  where
    go : List (a, Nat) -> List (a, Nat) -> Nat -> List (List (a, Nat))
    go [] cur _ = if null cur then [] else [reverse cur]
    go (x :: rest) [] _ = go rest [x] (snd x)
    go (x :: rest) cur used =
      if used + gap + snd x > room
         then reverse cur :: go (x :: rest) [] 0
         else go rest (x :: cur) (used + gap + snd x)

-- The children of a row cut into lines (one line, unless it wraps), each
-- with its outer width after the distribution of the room of its line.
rowLines : Props -> Nat -> List (Kid msg) -> List (List (Kid msg, Nat))
rowLines p iw ks =
  let based = map (\k => (k, hEdges k.margin
                              + k.clampW (fromMaybe (min (iw `minus` hEdges k.margin) (maxContent k.node))
                                                    (dimSize iw k.kw)))) ks
      lines = if p.pWrap then breakLines p.pGap iw based else [based]
  in map distribute' lines
  where
    distribute' : List (Kid msg, Nat) -> List (Kid msg, Nat)
    distribute' ln =
      let room = iw `minus` (p.pGap * (length ln `minus` 1))
          sizes = flex room (map (\(k, b) => (b, k.kgrow, k.kshrink)) ln)
      in zipWith (\(k, _), sz => (k, hEdges k.margin + k.clampW (sz `minus` hEdges k.margin))) ln sizes

-- The height of a child of a row that gets `mw` cells of width (margin excluded).
rowChildHeight : (Node msg -> Nat -> (Nat, Nat)) -> Kid msg -> Nat -> Nat
rowChildHeight nat k mw = k.clampH (fromMaybe (snd (nat k.node mw)) (dimSize 0 k.kh `orElse` natural' k))
  where
    -- a percentage has no meaning before the height of the row is known
    natural' : Kid msg -> Maybe Nat
    natural' kid = case kid.kh of
                     Cells n => Just n
                     _ => Nothing
    orElse : Maybe a -> Maybe a -> Maybe a
    orElse (Just x) _ = Just x
    orElse Nothing y = y

-- Widths (margin excluded) of the children of a column in `iw` cells.
columnWidths : Props -> Nat -> List (Kid msg) -> List Nat
columnWidths p iw = map width
  where
    width : Kid msg -> Nat
    width k =
      let mh = hEdges k.margin in
      k.clampW $ case dimSize iw k.kw of
        Just n => n
        Nothing => case p.pAlign of
                     Stretch => iw `minus` mh
                     _ => min (iw `minus` mh) (maxContent k.node)

-------------------------------------------------------------------------------
-- Natural size

-- Size of the border box when at most `maxW` cells of width are available.
-- A `Focusable` is laid out as its unfocused body; the runtime resolves
-- focusables (`TermUI.Program`) before the layout sees them. Children out of
-- the flow take no room.
natural : Node msg -> Nat -> (Nat, Nat)
natural (Focusable body _) maxW = natural (body False) maxW
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
      ks = map kidOf (filter (not . isAbsolute) kids)
      (cw, ch) = case p.pDirection of
        Row =>
          let lines = rowLines p iw ks
              lineWidth = \ln => sum (map snd ln) + p.pGap * (length ln `minus` 1)
              lineHeight = \ln => foldl max 0 (map (\(k, sz) =>
                              rowChildHeight natural k (sz `minus` hEdges k.margin) + vEdges k.margin) ln)
          in ( foldl max 0 (map lineWidth lines)
             , sum (map lineHeight lines) + p.pGap * (length lines `minus` 1) )
        Column =>
          -- The width of a column is that of its widest child; the height of
          -- a child is measured at the width it will receive.
          let widths = columnWidths p iw ks
              wanted = map (\k => maxContent k.node + hEdges k.margin) ks
          in ( foldl max 0 wanted
             , sum (zipWith (\k, cwid => k.clampH (snd (natural k.node cwid)) + vEdges k.margin) ks widths)
               + p.pGap * (length ks `minus` 1) )
      w = case p.pWidth of
            Cells k => k
            _ => min maxW (cw + bx)
      h = case p.pHeight of
            Cells k => k
            _ => ch + by
  in (clampBy p.pMinWidth p.pMaxWidth w, clampBy p.pMinHeight p.pMaxHeight h)

-------------------------------------------------------------------------------
-- Placement

crossOffset : Align -> Nat -> Nat
crossOffset Center free = ndiv free 2
crossOffset End free = free
crossOffset _ _ = 0

-- The top of each line of a wrapping row, `gap` apart.
lineTops : (gap : Nat) -> (y : Nat) -> List Nat -> List Nat
lineTops _ _ [] = []
lineTops gap y (lh :: rest) = y :: lineTops gap (y + lh + gap) rest

mutual
  -- Where a box out of the flow goes in the content box `i` of its parent.
  placeAbsolute : Rect -> Node msg -> Laid
  placeAbsolute i (Focusable body _) = placeAbsolute i (body False)
  placeAbsolute i node@(Box p _) =
    let k = kidOf node
        side = \a, b => fromMaybe 0 a + fromMaybe 0 b
        freeW = i.w `minus` side p.pLeft p.pRight
        freeH = i.h `minus` side p.pTop p.pBottom
        stretchedW = isJust p.pLeft && isJust p.pRight
        stretchedH = isJust p.pTop && isJust p.pBottom
        w = k.clampW $ case dimSize i.w p.pWidth of
              Just n => n
              Nothing => if stretchedW then freeW else min freeW (fst (natural node freeW))
        h = k.clampH $ case dimSize i.h p.pHeight of
              Just n => n
              Nothing => if stretchedH then freeH else min freeH (snd (natural node w))
        x = case (p.pLeft, p.pRight) of
              (Just l, _) => l
              (Nothing, Just r) => i.w `minus` (w + r)
              _ => 0
        y = case (p.pTop, p.pBottom) of
              (Just t, _) => t
              (Nothing, Just b) => i.h `minus` (h + b)
              _ => 0
    in place node (MkRect (i.x + x) (i.y + y) w h)
  placeAbsolute i node = place node i

  ||| Place a node in the border box `r`.
  export
  place : Node msg -> Rect -> Laid
  place (Text s wrap str) r = LText r s (wrapText wrap r.w str)
  place (Focusable body _) r = place (body False) r
  place (Box p kids) r =
    let i = innerRect p r
        ks = map kidOf (filter (not . isAbsolute) kids)
        flowing = case p.pDirection of
                    Row => placeRow p i ks
                    Column => placeColumn p i ks
    in LBox r p (flowing ++ map (placeAbsolute i) (filter isAbsolute kids))

  placeRow : Props -> Rect -> List (Kid msg) -> List Laid
  placeRow p i ks =
    let lines = rowLines p i.w ks
        heightOf = \ln => if p.pWrap
                             then foldl max 0 (map (\(k, sz) =>
                                    rowChildHeight natural k (sz `minus` hEdges k.margin) + vEdges k.margin) ln)
                             else i.h
        heights = map heightOf lines
    in concat (zipWith3 (placeLine p i) lines heights (lineTops p.pGap 0 heights))

  placeLine : Props -> Rect -> List (Kid msg, Nat) -> Nat -> Nat -> List Laid
  placeLine p i ln lh y0 =
    let sizes = map snd ln
        xs = mainPositions p i.w sizes
    in zipWith (\(k, sz), px =>
         let mw = sz `minus` hEdges k.margin
             mv = vEdges k.margin
             ch = k.clampH $ case dimSize lh k.kh of
                    Just n => n
                    Nothing => case p.pAlign of
                                 Stretch => lh `minus` mv
                                 _ => snd (natural k.node mw)
             off = crossOffset p.pAlign (lh `minus` (ch + mv))
         in place k.node (MkRect (i.x + px + k.margin.left) (i.y + y0 + off + k.margin.top) mw ch))
       ln xs

  placeColumn : Props -> Rect -> List (Kid msg) -> List Laid
  placeColumn p i ks =
    let widths = columnWidths p i.w ks
        bases = zipWith (\k, cw => vEdges k.margin
                                     + k.clampH (fromMaybe (snd (natural k.node cw)) (dimSize i.h k.kh))) ks widths
        room = i.h `minus` (p.pGap * (length ks `minus` 1))
        sizes = flex room (zip3 bases (map kgrow ks) (map kshrink ks))
        ys = mainPositions p i.h sizes
    in zipWith3 (\(k, cw), sz, py =>
         let mh = k.clampH (sz `minus` vEdges k.margin)
             off = crossOffset p.pAlign (i.w `minus` (cw + hEdges k.margin))
         in place k.node (MkRect (i.x + off + k.margin.left) (i.y + py + k.margin.top) cw mh))
       (zip ks widths) sizes ys

||| Lay out a view in a screen of `w` x `h` cells.
export
layout : Node msg -> (w : Nat) -> (h : Nat) -> Laid
layout n w h = place n (MkRect 0 0 w h)
