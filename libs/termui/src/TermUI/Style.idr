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

||| `Inherit` takes the colour of the parent, `Default` is the terminal's own.
public export
data Color
  = Inherit
  | Default
  | Indexed Bits8
  | RGB Bits8 Bits8 Bits8

export
Eq Color where
  Inherit == Inherit = True
  Default == Default = True
  Indexed a == Indexed b = a == b
  RGB r g b == RGB r' g' b' = r == r' && g == g' && b == b'
  _ == _ = False

export
Show Color where
  show Inherit = "Inherit"
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

||| `attrs` are the attributes switched on, `attrsOff` those explicitly switched
||| off (against a parent that has them on); the rest is inherited.
public export
record Style where
  constructor MkStyle
  fg : Color
  bg : Color
  attrs : Bits8
  attrsOff : Bits8

export
Eq Style where
  MkStyle f b a o == MkStyle f' b' a' o' = a == a' && o == o' && f == f' && b == b'

export
Show Style where
  show (MkStyle f b a o) = "MkStyle (" ++ show f ++ ") (" ++ show b ++ ") " ++ show a ++ " " ++ show o

||| Everything inherited.
public export
plain : Style
plain = MkStyle Inherit Inherit 0 0

public export
fgColor : Color -> Style -> Style
fgColor c s = { fg := c } s

public export
bgColor : Color -> Style -> Style
bgColor c s = { bg := c } s

public export
withAttr : Attr -> Style -> Style
withAttr a s = { attrs := s.attrs .|. attrBit a, attrsOff := s.attrsOff .&. complement (attrBit a) } s

||| Switch an attribute off, whatever the parent has.
public export
withoutAttr : Attr -> Style -> Style
withoutAttr a s = { attrs := s.attrs .&. complement (attrBit a), attrsOff := s.attrsOff .|. attrBit a } s

public export
hasAttr : Attr -> Style -> Bool
hasAttr a s = (s.attrs .&. attrBit a) /= 0

||| `over top base`: what `top` sets wins (a colour, an attribute on or off);
||| the rest is inherited from `base`.
public export
over : Style -> Style -> Style
over top base =
  MkStyle (if top.fg == Inherit then base.fg else top.fg)
          (if top.bg == Inherit then base.bg else top.bg)
          ((base.attrs .&. complement top.attrsOff) .|. top.attrs)
          ((base.attrsOff .&. complement top.attrs) .|. top.attrsOff)

||| The style of a cell: what is still inherited at the root is the terminal's
||| own, and attributes switched off are just absent.
public export
settle : Style -> Style
settle s = MkStyle (fix s.fg) (fix s.bg) s.attrs 0
  where
    fix : Color -> Color
    fix Inherit = Default
    fix c = c
