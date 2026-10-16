||| A scrolling list of strings with one selected item: Model, Msgs, `update`
||| and a `list` view that takes the keyboard focus, with a scroll bar. The
||| window is `rows` lines high, kept in the model, and follows the selection.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Select

import Data.List
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.ScrollBar

%default total

-------------------------------------------------------------------------------
-- Model

public export
record Model where
  constructor MkModel
  rows : Nat
  items : List String
  selected : Nat
  top : Nat

||| A list showing `rows` lines at a time.
export
fromList : (rows : Nat) -> List String -> Model
fromList rows items = MkModel rows items 0 0

-- The first visible item that keeps `sel` in a window of `rows` lines.
windowTop : (rows : Nat) -> (sel : Nat) -> (top : Nat) -> Nat
windowTop rows sel top =
  if rows == 0 then top
  else if sel < top then sel
  else if sel >= top + rows then (sel + 1) `minus` rows
  else top

||| The same list in a window of another height.
export
resize : (rows : Nat) -> Model -> Model
resize rows m =
  { rows := rows
  , top := min (windowTop rows m.selected m.top) (length m.items `minus` rows) } m

||| Replace the items, keeping the selection where it still makes sense.
export
setItems : List String -> Model -> Model
setItems items m =
  let sel = min (length items `minus` 1) m.selected in
  MkModel m.rows items sel (min (windowTop m.rows sel (min sel m.top)) (length items `minus` m.rows))

||| The selected item, if the list is not empty.
export
current : Model -> Maybe String
current m = head' (drop m.selected m.items)

-------------------------------------------------------------------------------
-- Update

||| `ClickRow r`: the line `r` of the window was clicked.
public export
data Msg = Up | Down | PageUp | PageDown | First | Last | ClickRow Nat

||| Move the selection; the window scrolls to keep it in view.
export
update : Msg -> Model -> Model
update msg m =
  let n = length m.items
      lastIx = n `minus` 1
      cur = min lastIx m.selected
      first = windowTop m.rows cur m.top
      target = case msg of
                 Up => cur `minus` 1
                 Down => min lastIx (cur + 1)
                 PageUp => cur `minus` m.rows
                 PageDown => min lastIx (cur + m.rows)
                 First => 0
                 Last => lastIx
                 ClickRow r => if first + r > lastIx then cur else first + r
  in if n == 0 then MkModel m.rows m.items 0 0
     else MkModel m.rows m.items target (windowTop m.rows target m.top)

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

-- The lines of the window; the selected one is inverse when `focused` and
-- marked with `>` otherwise.
body : (focused : Bool) -> Model -> Node msg
body focused m =
  let sel = min (length m.items `minus` 1) m.selected
      first = windowTop m.rows sel m.top
  in column [grow 1, height (Cells m.rows)]
       (map (uncurry (line sel)) (indexed first (take m.rows (drop first m.items))))
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

bar : Model -> Node msg
bar m = scrollBar m.rows (length m.items) (windowTop m.rows (min (length m.items `minus` 1) m.selected) m.top)

||| The window of the list with a scroll bar on its right.
export
view : (focused : Bool) -> Model -> Node msg
view focused m = box [direction Row, height (Cells m.rows)] [body focused m, bar m]

||| The list as a focusable node; the scroll bar is outside of what takes the
||| keyboard and the mouse.
export
list : (wrap : Msg -> msg) -> Model -> Node msg
list wrap m =
  box [direction Row, height (Cells m.rows)]
    [ focusable (\focused => body focused m) (\i => map wrap (keyMsg i))
    , bar m ]
