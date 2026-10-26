||| The cell grid a view is painted into, and the painter.
||| A wide character occupies its own cell followed by a continuation cell
||| (glyph '\0') carrying the same style, so equal frames are equal cell by
||| cell. Combining marks are kept with the cell of the character they follow.
||| The grid is one `Buffer` of 16-byte cells, so painting and diffing
||| allocate nothing per cell; see libs/termui/doc/design.md ("Frame layout").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Frame

import Data.Bits
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedMap
import TermUI.Canvas
import public TermUI.Cell
import TermUI.Layout
import TermUI.Len
import TermUI.Node
import TermUI.Style
import TermUI.Width

%default covering

-------------------------------------------------------------------------------
-- Cells and frames

public export
record Cell where
  constructor MkCell
  glyph : Char
  style : Style
  combining : List Char

export
Eq Cell where
  MkCell g s m == MkCell g' s' m' = g == g' && s == s' && m == m'

public export
blank : Cell
blank = MkCell ' ' (settle plain) []

-- The layout of a cell is in doc/design.md ("Frame layout").
public export
record Frame where
  constructor MkFrame
  frameWidth, frameHeight : Len
  buf : Buffer
  marks : IORef (SortedMap Int (List Char))

export
newFrame : Len -> Len -> IO Frame
newFrame w h = do
  let w' = nonneg w
      h' = nonneg h
  b <- newGrid w' h'
  MkFrame w' h' b <$> newIORef empty

within : Frame -> Len -> Len -> Bool
within f = inGrid f.frameWidth f.frameHeight

offset : Frame -> Len -> Len -> Int
offset f = cellOffset f.frameWidth

export
getCell : Frame -> Len -> Len -> IO Cell
getCell f x y =
  if within f x y
     then do
       let at = offset f x y
       g <- getBits32 f.buf at
       fg <- getBits32 f.buf (at + 4)
       bg <- getBits32 f.buf (at + 8)
       a <- getBits32 f.buf (at + 12)
       ms <- if (a .&. markedBit) /= 0 then fromMaybe [] . lookup at <$> readIORef f.marks else pure []
       pure (MkCell (unpackGlyph g) (unpackStyle fg bg a) ms)
     else pure blank

||| The glyph of a cell, without building the cell.
export
glyphAt : Frame -> Len -> Len -> IO Char
glyphAt f = glyphIn f.buf f.frameWidth f.frameHeight

||| Whether two frames of the same size have equal cells at (x, y).
export
sameAt : Frame -> Frame -> Len -> Len -> IO Bool
sameAt a b x y = do
  let oa = offset a x y
      ob = offset b x y
  l <- getBits64 a.buf oa
  r <- getBits64 b.buf ob
  if l /= r then pure False else do
    l' <- getBits64 a.buf (oa + 8)
    r' <- getBits64 b.buf (ob + 8)
    if l' /= r' then pure False else do
      attrs <- getBits32 a.buf (oa + 12)
      if (attrs .&. markedBit) == 0 then pure True else do
        ma <- readIORef a.marks
        mb <- readIORef b.marks
        pure (lookup oa ma == lookup ob mb)

||| Whether the cell at (x, y) is a blank default cell.
export
blankAt : Frame -> Len -> Len -> IO Bool
blankAt f x y = do
  let at = offset f x y
  l <- getBits64 f.buf at
  r <- getBits64 f.buf (at + 8)
  pure (l == 0 && r == 0)

||| A hash of the cells of row `y`, all but the last column (a scroll bar changes
||| with the text that scrolls past it). Combining marks are not in it.
export
rowHash : Frame -> Len -> IO Bits64
rowHash f y = go 0 0
  where
    last : Len
    last = f.frameWidth `monus` 1

    go : Len -> Bits64 -> IO Bits64
    go x h =
      if x >= last then pure h else do
        let at = offset f x y
        l <- getBits64 f.buf at
        r <- getBits64 f.buf (at + 8)
        go (x + 1) ((h * 1099511628211) `xor` l `xor` (r * 31))

||| The hash of a row with nothing in it (`rowHash` starts from 0 and a blank cell adds 0).
export
emptyRowHash : Bits64
emptyRowHash = 0

||| The frame as a terminal shows it after the rows `top` to `bottom` have been
||| scrolled up by `k` rows (down if `k` is negative): the rows that come in are
||| blank, the others are as they were.
export
shiftRows : Frame -> (top, bottom, k : Len) -> IO Frame
shiftRows f top bottom k = do
  let w = f.frameWidth
      rowBytes = cellSize * cast w
  nf <- newFrame w f.frameHeight
  -- the rows outside the region as they are, the rows of the region that stay moved;
  -- the others are as `newFrame` made them, blank
  copyRows f nf 0 top
  copyRows f nf (bottom + 1) f.frameHeight
  traverse_ (\y => copyData f.buf (offset f 0 y) rowBytes nf.buf (offset nf 0 (y - k)))
            (if k > 0 then span (top + k) (bottom + 1) else span top (bottom + k + 1))
  ms <- readIORef f.marks
  let inRegion = \y => y >= top && y <= bottom
      rowOf = \key => cast {to = Len} ((key `div` cellSize) `div` cast w)
      (inside, outside) = partition (\(key, _) => inRegion (rowOf key)) (SortedMap.toList ms)
      moved = mapMaybe (\(key, m) => if inRegion (rowOf key - k) then Just (key - cast k * rowBytes, m) else Nothing) inside
  writeIORef nf.marks (fromList (outside ++ moved))
  pure nf
  where
    copyRows : Frame -> Frame -> Len -> Len -> IO ()
    copyRows src dst from to =
      when (to > from) $
        copyData src.buf (offset src 0 from) (cellSize * cast src.frameWidth * cast (to - from)) dst.buf (offset dst 0 from)

-- The cell at `at` has no combining marks afterwards.
dropMarks : Frame -> Int -> IO ()
dropMarks f at = do
  a <- getBits32 f.buf (at + 12)
  when ((a .&. markedBit) /= 0) $ do
    setBits32 f.buf (at + 12) (a .&. 0xff)
    modifyIORef f.marks (delete at)

setCell : Frame -> Len -> Len -> Char -> (fg, bg, attrs : Bits32) -> IO ()
setCell f = storeCell f.buf (dropMarks f) f.frameWidth f.frameHeight

-- At most 8 marks stay with a cell.
addMark : Frame -> Len -> Len -> Char -> IO ()
addMark f x y mark =
  when (within f x y) $ do
    let at = offset f x y
    cur <- fromMaybe [] . lookup at <$> readIORef f.marks
    when (length cur < 8) $ do
      modifyIORef f.marks (insert at (cur ++ [mark]))
      a <- getBits32 f.buf (at + 12)
      setBits32 f.buf (at + 12) (a .|. markedBit)

-------------------------------------------------------------------------------
-- Painting

-- A drawing window [x0, x1) x [y0, y1): cells outside it are ignored.
record Clip where
  constructor MkClip
  x0, y0, x1, y1 : Len

clipRect : Rect -> Clip
clipRect r = MkClip r.x r.y (r.x + r.w) (r.y + r.h)

intersect : Clip -> Clip -> Clip
intersect a b = MkClip (max a.x0 b.x0) (max a.y0 b.y0) (min a.x1 b.x1) (min a.y1 b.y1)

inside : Clip -> Len -> Len -> Bool
inside c x y = x >= c.x0 && x < c.x1 && y >= c.y0 && y < c.y1

put : Frame -> Clip -> Len -> Len -> Char -> Style -> IO ()
put f c x y g s = when (inside c x y) $ setCell f x y g (packColor s.fg) (packColor s.bg) (cast s.attrs)

-- The cells of `c` that are at its place `r` inside the clip.
blitCanvas : Frame -> Clip -> Rect -> Canvas -> IO ()
blitCanvas f clip r c = do
  let x0 = max r.x clip.x0
      x1 = min (r.x + min c.canvasWidth r.w) clip.x1
      y0 = max r.y clip.y0
      y1 = min (r.y + min c.canvasHeight r.h) clip.y1
  when (x1 > x0 && y1 > y0) $ do
    forgetMarks x0 x1 y0 y1
    traverse_ (row x0 x1) (span y0 y1)
  where
    -- Stored marks in the cells about to be overwritten go.
    forgetMarks : Len -> Len -> Len -> Len -> IO ()
    forgetMarks x0 x1 y0 y1 = do
      ms <- readIORef f.marks
      when (isJust (leftMost ms)) $
        writeIORef f.marks (fromList (filter (\(k, _) => not (covered k)) (SortedMap.toList ms)))
      where
        covered : Int -> Bool
        covered k =
          let cell = k `div` cellSize
              (cy, cx) = (cell `div` cast f.frameWidth, cell `mod` cast f.frameWidth)
          in cx >= cast x0 && cx < cast x1 && cy >= cast y0 && cy < cast y1

    blankGlyphAt : Len -> Len -> IO ()
    blankGlyphAt x y = do
      let at = offset f x y
      dropMarks f at
      setBits32 f.buf at 0

    -- A wide character cut by the window or by what is under it is a blank.
    row : Len -> Len -> Len -> IO ()
    row x0 x1 y = do
      let dst = offset f x0 y
          len = cellSize * cast (x1 - x0)
      before <- glyphAt f (x0 - 1) y
      when (charWidth before == 2) $ blankGlyphAt (x0 - 1) y
      after <- glyphAt f x1 y
      when (after == continuation) $ blankGlyphAt x1 y
      copyData c.canvasBuf (cellOffset c.canvasWidth (x0 - r.x) (y - r.y)) len f.buf dst
      first <- glyphAt f x0 y
      when (first == continuation) $ blankGlyphAt x0 y
      lastG <- glyphAt f (x1 - 1) y
      when (charWidth lastG == 2) $ blankGlyphAt (x1 - 1) y

-- Children are clipped to the content box of their parent.
paintLaid : Frame -> Clip -> Style -> Laid -> IO ()
paintLaid f c inherited (LText r s ls) = do
  let st = s `over` inherited
      cl = intersect c (clipRect r)
  traverse_ (\(i, l) => paintLine cl r.x (r.y + i) st (unpack l)) (zip [0 .. count ls] ls)
  where
    -- A combining mark goes with the cell before `x` (the first one of a wide
    -- character), if that is in the window.
    attach : Clip -> Len -> Len -> Char -> IO ()
    attach c x y mark =
      when (x > 0) $ do
        prev <- glyphAt f (x `monus` 1) y
        let at = if prev == continuation && x > 1 then x `monus` 2 else x `monus` 1
        when (inside c at y) $ addMark f at y mark

    paintLine : Clip -> Len -> Len -> Style -> List Char -> IO ()
    paintLine _ _ _ _ [] = pure ()
    paintLine c x y s (ch :: rest) =
      case charWidth ch of
        0 => when (isMark ch) (attach c x y ch) >> paintLine c x y s rest
        2 => do
          if inside c x y && inside c (x + 1) y
             then put f c x y ch s >> put f c (x + 1) y continuation s
             else put f c x y ' ' s
          paintLine c (x + 2) y s rest
        _ => put f c x y ch s >> paintLine c (x + 1) y s rest
paintLaid f c _ (LCanvas r cv) = blitCanvas f (intersect c (clipRect r)) r cv
paintLaid f c inherited (LBox r p kids) = do
  let st = p.pStyle `over` inherited
      cl = intersect c (clipRect r)
  when (st /= inherited || hasBorder p.pBorder) $ fillRect cl r st
  paintBorder cl r p.pBorder (p.pBorderStyle `over` st)
  let inner = intersect cl (clipRect (innerRect p r))
  traverse_ (paintLaid f inner st) kids
  where
    hasBorder : Border -> Bool
    hasBorder NoBorder = False
    hasBorder _ = True

    -- Only the part of `r` inside the clip is visited.
    fillRect : Clip -> Rect -> Style -> IO ()
    fillRect c r s =
      traverse_ (\yy => traverse_ (\xx => put f c xx yy ' ' s)
                                  (span (max r.x c.x0) (min (r.x + r.w) c.x1)))
                (span (max r.y c.y0) (min (r.y + r.h) c.y1))

    -- (top-left, top-right, bottom-left, bottom-right, horizontal, vertical)
    borderChars : Border -> (Char, Char, Char, Char, Char, Char)
    borderChars Rounded = ('╭', '╮', '╰', '╯', '─', '│')
    borderChars DoubleLine = ('╔', '╗', '╚', '╝', '═', '║')
    borderChars Heavy = ('┏', '┓', '┗', '┛', '━', '┃')
    borderChars Ascii = ('+', '+', '+', '+', '-', '|')
    borderChars _ = ('┌', '┐', '└', '┘', '─', '│')

    paintBorder : Clip -> Rect -> Border -> Style -> IO ()
    paintBorder _ _ NoBorder _ = pure ()
    paintBorder c r b s =
      when (r.w >= 2 && r.h >= 2) $ do
        let (tl, tr, bl, br, hz, vt) = borderChars b
            right = r.x + r.w `monus` 1
            bottom = r.y + r.h `monus` 1
        traverse_ (\xx => put f c xx r.y hz s >> put f c xx bottom hz s)
                  (span (max (r.x + 1) c.x0) (min right c.x1))
        traverse_ (\yy => put f c r.x yy vt s >> put f c right yy vt s)
                  (span (max (r.y + 1) c.y0) (min bottom c.y1))
        put f c r.x r.y tl s
        put f c right r.y tr s
        put f c r.x bottom bl s
        put f c right bottom br s

||| Lay out `view` in `w` x `h` cells and paint it into a fresh frame; the
||| layout is returned too, for finding where nodes ended up.
export
renderLaid : Node msg -> (w : Len) -> (h : Len) -> IO (Frame, Laid)
renderLaid view w h = do
  f <- newFrame w h
  let laid = layout view w h
  paintLaid f (MkClip 0 0 w h) plain laid
  pure (f, laid)

||| Lay out `view` in `w` x `h` cells and paint it into a fresh frame.
export
render : Node msg -> (w : Len) -> (h : Len) -> IO Frame
render view w h = fst <$> renderLaid view w h

||| The text of a frame, one string per row without trailing blanks.
||| Styles are dropped; used by tests and for plain-text dumps.
export
frameLines : Frame -> IO (List String)
frameLines f = traverse row (span 0 f.frameHeight)
  where
    trimEnd : String -> String
    trimEnd s = pack (reverse (dropWhile (== ' ') (reverse (unpack s))))

    shown : Cell -> List Char
    shown cell = if cell.glyph == continuation then [] else cell.glyph :: cell.combining

    row : Len -> IO String
    row y = do
      cs <- traverse (\x => getCell f x y) (span 0 f.frameWidth)
      pure (trimEnd (pack (concatMap shown cs)))
