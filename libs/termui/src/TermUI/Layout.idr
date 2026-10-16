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

-- Main-axis sizes of the items given `(base, grow, shrink)` and the room.
flexRaw : Nat -> List (Nat, Nat, Nat) -> List Nat
flexRaw room ks =
  let bases = map (\(b, _, _) => b) ks
      tot = sum bases
  in if tot <= room
        then zipWith (+) bases (distribute (room `minus` tot) (map (\(_, g, _) => g) ks))
        else shrinkAll (length ks + 1) (tot `minus` room)
                       (map (\(b, _, s) => (b, s)) ks)
  where
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


||| Main-axis sizes of the items given `(base, grow, shrink, clamp)` and the room.
||| An item the bounds change is fixed at the size they give, and the room it
||| frees or takes is shared among the others.
flex : Nat -> List (Nat, Nat, Nat, Nat -> Nat) -> List Nat
flex room ks = go (length ks + 1) (map (const Nothing) ks)
  where
    -- the sizes of the items not yet fixed, put among those that are
    spread : List (Maybe Nat) -> List Nat -> List Nat
    spread [] _ = []
    spread (Just n :: fs) free = n :: spread fs free
    spread (Nothing :: fs) (n :: free) = n :: spread fs free
    spread (Nothing :: fs) [] = 0 :: spread fs []

    go : Nat -> List (Maybe Nat) -> List Nat
    go fuel fixed =
      let taken = sum (map (fromMaybe 0) fixed)
          loose = map fst (filter (isNothing . snd) (zip ks fixed))
          sizes = spread fixed (flexRaw (room `minus` taken) (map (\(b, g, sh, _) => (b, g, sh)) loose))
          bad = zipWith3 (\(_, _, _, c), fx, sz => isNothing fx && c sz /= sz) ks fixed sizes
      in case fuel of
           Z => zipWith (\(_, _, _, c), sz => c sz) ks sizes
           S f => if any id bad
                     then go f (zipWith3 (\(_, _, _, c), fx, sz => if isNothing fx && c sz /= sz then Just (c sz) else fx) ks fixed sizes)
                     else sizes

-- Positions along the main axis given the sizes (margin included).
mainPositions : Props -> Nat -> List Nat -> List Nat
mainPositions p room sizes =
  let n = length sizes
      free = room `minus` (sum sizes + p.pGap * (n `minus` 1))
      (start, extras) = justifyOffsets p.pJustify free n
  in go start sizes (map (+ p.pGap) extras)
  where
    -- Offset of the first item and the extra space before each following one.
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

-- A child of a parent whose content is `pw` cells wide.
kidOf : (pw : Nat) -> Node msg -> Kid msg
kidOf _ k@(Text _ _ _) = MkKid k noEdges Auto Auto 0 1 id id
kidOf pw k@(Box p _) =
  MkKid k (MkEdges (pct p.pMargin.top p.pMarginPct.top) (pct p.pMargin.right p.pMarginPct.right)
                   (pct p.pMargin.bottom p.pMarginPct.bottom) (pct p.pMargin.left p.pMarginPct.left))
        p.pWidth p.pHeight p.pGrow p.pShrink
        (clampBy p.pMinWidth p.pMaxWidth) (clampBy p.pMinHeight p.pMaxHeight)
  where
    pct : Nat -> Nat -> Nat
    pct cells percent = cells + ndiv (pw * percent) 100
kidOf pw (Focusable body _) = kidOf pw (body False)

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
      ks = map (kidOf 0) (filter (not . isAbsolute) kids)
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

-- The outer width (margin included) a child gets for the width `sz`, held between its bounds.
outerW : Kid msg -> Nat -> Nat
outerW k sz = hEdges k.margin + k.clampW (sz `minus` hEdges k.margin)

outerH : Kid msg -> Nat -> Nat
outerH k sz = vEdges k.margin + k.clampH (sz `minus` vEdges k.margin)

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
          sizes = flex room (map (\(k, b) => (b, k.kgrow, k.kshrink, outerW k)) ln)
      in zipWith (\(k, _), sz => (k, sz)) ln sizes

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

isCells : Dim -> Bool
isCells (Cells _) = True
isCells _ = False

cellsOf : Dim -> Nat
cellsOf (Cells n) = n
cellsOf _ = 0

mutual
  -- The children of a column that wraps cut into columns of at most `room`
  -- cells high: each child with its width and height (margins included) and
  -- the outer width of the column, which is that of its widest child. The
  -- width of a child is what it wants, and its height what that width needs.
  colLines : Props -> (iw : Nat) -> (room : Nat) -> List (Kid msg) -> List (List (Kid msg, Nat, Nat), Nat)
  colLines p iw room ks =
    map (\ln => (map fst ln, foldl max 0 (map (\(_, w, _) => w) (map fst ln)))) (breakLines p.pGap room sized)
    where
      sized : List ((Kid msg, Nat, Nat), Nat)
      sized = map measure ks
        where
          measure : Kid msg -> ((Kid msg, Nat, Nat), Nat)
          measure k =
            let mh = hEdges k.margin
                cw = k.clampW (fromMaybe (min (iw `minus` mh) (maxContent k.node)) (dimSize iw k.kw))
                h = vEdges k.margin + k.clampH (fromMaybe (snd (natural k.node cw)) (dimSize room k.kh))
            in ((k, cw + mh, h), h)

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
        ks = map (kidOf iw) (filter (not . isAbsolute) kids)
        (cw, ch) = case p.pDirection of
          Row =>
            let lines = rowLines p iw ks
                lineWidth = \ln => sum (map snd ln) + p.pGap * (length ln `minus` 1)
            in ( foldl max 0 (map lineWidth lines)
               , sum (map rowLineHeight lines) + p.pGap * (length lines `minus` 1) )
          Column =>
            if p.pWrap && isCells p.pHeight
               then let cols = colLines p iw (cellsOf p.pHeight `minus` by) ks
                    in (sum (map snd cols) + p.pGap * (length cols `minus` 1), 0)
            else
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

  -- The height of a child of a row that gets `mw` cells of width (margin excluded).
  rowChildHeight : Kid msg -> Nat -> Nat
  rowChildHeight k mw =
    k.clampH $ case k.kh of
      Cells n => n
      _ => snd (natural k.node mw)

  -- The height of a line of a row: its tallest child with margins.
  rowLineHeight : List (Kid msg, Nat) -> Nat
  rowLineHeight ln =
    foldl max 0 (map (\(k, sz) => rowChildHeight k (sz `minus` hEdges k.margin) + vEdges k.margin) ln)

-------------------------------------------------------------------------------
-- Placement

crossOffset : Align -> Nat -> Nat
crossOffset Center free = ndiv free 2
crossOffset End free = free
crossOffset _ _ = 0

mutual
  -- Where a box out of the flow goes in the content box `i` of its parent.
  placeAbsolute : Rect -> Node msg -> Laid
  placeAbsolute i (Focusable body _) = placeAbsolute i (body False)
  placeAbsolute i node@(Box p _) =
    let k = kidOf i.w node
        side = \a, b => fromMaybe 0 a + fromMaybe 0 b
        freeW = i.w `minus` (side p.pLeft p.pRight + hEdges k.margin)
        freeH = i.h `minus` (side p.pTop p.pBottom + vEdges k.margin)
        stretchedW = isJust p.pLeft && isJust p.pRight
        stretchedH = isJust p.pTop && isJust p.pBottom
        w = k.clampW $ case dimSize i.w p.pWidth of
              Just n => n
              Nothing => if stretchedW then freeW else min freeW (maxContent node)
        h = k.clampH $ case dimSize i.h p.pHeight of
              Just n => n
              Nothing => if stretchedH then freeH else min freeH (snd (natural node w))
        x = case (p.pLeft, p.pRight) of
              (Just l, _) => l + k.margin.left
              (Nothing, Just r) => i.w `minus` (w + r + k.margin.right)
              _ => k.margin.left
        y = case (p.pTop, p.pBottom) of
              (Just t, _) => t + k.margin.top
              (Nothing, Just b) => i.h `minus` (h + b + k.margin.bottom)
              _ => k.margin.top
    in place node (MkRect (i.x + x) (i.y + y) w h)
  placeAbsolute i node@(Text _ _ _) = place node i
  
  ||| Place a node in the border box `r`.
  export
  place : Node msg -> Rect -> Laid
  place (Text s wrap str) r = LText r s (wrapText wrap r.w str)
  place (Focusable body _) r = place (body False) r
  place (Box p kids) r =
    let i = innerRect p r
        ks = map (kidOf i.w) (filter (not . isAbsolute) kids)
        flowing = case p.pDirection of
                    Row => placeRow p i ks
                    Column => if p.pWrap then placeColumnWrap p i ks else placeColumn p i ks
    in LBox r p (flowing ++ map (placeAbsolute i) (filter isAbsolute kids))

  placeRow : Props -> Rect -> List (Kid msg) -> List Laid
  placeRow p i ks =
    let lines = rowLines p i.w ks
        heightOf = \ln => if p.pWrap then rowLineHeight ln else i.h
        heights = map heightOf lines
    in concat (zipWith3 (placeLine p i) lines heights (lineTops p.pGap 0 heights))
    where
      -- The top of each line of a wrapping row, `gap` apart.
      lineTops : (gap : Nat) -> (y : Nat) -> List Nat -> List Nat
      lineTops _ _ [] = []
      lineTops gap y (lh :: rest) = y :: lineTops gap (y + lh + gap) rest


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
        sizes = flex room (zipWith (\k, b => (b, k.kgrow, k.kshrink, outerH k)) ks bases)
        ys = mainPositions p i.h sizes
    in zipWith3 (\(k, cw), sz, py =>
         let mh = sz `minus` vEdges k.margin
             off = crossOffset p.pAlign (i.w `minus` (cw + hEdges k.margin))
         in place k.node (MkRect (i.x + off + k.margin.left) (i.y + py + k.margin.top) cw mh))
       (zip ks widths) sizes ys

  -- A column that wraps: the columns go on to the right, `gap` apart, each as
  -- wide as its widest child; a column is distributed and justified by itself.
  placeColumnWrap : Props -> Rect -> List (Kid msg) -> List Laid
  placeColumnWrap p i ks =
    let cols = colLines p i.w i.h ks
        xs = colStarts 0 (map snd cols)
    in concat (zipWith placeCol cols xs)
    where
      colStarts : Nat -> List Nat -> List Nat
      colStarts _ [] = []
      colStarts x (cw :: rest) = x :: colStarts (x + cw + p.pGap) rest

      placeCol : (List (Kid msg, Nat, Nat), Nat) -> Nat -> List Laid
      placeCol (items, cw) x0 =
        let room = i.h `minus` (p.pGap * (length items `minus` 1))
            sizes = flex room (map (\(k, _, h) => (h, k.kgrow, k.kshrink, outerH k)) items)
            ys = mainPositions p i.h sizes
            widths = columnWidths p cw (map (\(k, _, _) => k) items)
        in zipWith3 (\((k, _, _), sz), wd, py =>
             let off = crossOffset p.pAlign (cw `minus` (wd + hEdges k.margin))
             in place k.node (MkRect (i.x + x0 + off + k.margin.left) (i.y + py + k.margin.top)
                                     wd (sz `minus` vEdges k.margin)))
           (zip items sizes) widths ys

||| Lay out a view in a screen of `w` x `h` cells.
export
layout : Node msg -> (w : Nat) -> (h : Nat) -> Laid
layout n w h = place n (MkRect 0 0 w h)
