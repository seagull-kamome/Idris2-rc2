||| What the widgets that scroll under keys and the wheel share: the messages,
||| the arithmetic of the first visible line, and the keys.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Scrolling

import TermUI.Input
import TermUI.Len

%default total

public export
data Msg = LineUp Len | LineDown Len | PageUp | PageDown | ToStart | ToEnd

||| The first visible line after a message, for a window of `rows` lines over
||| `count` lines whose first line is `top` now. The window never goes past
||| the last line.
export
scrollTop : (rows : Len) -> (count : Len) -> (top : Len) -> Msg -> Len
scrollTop rows count top msg =
  let maxTop = count `monus` rows
      target : Len
      target = case msg of
                 LineUp k => top `monus` k
                 LineDown k => top + k
                 PageUp => top `monus` rows
                 PageDown => top + rows
                 ToStart => 0
                 ToEnd => maxTop
  in min maxTop target

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
