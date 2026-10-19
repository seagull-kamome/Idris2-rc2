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
import TermUI.Len
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
  x, y, w, h : Len

public export
data Laid
  = LText Rect Style (List String)
  | LBox Rect Props (List Laid)

-------------------------------------------------------------------------------
-- Helpers

ndiv : Len -> Len -> Len
ndiv a n = if n <= 0 then 0 else a `div` n

hEdges, vEdges : Edges -> Len
hEdges e = e.left + e.right
vEdges e = e.top + e.bottom

borderWidth : Border -> Len
borderWidth NoBorder = 0
borderWidth _ = 1

||| The content box of a border box: inside border and padding.
export
innerRect : Props -> Rect -> Rect
innerRect p r =
  let bw = borderWidth p.pBorder in
  MkRect (r.x + bw + p.pPadding.left) (r.y + bw + p.pPadding.top)
         (r.w `monus` (2 * bw + hEdges p.pPadding))
         (r.h `monus` (2 * bw + vEdges p.pPadding))

-------------------------------------------------------------------------------
-- Text

-- The lines of a text; a trailing newline does not start a further line.
textLines : String -> List String
textLines s =
  let ls = forget (split (== '\n') s) in
  if length ls > 1 && last' ls == Just "" then reverse (drop 1 (reverse ls)) else ls

-- What the row at the start of some characters is: the last one, or one that
-- is cut off after `consumed` characters (more than the row itself keeps when
-- the spaces at the break are dropped), at least one.
data RowCut = Last (List Char) | Cut (List Char) Nat

||| The lines of a text laid out in `maxW` cells.
export
wrapText : Wrap -> Len -> String -> List String
wrapText wrap maxW s =
  if maxW == 0 then [] else concat (map fit (textLines s))
  where
    takeCells : Len -> List Char -> (List Char, List Char)
    takeCells _ [] = ([], [])
    takeCells w (c :: cs) =
      let cw = charWidth c in
      if cw <= w
         then let (a, b) = takeCells (w `monus` cw) cs in (c :: a, b)
         else ([], c :: cs)

    -- The rows of a text: `cut` says where the row at the start of the
    -- characters ends. The characters are walked once, skipping those of the row
    -- begun before, so that the recursion is on the tail. When no character is
    -- left after a row there is one more, empty, row.
    chunks : (cut : List Char -> RowCut) -> List Char -> List (List Char)
    chunks cut cs = go cs 0
      where
        go : List Char -> (skip : Nat) -> List (List Char)
        go [] Z = [[]]
        go [] (S _) = []
        go (_ :: xs) (S k) = go xs k
        go rest@(_ :: xs) Z =
          case cut rest of
            Last a => [a]
            Cut a n => a :: go xs (n `minus` 1)

    charCut : Len -> List Char -> RowCut
    charCut w rest =
      case takeCells w rest of
        (a, []) => Last a
        ([], c :: _) => Cut [c] 1
        (a, _) => Cut a (length a)

    wordCut : Len -> List Char -> RowCut
    wordCut w rest =
      case takeCells w rest of
        (a, []) => Last a
        (a, b@(n :: _)) =>
          if n == ' '
             then Cut a (length a + length (takeWhile (== ' ') b))
             else case break (== ' ') (reverse a) of
                    (after, _ :: before) =>
                      if all (== ' ') before
                         then hard a b
                         else Cut (reverse (dropWhile (== ' ') before)) (length a `minus` length after)
                    _ => hard a b
      where
        hard : List Char -> List Char -> RowCut
        hard [] (c :: _) = Cut [c] 1
        hard a _ = Cut a (length a)

    fit : String -> List String
    fit line =
      let cs = unpack line in
      case wrap of
        Truncate => [pack (fst (takeCells maxW cs))]
        WrapChars => map pack (chunks (charCut maxW) cs)
        WrapWords => map pack (chunks (wordCut maxW) cs)

-------------------------------------------------------------------------------
-- Flex distribution

-- `amt` split in proportion to the weights; the remainder goes to the first
-- entries with a non-zero weight.
distribute : Len -> List Len -> List Len
distribute amt ws =
  let tw = sum ws in
  if tw == 0
     then map (const 0) ws
     else let shares = map (\w => ndiv (amt * w) tw) ws in
          spread (amt `monus` sum shares) (zip ws shares)
  where
    spread : Len -> List (Len, Len) -> List Len
    spread _ [] = []
    spread r ((w, b) :: xs) =
      if r > 0 && w > 0 then (b + 1) :: spread (r - 1) xs else b :: spread r xs

-- Main-axis sizes of the items given `(base, grow, shrink)` and the room.
flexRaw : Len -> List (Len, Len, Len) -> List Len
flexRaw room ks =
  let bases = map (\(b, _, _) => b) ks
      tot = sum bases
  in if tot <= room
        then zipWith (+) bases (distribute (room `monus` tot) (map (\(_, g, _) => g) ks))
        else shrinkAll (length ks + 1) (tot `monus` room)
                       (map (\(b, _, s) => (b, s)) ks)
  where
    -- Items that would shrink below zero are fixed at zero and their share of
    -- the deficit is redistributed among the others.
    shrinkAll : Nat -> Len -> List (Len, Len) -> List Len
    shrinkAll Z _ ks = map fst ks
    shrinkAll (S fuel) deficit ks =
      let cuts = distribute deficit (map (\(b, s) => b * s) ks)
          sat = zipWith (\(b, _), c => c > b) ks cuts
      in if not (any id sat)
            then zipWith (\(b, _), c => b `monus` c) ks cuts
            else shrinkAll fuel
                   (deficit `monus` sum (map (\((b, _), _) => b) (filter snd (zip ks sat))))
                   (zipWith (\k, s => if s then (0, 0) else k) ks sat)


||| Main-axis sizes of the items given `(base, grow, shrink, clamp)` and the room.
||| An item the bounds change is fixed at the size they give, and the room it
||| frees or takes is shared among the others.
flex : Len -> List (Len, Len, Len, Len -> Len) -> List Len
flex room ks = go (length ks + 1) (map (const Nothing) ks)
  where
    -- the sizes of the items not yet fixed, put among those that are
    spread : List (Maybe Len) -> List Len -> List Len
    spread [] _ = []
    spread (Just n :: fs) free = n :: spread fs free
    spread (Nothing :: fs) (n :: free) = n :: spread fs free
    spread (Nothing :: fs) [] = 0 :: spread fs []

    go : Nat -> List (Maybe Len) -> List Len
    go fuel fixed =
      let taken = sum (map (fromMaybe 0) fixed)
          loose = map fst (filter (isNothing . snd) (zip ks fixed))
          sizes = spread fixed (flexRaw (room `monus` taken) (map (\(b, g, sh, _) => (b, g, sh)) loose))
          bad = zipWith3 (\(_, _, _, c), fx, sz => isNothing fx && c sz /= sz) ks fixed sizes
      in case fuel of
           Z => zipWith (\(_, _, _, c), sz => c sz) ks sizes
           S f => if any id bad
                     then go f (zipWith3 (\(_, _, _, c), fx, sz => if isNothing fx && c sz /= sz then Just (c sz) else fx) ks fixed sizes)
                     else sizes

-- Positions along the main axis given the sizes (margin included).
mainPositions : Props -> Len -> List Len -> List Len
mainPositions p room sizes =
  let n = length sizes
      free = room `monus` (sum sizes + p.pGap * (count sizes `monus` 1))
      (start, extras) = justifyOffsets p.pJustify free n
  in go start sizes (map (+ p.pGap) extras)
  where
    -- Offset of the first item and the extra space before each following one.
    justifyOffsets : Justify -> Len -> Nat -> (Len, List Len)
    justifyOffsets j free n =
      let none : List Len
          none = replicate (n `minus` 1) 0
      in case j of
           JStart => (0, none)
           JCenter => (ndiv free 2, none)
           JEnd => (free, none)
           JBetween => if n < 2 then (0, none) else (0, distribute free (replicate (n `minus` 1) 1))
           JAround => let per = ndiv free (cast n) in (ndiv per 2, replicate (n `minus` 1) per)

    go : Len -> List Len -> List Len -> List Len
    go _ [] _ = []
    go at (s :: ss) steps = at :: go (at + s + fromMaybe 0 (head' steps)) ss (drop 1 steps)

-------------------------------------------------------------------------------
-- Children

-- `n` held between the bounds; the maximum is applied first, so the minimum wins.
clampBy : Maybe Len -> Maybe Len -> Len -> Len
clampBy lo hi n = maybe id max lo (maybe id min hi n)

record Kid msg where
  constructor MkKid
  node : Node msg
  margin : Edges
  kw, kh : Dim
  kgrow, kshrink : Len
  clampW, clampH : Len -> Len

-- A child of a parent whose content is `pw` cells wide.
kidOf : (pw : Len) -> Node msg -> Kid msg
kidOf _ k@(Text _ _ _) = MkKid k noEdges Auto Auto 0 1 id id
kidOf pw k@(Box p _) =
  MkKid k (MkEdges (pct p.pMargin.top p.pMarginPct.top) (pct p.pMargin.right p.pMarginPct.right)
                   (pct p.pMargin.bottom p.pMarginPct.bottom) (pct p.pMargin.left p.pMarginPct.left))
        p.pWidth p.pHeight p.pGrow p.pShrink
        (clampBy p.pMinWidth p.pMaxWidth) (clampBy p.pMinHeight p.pMaxHeight)
  where
    pct : Len -> Len -> Len
    pct cells percent = cells + ndiv (pw * percent) 100
kidOf pw (Focusable _ body _) = kidOf pw (body False)

isAbsolute : Node msg -> Bool
isAbsolute (Box p _) = p.pAbsolute
isAbsolute (Focusable _ body _) = isAbsolute (body False)
isAbsolute _ = False

-- The width a node wants when nothing limits it, text not wrapped: the
-- width of the border box. Linear in the size of the subtree, and what the
-- layout uses to decide widths, so that `natural` calls each child once.
maxContent : Node msg -> Len
maxContent (Focusable _ body _) = maxContent (body False)
maxContent (Text _ _ s) = foldl max 0 (map stringWidth (textLines s))
maxContent (Box p kids) =
  let bx = 2 * borderWidth p.pBorder + hEdges p.pPadding
      ks = map (kidOf 0) (filter (not . isAbsolute) kids)
      wants = map (\k => maxContent k.node + hEdges k.margin) ks
      gaps = p.pGap * (count ks `monus` 1)
      content = case p.pDirection of
                  Row => sum wants + gaps
                  Column => foldl max 0 wants
      w = case p.pWidth of
            Cells n => n
            _ => content + bx
  in clampBy p.pMinWidth p.pMaxWidth w

dimSize : Len -> Dim -> Maybe Len
dimSize _ Auto = Nothing
dimSize _ (Cells n) = Just n
dimSize room (Percent q) = Just (ndiv (room * q) 100)

-- The outer width (margin included) a child gets for the width `sz`, held between its bounds.
outerW : Kid msg -> Len -> Len
outerW k sz = hEdges k.margin + k.clampW (sz `monus` hEdges k.margin)

outerH : Kid msg -> Len -> Len
outerH k sz = vEdges k.margin + k.clampH (sz `monus` vEdges k.margin)

-- The items cut into lines of at most `room` cells, `gap` cells apart.
breakLines : Len -> Len -> List (a, Len) -> List (List (a, Len))
breakLines gap room items = go items [] 0
  where
    go : List (a, Len) -> List (a, Len) -> Len -> List (List (a, Len))
    go [] cur _ = if null cur then [] else [reverse cur]
    go (x :: rest) [] _ = go rest [x] (snd x)
    go (x :: rest) cur used =
      if used + gap + snd x > room
         then reverse cur :: go (x :: rest) [] 0
         else go rest (x :: cur) (used + gap + snd x)

-- The children of a row cut into lines (one line, unless it wraps), each
-- with its outer width after the distribution of the room of its line.
rowLines : Props -> Len -> List (Kid msg) -> List (List (Kid msg, Len))
rowLines p iw ks =
  let based = map (\k => (k, hEdges k.margin
                              + k.clampW (fromMaybe (min (iw `monus` hEdges k.margin) (maxContent k.node))
                                                    (dimSize iw k.kw)))) ks
      lines = if p.pWrap then breakLines p.pGap iw based else [based]
  in map distribute' lines
  where
    distribute' : List (Kid msg, Len) -> List (Kid msg, Len)
    distribute' ln =
      let room = iw `monus` (p.pGap * (count ln `monus` 1))
          sizes = flex room (map (\(k, b) => (b, k.kgrow, k.kshrink, outerW k)) ln)
      in zipWith (\(k, _), sz => (k, sz)) ln sizes

-- Widths (margin excluded) of the children of a column in `iw` cells.
columnWidths : Props -> Len -> List (Kid msg) -> List Len
columnWidths p iw = map width
  where
    width : Kid msg -> Len
    width k =
      let mh = hEdges k.margin in
      k.clampW $ case dimSize iw k.kw of
        Just n => n
        Nothing => case p.pAlign of
                     Stretch => iw `monus` mh
                     _ => min (iw `monus` mh) (maxContent k.node)

-------------------------------------------------------------------------------
-- Natural size

isCells : Dim -> Bool
isCells (Cells _) = True
isCells _ = False

cellsOf : Dim -> Len
cellsOf (Cells n) = n
cellsOf _ = 0

mutual
  -- The children of a column that wraps cut into columns of at most `room`
  -- cells high: each child with its width and height (margins included) and
  -- the outer width of the column, which is that of its widest child. The
  -- width of a child is what it wants, and its height what that width needs.
  colLines : Props -> (iw : Len) -> (room : Len) -> List (Kid msg) -> List (List (Kid msg, Len, Len), Len)
  colLines p iw room ks =
    map (\ln => (map fst ln, foldl max 0 (map (\(_, w, _) => w) (map fst ln)))) (breakLines p.pGap room sized)
    where
      sized : List ((Kid msg, Len, Len), Len)
      sized = map measure ks
        where
          measure : Kid msg -> ((Kid msg, Len, Len), Len)
          measure k =
            let mh = hEdges k.margin
                cw = k.clampW (fromMaybe (min (iw `monus` mh) (maxContent k.node)) (dimSize iw k.kw))
                h = vEdges k.margin + k.clampH (fromMaybe (snd (natural k.node cw)) (dimSize room k.kh))
            in ((k, cw + mh, h), h)

  -- Size of the border box when at most `maxW` cells of width are available.
  -- A `Focusable` is laid out as its unfocused body; the runtime resolves
  -- focusables (`TermUI.Program`) before the layout sees them. Children out of
  -- the flow take no room.
  natural : Node msg -> Len -> (Len, Len)
  natural (Focusable _ body _) maxW = natural (body False) maxW
  natural (Text _ wrap s) maxW =
    let ls = wrapText wrap maxW s in
    (foldl max 0 (map stringWidth ls), count ls)
  natural (Box p kids) maxW =
    let bw = borderWidth p.pBorder
        bx = 2 * bw + hEdges p.pPadding
        by = 2 * bw + vEdges p.pPadding
        avail = case p.pWidth of
                  Cells n => min n maxW
                  _ => maxW
        iw = avail `monus` bx
        ks = map (kidOf iw) (filter (not . isAbsolute) kids)
        (cw, ch) = case p.pDirection of
          Row =>
            let lines = rowLines p iw ks
                lineWidth = \ln => sum (map snd ln) + p.pGap * (count ln `monus` 1)
            in ( foldl max 0 (map lineWidth lines)
               , sum (map rowLineHeight lines) + p.pGap * (count lines `monus` 1) )
          Column =>
            if p.pWrap && isCells p.pHeight
               then let cols = colLines p iw (cellsOf p.pHeight `monus` by) ks
                    in (sum (map snd cols) + p.pGap * (count cols `monus` 1), 0)
            else
            -- The width of a column is that of its widest child; the height of
            -- a child is measured at the width it will receive.
            let widths = columnWidths p iw ks
                wanted = map (\k => maxContent k.node + hEdges k.margin) ks
            in ( foldl max 0 wanted
               , sum (zipWith (\k, cwid => k.clampH (snd (natural k.node cwid)) + vEdges k.margin) ks widths)
                 + p.pGap * (count ks `monus` 1) )
        w = case p.pWidth of
              Cells k => k
              _ => min maxW (cw + bx)
        h = case p.pHeight of
              Cells k => k
              _ => ch + by
    in (clampBy p.pMinWidth p.pMaxWidth w, clampBy p.pMinHeight p.pMaxHeight h)

  -- The height of a child of a row that gets `mw` cells of width (margin excluded).
  rowChildHeight : Kid msg -> Len -> Len
  rowChildHeight k mw =
    k.clampH $ case k.kh of
      Cells n => n
      _ => snd (natural k.node mw)

  -- The height of a line of a row: its tallest child with margins.
  rowLineHeight : List (Kid msg, Len) -> Len
  rowLineHeight ln =
    foldl max 0 (map (\(k, sz) => rowChildHeight k (sz `monus` hEdges k.margin) + vEdges k.margin) ln)

-------------------------------------------------------------------------------
-- Placement

crossOffset : Align -> Len -> Len
crossOffset Center free = ndiv free 2
crossOffset End free = free
crossOffset _ _ = 0

mutual
  -- Where a box out of the flow goes in the content box `i` of its parent.
  placeAbsolute : Rect -> Node msg -> Laid
  placeAbsolute i (Focusable _ body _) = placeAbsolute i (body False)
  placeAbsolute i node@(Box p _) =
    let k = kidOf i.w node
        side = \a, b => fromMaybe 0 a + fromMaybe 0 b
        freeW = i.w `monus` (side p.pLeft p.pRight + hEdges k.margin)
        freeH = i.h `monus` (side p.pTop p.pBottom + vEdges k.margin)
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
              (Nothing, Just r) => i.w `monus` (w + r + k.margin.right)
              _ => k.margin.left
        y = case (p.pTop, p.pBottom) of
              (Just t, _) => t + k.margin.top
              (Nothing, Just b) => i.h `monus` (h + b + k.margin.bottom)
              _ => k.margin.top
    in place node (MkRect (i.x + x) (i.y + y) w h)
  placeAbsolute i node@(Text _ _ _) = place node i
  
  ||| Place a node in the border box `r`.
  export
  place : Node msg -> Rect -> Laid
  place (Text s wrap str) r = LText r s (wrapText wrap r.w str)
  place (Focusable _ body _) r = place (body False) r
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
      lineTops : (gap : Len) -> (y : Len) -> List Len -> List Len
      lineTops _ _ [] = []
      lineTops gap y (lh :: rest) = y :: lineTops gap (y + lh + gap) rest


  placeLine : Props -> Rect -> List (Kid msg, Len) -> Len -> Len -> List Laid
  placeLine p i ln lh y0 =
    let sizes = map snd ln
        xs = mainPositions p i.w sizes
    in zipWith (\(k, sz), px =>
         let mw = sz `monus` hEdges k.margin
             mv = vEdges k.margin
             ch = k.clampH $ case dimSize lh k.kh of
                    Just n => n
                    Nothing => case p.pAlign of
                                 Stretch => lh `monus` mv
                                 _ => snd (natural k.node mw)
             off = crossOffset p.pAlign (lh `monus` (ch + mv))
         in place k.node (MkRect (i.x + px + k.margin.left) (i.y + y0 + off + k.margin.top) mw ch))
       ln xs

  placeColumn : Props -> Rect -> List (Kid msg) -> List Laid
  placeColumn p i ks =
    let widths = columnWidths p i.w ks
        bases = zipWith (\k, cw => vEdges k.margin
                                     + k.clampH (fromMaybe (snd (natural k.node cw)) (dimSize i.h k.kh))) ks widths
        room = i.h `monus` (p.pGap * (count ks `monus` 1))
        sizes = flex room (zipWith (\k, b => (b, k.kgrow, k.kshrink, outerH k)) ks bases)
        ys = mainPositions p i.h sizes
    in zipWith3 (\(k, cw), sz, py =>
         let mh = sz `monus` vEdges k.margin
             off = crossOffset p.pAlign (i.w `monus` (cw + hEdges k.margin))
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
      colStarts : Len -> List Len -> List Len
      colStarts _ [] = []
      colStarts x (cw :: rest) = x :: colStarts (x + cw + p.pGap) rest

      placeCol : (List (Kid msg, Len, Len), Len) -> Len -> List Laid
      placeCol (items, cw) x0 =
        let room = i.h `monus` (p.pGap * (count items `monus` 1))
            sizes = flex room (map (\(k, _, h) => (h, k.kgrow, k.kshrink, outerH k)) items)
            ys = mainPositions p i.h sizes
            widths = columnWidths p cw (map (\(k, _, _) => k) items)
        in zipWith3 (\((k, _, _), sz), wd, py =>
             let off = crossOffset p.pAlign (cw `monus` (wd + hEdges k.margin))
             in place k.node (MkRect (i.x + x0 + off + k.margin.left) (i.y + py + k.margin.top)
                                     wd (sz `monus` vEdges k.margin)))
           (zip items sizes) widths ys

||| Lay out a view in a screen of `w` x `h` cells.
export
layout : Node msg -> (w : Len) -> (h : Len) -> Laid
layout n w h = place n (MkRect 0 0 w h)
