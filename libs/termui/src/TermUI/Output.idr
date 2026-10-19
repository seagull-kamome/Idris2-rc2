||| Turns the difference between two frames into the terminal output that
||| transforms the screen from one to the other.
||| Cursor moves and SGR sequences are emitted only when needed; the whole
||| update is one string, meant to be written with a single write(2).
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Output

import Control.ANSI.CSI
import Data.List
import Data.Maybe
import TermUI.Frame
import TermUI.Len
import TermUI.Style
import TermUI.Width

%default covering

-------------------------------------------------------------------------------
-- SGR

colorCode : (base : Nat) -> (bright : Nat) -> (ext : Nat) -> Color -> String
colorCode _ _ _ Inherit = ""
colorCode _ _ _ Default = ""
colorCode base br ext (Indexed n) =
  let i = cast {to = Nat} n in
  if i < 8 then ";" ++ show (base + i)
  else if i < 16 then ";" ++ show (br + i `minus` 8)
  else ";" ++ show ext ++ ";5;" ++ show i
colorCode _ _ ext (RGB r g b) =
  ";" ++ show ext ++ ";2;" ++ show r ++ ";" ++ show g ++ ";" ++ show b

attrCode : Attr -> String
attrCode Bold = ";1"
attrCode Dim = ";2"
attrCode Italic = ";3"
attrCode Underline = ";4"
attrCode Inverse = ";7"
attrCode Strike = ";9"

||| The sequence that sets exactly `s`, whatever was set before.
export
sgr : Style -> String
sgr s =
  "\ESC[0"
    ++ concatMap attrCode (filter (\a => hasAttr a s) allAttrs)
    ++ colorCode 30 90 38 s.fg
    ++ colorCode 40 100 48 s.bg
    ++ "m"

-------------------------------------------------------------------------------
-- Diff

record St where
  constructor MkSt
  out : List String            
  cursor : Maybe (Len, Len)
  current : Maybe Style

glyphWidth : Char -> Len
glyphWidth c = max 1 (charWidth c)

emitCell : Len -> Len -> Len -> Cell -> St -> St
emitCell fw x y c st =
  let moved = if st.cursor == Just (x, y) then [] else [cursorMove (cast (y + 1)) (cast (x + 1))]
      styled = if st.current == Just c.style then [] else [sgr c.style]
      next = x + glyphWidth c.glyph
  in MkSt (pack (c.glyph :: c.combining) :: styled ++ moved ++ st.out)
          (if next >= fw then Nothing else Just (next, y))
          (Just c.style)

||| The output that turns the screen showing `prev` into `next`. Without a
||| previous frame (or after a resize) the screen is cleared first.
export
diffFrames : Maybe Frame -> Frame -> IO String
diffFrames prev0 next = do
  let prev = case prev0 of
               Just p => if p.frameWidth == next.frameWidth && p.frameHeight == next.frameHeight then Just p else Nothing
               Nothing => Nothing
      start = MkSt (if isNothing prev then [eraseScreen All, "\ESC[0m"] else []) Nothing Nothing
  st <- goRows prev (span 0 next.frameHeight) start
  pure (if null st.out then "" else concat (reverse ("\ESC[0m" :: st.out)))
  where
    before : Maybe Frame -> Len -> Len -> IO Cell
    before Nothing _ _ = pure blank
    before (Just p) x y = getCell p x y

    goCols : Maybe Frame -> Len -> Len -> St -> IO St
    goCols prev y x st =
      if x >= next.frameWidth then pure st else do
        c <- getCell next x y
        if c.glyph == continuation then goCols prev y (x + 1) st else do
          o <- before prev x y
          let st' = if o == c then st else emitCell (next.frameWidth) x y c st
          goCols prev y (x + glyphWidth c.glyph) st'

    goRows : Maybe Frame -> List Len -> St -> IO St
    goRows _ [] st = pure st
    goRows prev (y :: ys) st = goCols prev y 0 st >>= goRows prev ys
