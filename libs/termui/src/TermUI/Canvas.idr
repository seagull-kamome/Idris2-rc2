||| A canvas: a grid of cells that a program draws into with `putCell`,
||| `putString` and `fillRect` and shows with the `canvas` node, for a game or
||| anything else that paints single cells. It keeps what was drawn between
||| views, so only the changes need to be drawn. Cells are packed as in a
||| `Frame` (libs/termui/doc/design.md, "Canvas"); a canvas has no combining
||| marks, and its colours are the terminal's own where `Default`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Canvas

import Data.Bits
import Data.Buffer
import Data.List
import TermUI.Cell
import TermUI.Len
import TermUI.Style
import TermUI.Width

%default covering

public export
record Canvas where
  constructor MkCanvas
  canvasWidth, canvasHeight : Len
  canvasBuf : Buffer

||| A blank canvas; a negative size is 0.
export
newCanvas : Len -> Len -> IO Canvas
newCanvas w h = do
  let w' = nonneg w
      h' = nonneg h
  MkCanvas w' h' <$> newGrid w' h'

-- A cell of the canvas; nothing outside it.
store : Canvas -> Len -> Len -> Char -> Style -> IO ()
store c x y g s =
  storeCell c.canvasBuf (const (pure ())) c.canvasWidth c.canvasHeight x y g
            (packColor s.fg) (packColor s.bg) (cast s.attrs)

||| Draw a character in a cell. A wide one takes the next cell too, and is
||| a blank if that is outside the canvas. A zero-width one is not drawn.
export
putCell : Canvas -> Len -> Len -> Char -> Style -> IO ()
putCell c x y g s =
  case charWidth g of
    0 => pure ()
    2 => if x + 1 < c.canvasWidth && x >= 0
            then store c x y g s >> store c (x + 1) y continuation s
            else store c (max 0 x) y ' ' s
    _ => store c x y g s

||| Draw a string from (x, y) to the right, cut at the edges of the canvas.
export
putString : Canvas -> Len -> Len -> Style -> String -> IO ()
putString c x y s str = go x (unpack str)
  where
    go : Len -> List Char -> IO ()
    go _ [] = pure ()
    go xx (g :: rest) = putCell c xx y g s >> go (xx + charWidth g) rest

||| Fill the rectangle with its top left cell at (x, y), cut at the edges of
||| the canvas, with one character. A wide one is drawn as many times as
||| fit, a blank where one cell is left.
export
fillRect : Canvas -> (x, y, w, h : Len) -> Char -> Style -> IO ()
fillRect c x y w h g s =
  traverse_ (\yy => row yy (max 0 x)) (span (max 0 y) (min c.canvasHeight (y + h)))
  where
    right : Len
    right = min c.canvasWidth (x + w)

    row : Len -> Len -> IO ()
    row yy xx =
      when (xx < right) $
        if charWidth g == 2 && xx + 1 >= right
           then putCell c xx yy ' ' s
           else putCell c xx yy g s >> row yy (xx + max 1 (charWidth g))

||| Every cell becomes a blank in the style.
export
clear : Canvas -> Style -> IO ()
clear c = fillRect c 0 0 c.canvasWidth c.canvasHeight ' '

||| The character and style of a cell; a blank default one outside the canvas.
||| The second cell of a wide character reads as `continuation`.
export
cellAt : Canvas -> Len -> Len -> IO (Char, Style)
cellAt c x y =
  if inGrid c.canvasWidth c.canvasHeight x y
     then do
       let at = cellOffset c.canvasWidth x y
       g <- getBits32 c.canvasBuf at
       fg <- getBits32 c.canvasBuf (at + 4)
       bg <- getBits32 c.canvasBuf (at + 8)
       a <- getBits32 c.canvasBuf (at + 12)
       pure (unpackGlyph g, unpackStyle fg bg a)
     else pure (' ', settle plain)
