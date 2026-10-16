||| A read-only scrolling view of lines of text with a scroll bar. See
||| libs/termui/doc/design.md ("Widgets").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Scroll

import Data.List
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.ScrollBar

%default total

-------------------------------------------------------------------------------
-- Viewer

public export
record Model where
  constructor MkModel
  lines : List String
  top : Nat

export
fromLines : List String -> Model
fromLines ls = MkModel ls 0

public export
data Msg = LineUp Nat | LineDown Nat | PageUp | PageDown | ToStart | ToEnd

||| Scroll; `rows` is the height of the window. The window never goes past the
||| last line.
export
update : (rows : Nat) -> Msg -> Model -> Model
update rows msg (MkModel ls cur) =
  let maxTop = length ls `minus` rows
      target : Nat
      target = case msg of
                 LineUp k => cur `minus` k
                 LineDown k => cur + k
                 PageUp => cur `minus` rows
                 PageDown => cur + rows
                 ToStart => 0
                 ToEnd => maxTop
  in MkModel ls (min maxTop target)

||| Arrows, PageUp/PageDown, Home/End and the wheel (three lines a notch).
export
keyMsg : Input -> Maybe Msg
keyMsg (Press key mods) =
  if mods.alt || mods.ctrl || mods.shift then Nothing
  else case key of
         KUp => Just (LineUp 1)
         KDown => Just (LineDown 1)
         KPageUp => Just PageUp
         KPageDown => Just PageDown
         KHome => Just ToStart
         KEnd => Just ToEnd
         _ => Nothing
keyMsg (Mouse e) =
  case e.button of
    WheelUp => Just (LineUp 3)
    WheelDown => Just (LineDown 3)
    _ => Nothing
keyMsg _ = Nothing

||| The window of `rows` lines with the scroll bar on its right.
export
view : (rows : Nat) -> Model -> Node msg
view rows m =
  let first = min m.top (length m.lines `minus` rows) in
  box [direction Row, height (Cells rows)]
    [ box [grow 1] (map (Text plain Truncate) (take rows (drop first m.lines)))
    , scrollBar rows (length m.lines) first
    ]

||| The viewer as a focusable node, so that the keys and the wheel reach it.
export
viewer : (rows : Nat) -> (wrap : Msg -> msg) -> Model -> Node msg
viewer rows wrap m = focusable (\_ => view rows m) (\i => map wrap (keyMsg i))
