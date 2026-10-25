||| The packed cell of a `Frame` and a `Canvas`: four `Bits32` words in a
||| `Buffer`, and the one way of storing a character into a grid of them.
||| The layout is in libs/termui/doc/design.md ("Frame layout").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Cell

import Data.Bits
import Data.Buffer
import TermUI.Len
import TermUI.Style
import TermUI.Width

%default covering

||| The glyph of the second cell of a wide character.
public export
continuation : Char
continuation = '\0'

export
cellSize : Int
cellSize = 16

||| Bit 8 of the attribute word: the cell has combining marks.
export
markedBit : Bits32
markedBit = 0x100

export
packGlyph : Char -> Bits32
packGlyph g = cast (ord g) `xor` 0x20

export
unpackGlyph : Bits32 -> Char
unpackGlyph w = chr (cast (w `xor` 0x20))

export
packColor : Color -> Bits32
packColor (Indexed n) = 0x01000000 .|. cast n
packColor (RGB r g b) = 0x02000000 .|. shiftL (cast r) 16 .|. shiftL (cast g) 8 .|. cast b
packColor _ = 0

export
unpackColor : Bits32 -> Color
unpackColor w =
  case shiftR w 24 of
    1 => Indexed (cast (w .&. 0xff))
    2 => RGB (cast (shiftR w 16 .&. 0xff)) (cast (shiftR w 8 .&. 0xff)) (cast (w .&. 0xff))
    _ => Default

||| The numbers lo, lo+1, .., hi-1.
export
span : Len -> Len -> List Len
span lo hi = if hi <= lo then [] else [lo .. hi `monus` 1]

||| A zeroed buffer for a grid of `w` x `h` cells, which is a blank grid.
export
newGrid : (w, h : Len) -> IO Buffer
newGrid w h = do
  -- `newBuffer` takes a C int
  let bytes = cellSize * cast w * cast h
  mb <- the (IO (Maybe Buffer)) (if bytes > 0x7fffffff then pure Nothing else newBuffer bytes)
  let Just b = mb
    | Nothing => assert_total (idris_crash "termui: cannot allocate a grid of cells")
  pure b

||| The style of a cell from its colour and attribute words.
export
unpackStyle : (fg, bg, attrs : Bits32) -> Style
unpackStyle fg bg a = MkStyle (unpackColor fg) (unpackColor bg) (cast (a .&. 0xff)) 0

||| Whether (x, y) is a cell of a `w` x `h` grid.
export
inGrid : (w, h : Len) -> Len -> Len -> Bool
inGrid w h x y = x >= 0 && y >= 0 && x < w && y < h

||| The byte offset of cell (x, y) of a grid `w` cells wide.
export
cellOffset : (w : Len) -> Len -> Len -> Int
cellOffset w x y = cellSize * (cast y * cast w + cast x)

||| The glyph of a cell, ' ' outside the grid.
export
glyphIn : Buffer -> (w, h : Len) -> Len -> Len -> IO Char
glyphIn b w h x y = if inGrid w h x y then unpackGlyph <$> getBits32 b (cellOffset w x y) else pure ' '

||| Store a character into cell (x, y) of a grid; outside it nothing happens.
||| Overwriting half of a wide character blanks the other half. `forget` is
||| called with the offset of every cell about to be overwritten, to let its
||| owner drop what it keeps beside the cell.
export
storeCell : Buffer -> (forget : Int -> IO ()) -> (w, h : Len) -> Len -> Len -> Char
         -> (fg, bg, attrs : Bits32) -> IO ()
storeCell b forget w h x y g fg bg attrs =
  when (inGrid w h x y) $ do
    old <- glyphIn b w h x y
    when (old == continuation && x > 0) $ blankGlyph (x - 1)
    when (charWidth old == 2 && x + 1 < w) $ blankGlyph (x + 1)
    let at = cellOffset w x y
    forget at
    setBits32 b at (packGlyph g)
    setBits32 b (at + 4) fg
    setBits32 b (at + 8) bg
    setBits32 b (at + 12) attrs
  where
    -- The glyph becomes ' ', the style stays.
    blankGlyph : Len -> IO ()
    blankGlyph xx = do
      let at = cellOffset w xx y
      forget at
      setBits32 b at 0
