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
  selected : Nat      -- index of the selected item
  top : Nat           -- index of the first visible item

export
fromList : List String -> Model
fromList items = MkModel items 0 0

||| The selected item, if the list is not empty.
export
current : Model -> Maybe String
current m = head' (drop m.selected m.items)

-------------------------------------------------------------------------------
-- Update

public export
data Msg = Up | Down | PageUp | PageDown | First | Last

||| Move the selection; `rows` is the height of the window, which scrolls to
||| keep the selection in view.
export
update : (rows : Nat) -> Msg -> Model -> Model
update rows msg m =
  let n = length m.items
      lastIx = n `minus` 1
      target = case msg of
                 Up => m.selected `minus` 1
                 Down => min lastIx (m.selected + 1)
                 PageUp => m.selected `minus` rows
                 PageDown => min lastIx (m.selected + rows)
                 First => 0
                 Last => lastIx
      top = if target < m.top then target
            else if target >= m.top + rows then (target + 1) `minus` rows
            else m.top
  in if n == 0 then m else { selected := target, top := top } m

export
keyMsg : Input -> Maybe Msg
keyMsg (Press KUp _) = Just Up
keyMsg (Press KDown _) = Just Down
keyMsg (Press KPageUp _) = Just PageUp
keyMsg (Press KPageDown _) = Just PageDown
keyMsg (Press KHome _) = Just First
keyMsg (Press KEnd _) = Just Last
keyMsg _ = Nothing

-------------------------------------------------------------------------------
-- View

||| The window of the list; the selected line is inverse when `focused` and
||| marked with `>` otherwise.
export
view : (rows : Nat) -> (focused : Bool) -> Model -> Node msg
view rows focused m =
  column [height (Cells rows)] (map (uncurry line) (indexed m.top (take rows (drop m.top m.items))))
  where
    indexed : Nat -> List a -> List (Nat, a)
    indexed _ [] = []
    indexed i (x :: xs) = (i, x) :: indexed (S i) xs

    line : Nat -> String -> Node msg
    line i item =
      if i == m.selected
         then if focused
                 then Text (withAttr Inverse plain) Truncate (" " ++ item ++ " ")
                 else Text (withAttr Bold plain) Truncate ("> " ++ item)
         else Text plain Truncate ("  " ++ item)

||| The list as a focusable node.
export
list : (rows : Nat) -> (wrap : Msg -> msg) -> Model -> Node msg
list rows wrap m =
  focusable (\focused => view rows focused m) (\i => map wrap (keyMsg i))
