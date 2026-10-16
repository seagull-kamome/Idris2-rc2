||| A vertical scroll bar, shared by the widgets that scroll.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.ScrollBar

import Data.List
import Data.Nat
import TermUI.Node
import TermUI.Style

%default total

-------------------------------------------------------------------------------
-- Scroll bar

||| A bar `rows` high for `count` lines of which the window starting at `top`
||| is visible. It is blank when everything fits.
export
scrollBar : (rows : Nat) -> (count : Nat) -> (top : Nat) -> Node msg
scrollBar rows count top =
  if count <= rows || rows == 0
     then box [width (Cells 1), height (Cells rows)] []
     else
       let thumb = max 1 (ndiv (rows * rows) count)
           room = rows `minus` thumb
           maxTop = count `minus` rows
           start = ndiv (min top maxTop * room + ndiv maxTop 2) maxTop
       in column [width (Cells 1), height (Cells rows)] (map (cell start thumb) (take rows [0 ..]))
  where
    ndiv : Nat -> Nat -> Nat
    ndiv a Z = 0
    ndiv a n@(S _) = divNatNZ a n ItIsSucc

    cell : Nat -> Nat -> Nat -> Node msg
    cell start thumb i =
      if i >= start && i < start + thumb
         then Text (fgColor white plain) Truncate "█"
         else Text (fgColor (Indexed 8) plain) Truncate "│"
