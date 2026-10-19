||| The cell grid a view is painted into, and the painter.
||| A wide character occupies its own cell followed by a continuation cell
||| (glyph '\0') carrying the same style, so equal frames are equal cell by
||| cell. Combining marks are kept with the cell of the character they follow.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Frame

import Data.IOArray
import Data.List
import Data.Maybe
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

public export
continuation : Char
continuation = '\0'

-- Cells never written read back as `blank`.
public export
record Frame where
  constructor MkFrame
  frameWidth, frameHeight : Len
  cells : IOArray Cell

export
newFrame : Len -> Len -> IO Frame
newFrame w h = MkFrame w h <$> newArray (cast (w * h))

||| The numbers lo, lo+1, .., hi-1.
export
span : Len -> Len -> List Len
span lo hi = if hi <= lo then [] else [lo .. hi `monus` 1]

export
getCell : Frame -> Len -> Len -> IO Cell
getCell f x y =
  if x < f.frameWidth && y < f.frameHeight
     then fromMaybe blank <$> readArray f.cells (cast (y * f.frameWidth + x))
     else pure blank

-- Overwriting half of a wide character blanks the other half.
setCell : Frame -> Len -> Len -> Cell -> IO ()
setCell f x y c =
  when (x < f.frameWidth && y < f.frameHeight) $ do
    old <- getCell f x y
    let at = cast (y * f.frameWidth + x)
    when (old.glyph == continuation && x > 0) $
      ignore (writeArray f.cells (at - 1) (MkCell ' ' old.style []))
    when (charWidth old.glyph == 2 && x + 1 < f.frameWidth) $
      ignore (writeArray f.cells (at + 1) (MkCell ' ' old.style []))
    ignore (writeArray f.cells at c)

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
put f c x y g s = when (inside c x y) $ setCell f x y (MkCell g (settle s) [])

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
        prev <- getCell f (x `monus` 1) y
        let at = if prev.glyph == continuation && x > 1 then x `monus` 2 else x `monus` 1
        cell <- getCell f at y
        when (inside c at y && length cell.combining < 8) $
          ignore (writeArray f.cells (cast (y * f.frameWidth + at)) ({ combining $= (++ [mark]) } cell))

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
