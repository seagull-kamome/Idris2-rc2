||| A scrolling list of strings with one selected item: Model, Msgs, `update`
||| and a `list` view that takes the keyboard focus. The window is `rows`
||| lines high and follows the selection.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Select

import Data.List
import TermUI.Input
import TermUI.Node
import TermUI.Style

%default total

-------------------------------------------------------------------------------
-- Model

public export
record Model where
  constructor MkModel
  items : List String
  selected : Nat
  top : Nat

export
fromList : List String -> Model
fromList items = MkModel items 0 0

||| Replace the items, keeping the selection where it still makes sense.
export
setItems : List String -> Model -> Model
setItems items m =
  let sel = min (length items `minus` 1) m.selected in
  MkModel items sel (min sel m.top)

||| The selected item, if the list is not empty.
export
current : Model -> Maybe String
current m = head' (drop m.selected m.items)

-------------------------------------------------------------------------------
-- Update

-- The first visible item that keeps `sel` in a window of `rows` lines.
windowTop : (rows : Nat) -> (sel : Nat) -> (top : Nat) -> Nat
windowTop rows sel top =
  if rows == 0 then top
  else if sel < top then sel
  else if sel >= top + rows then (sel + 1) `minus` rows
  else top

||| `ClickRow r`: the line `r` of the window was clicked.
public export
data Msg = Up | Down | PageUp | PageDown | First | Last | ClickRow Nat

||| Move the selection; `rows` is the height of the window, which scrolls to
||| keep the selection in view.
export
update : (rows : Nat) -> Msg -> Model -> Model
update rows msg m =
  let n = length m.items
      lastIx = n `minus` 1
      cur = min lastIx m.selected
      target = case msg of
                 Up => cur `minus` 1
                 Down => min lastIx (cur + 1)
                 PageUp => cur `minus` rows
                 PageDown => min lastIx (cur + rows)
                 First => 0
                 Last => lastIx
                 ClickRow r => min lastIx (windowTop rows cur m.top + r)
  in if n == 0 then MkModel m.items 0 0
     else MkModel m.items target (windowTop rows target m.top)

export
keyMsg : Input -> Maybe Msg
keyMsg (Press key mods) =
  if mods.alt || mods.ctrl || mods.shift then Nothing
  else case key of
         KUp => Just Up
         KDown => Just Down
         KPageUp => Just PageUp
         KPageDown => Just PageDown
         KHome => Just First
         KEnd => Just Last
         _ => Nothing
keyMsg (Mouse e) =
  case (e.button, e.action) of
    (WheelUp, _) => Just Up
    (WheelDown, _) => Just Down
    (LeftButton, ButtonDown) => Just (ClickRow e.row)
    _ => Nothing
keyMsg _ = Nothing

-------------------------------------------------------------------------------
-- View

||| The window of the list; the selected line is inverse when `focused` and
||| marked with `>` otherwise.
export
view : (rows : Nat) -> (focused : Bool) -> Model -> Node msg
view rows focused m =
  let sel = min (length m.items `minus` 1) m.selected
      top = windowTop rows sel m.top
  in column [height (Cells rows)] (map (uncurry (line sel)) (indexed top (take rows (drop top m.items))))
  where
    indexed : Nat -> List a -> List (Nat, a)
    indexed _ [] = []
    indexed i (x :: xs) = (i, x) :: indexed (S i) xs

    line : Nat -> Nat -> String -> Node msg
    line sel i item =
      if i == sel
         then if focused
                 then Text (withAttr Inverse plain) Truncate ("  " ++ item)
                 else Text (withAttr Bold plain) Truncate ("> " ++ item)
         else Text plain Truncate ("  " ++ item)

||| The list as a focusable node.
export
list : (rows : Nat) -> (wrap : Msg -> msg) -> Model -> Node msg
list rows wrap m =
  focusable (\focused => view rows focused m) (\i => map wrap (keyMsg i))
