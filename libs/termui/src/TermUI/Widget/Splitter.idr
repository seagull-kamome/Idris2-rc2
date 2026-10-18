||| Two panes separated by a divider that can be moved with the arrow keys or
||| by dragging it with the mouse. The first pane has a size of its own (the
||| model keeps it, in cells) and the second takes the rest. While the divider
||| is held, a transparent cover over the whole splitter takes the mouse, so
||| the drag follows the pointer inside it. The splitter wants mouse reporting
||| on (`MouseFocus`); `subs` ends a drag that is let go outside it.
||| See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Splitter

import TermUI.Input
import TermUI.Node
import TermUI.Style

%default total

-------------------------------------------------------------------------------
-- Model

||| `LeftRight`: the panes are side by side. `TopBottom`: one above the other.
public export
data Split = LeftRight | TopBottom

||| `size` is the size of the first pane along the split, kept between `lo`
||| and `hi`; `held` is true while the divider is being dragged.
public export
record Model where
  constructor MkModel
  split : Split
  size : Nat
  lo, hi : Nat
  held : Bool

||| A splitter whose first pane has the given size; it can be between 1 and 1000 cells.
export
fromSize : Split -> (size : Nat) -> Model
fromSize s n = MkModel s n 1 1000 False

||| The same with limits on the size of the first pane.
export
withLimits : (lo : Nat) -> (hi : Nat) -> Model -> Model
withLimits lo hi m = { lo := lo, hi := max lo hi, size := max lo (min hi m.size) } m

-------------------------------------------------------------------------------
-- Update

||| `Drag p`: the pointer is at `p` cells from the start of the splitter.
public export
data Msg = Shrink | Grow | Grab | Drag Nat | Release

export
update : Msg -> Model -> Model
update msg m =
  case msg of
    Shrink => resized (m.size `minus` 1)
    Grow => resized (S m.size)
    Grab => { held := True } m
    Drag p => if m.held then resized p else m
    Release => { held := False } m
  where
    resized : Nat -> Model
    resized n = { size := max m.lo (min m.hi n) } m

-- A key on the divider, and the press that picks it up.
dividerMsg : Split -> Input -> Maybe Msg
dividerMsg s (Press key mods) =
  if mods.alt || mods.ctrl || mods.shift then Nothing
  else case (s, key) of
         (LeftRight, KLeft) => Just Shrink
         (LeftRight, KRight) => Just Grow
         (TopBottom, KUp) => Just Shrink
         (TopBottom, KDown) => Just Grow
         _ => Nothing
dividerMsg _ (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just Grab
    _ => Nothing
dividerMsg _ _ = Nothing

-- What the cover over the splitter takes while the divider is held.
coverMsg : Split -> Input -> Maybe Msg
coverMsg s (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, Drag) => Just (Drag (along s e))
    (LeftButton, ButtonUp) => Just Release
    (LeftButton, ButtonDown) => Just Release
    _ => Nothing
  where
    along : Split -> MouseEvent -> Nat
    along LeftRight ev = ev.column
    along TopBottom ev = ev.row
coverMsg _ (Press KEscape _) = Just Release
coverMsg _ _ = Nothing

||| For an `OnMouse` subscription kept while `held`: a button let go anywhere,
||| also outside the splitter, ends the drag.
export
releasing : Model -> MouseEvent -> Maybe Msg
releasing m e =
  case e.action of
    ButtonUp => if m.held then Just Release else Nothing
    _ => Nothing

-------------------------------------------------------------------------------
-- View

||| The two panes with the divider between them. `name` keys the divider, so
||| that the focus stays with it while it is held; give each splitter its own.
||| The divider is blue while it has the focus or is held, grey otherwise.
export
splitter : (name : String) -> (wrap : Msg -> msg) -> Model -> (first : Node msg) -> (second : Node msg) -> Node msg
splitter name wrap m first second =
  Box ({ pDirection := dir, pGrow := 1 } defaultProps)
    ([ box [extent (Cells m.size)] [first]
     , if m.held then look True else keyed name (focusable look (\i => map wrap (dividerMsg m.split i)))
     , box [grow 1] [second] ] ++ cover)
  where
    dir : Direction
    dir = case m.split of
            LeftRight => Row
            TopBottom => Column

    extent : Dim -> Prop
    extent = case m.split of
               LeftRight => width
               TopBottom => height

    look : Bool -> Node msg
    look lit = box [extent (Cells 1), shrink 0, style (bgColor (Indexed (if lit then 4 else 8)) plain)] []

    cover : List (Node msg)
    cover =
      if m.held
         then [ keyed name (focusable (\_ => box [absolute, top 0, left 0, right 0, bottom 0] [])
                                      (\i => map wrap (coverMsg m.split i))) ]
         else []
