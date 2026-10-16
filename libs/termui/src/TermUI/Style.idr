||| Colours and text attributes of a terminal cell.
||| A `Style` is a plain value; the renderer turns style changes between
||| neighbouring cells into the shortest SGR sequence.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Style

import Data.Bits

%default total

-------------------------------------------------------------------------------
-- Colour

public export
data Color
  = Default
  | Indexed Bits8
  | RGB Bits8 Bits8 Bits8

export
Eq Color where
  Default == Default = True
  Indexed a == Indexed b = a == b
  RGB r g b == RGB r' g' b' = r == r' && g == g' && b == b'
  _ == _ = False

export
Show Color where
  show Default = "Default"
  show (Indexed n) = "Indexed " ++ show n
  show (RGB r g b) = "RGB " ++ show r ++ " " ++ show g ++ " " ++ show b

public export
black, red, green, yellow, blue, magenta, cyan, white : Color
black = Indexed 0
red = Indexed 1
green = Indexed 2
yellow = Indexed 3
blue = Indexed 4
magenta = Indexed 5
cyan = Indexed 6
white = Indexed 7

||| The bright variant (indices 8..15) of an ANSI colour.
public export
bright : Color -> Color
bright (Indexed n) = if n < 8 then Indexed (n + 8) else Indexed n
bright c = c

-------------------------------------------------------------------------------
-- Attributes

public export
data Attr = Bold | Dim | Italic | Underline | Inverse | Strike

public export
attrBit : Attr -> Bits8
attrBit Bold = 1
attrBit Dim = 2
attrBit Italic = 4
attrBit Underline = 8
attrBit Inverse = 16
attrBit Strike = 32

public export
allAttrs : List Attr
allAttrs = [Bold, Dim, Italic, Underline, Inverse, Strike]

-------------------------------------------------------------------------------
-- Style

public export
record Style where
  constructor MkStyle
  fg : Color
  bg : Color
  attrs : Bits8

export
Eq Style where
  MkStyle f b a == MkStyle f' b' a' = a == a' && f == f' && b == b'

export
Show Style where
  show (MkStyle f b a) = "MkStyle (" ++ show f ++ ") (" ++ show b ++ ") " ++ show a

public export
plain : Style
plain = MkStyle Default Default 0

public export
fgColor : Color -> Style -> Style
fgColor c s = { fg := c } s

public export
bgColor : Color -> Style -> Style
bgColor c s = { bg := c } s

public export
withAttr : Attr -> Style -> Style
withAttr a s = { attrs := s.attrs .|. attrBit a } s

public export
hasAttr : Attr -> Style -> Bool
hasAttr a s = (s.attrs .&. attrBit a) /= 0

||| `over top base`: the fields of `top` that are set win; colours left at
||| `Default` and absent attributes are inherited from `base`.
public export
over : Style -> Style -> Style
over top base =
  MkStyle (if top.fg == Default then base.fg else top.fg)
          (if top.bg == Default then base.bg else top.bg)
          (top.attrs .|. base.attrs)
