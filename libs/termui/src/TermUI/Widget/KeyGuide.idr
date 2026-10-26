||| A function-key guide: a row such as `F1 Help  F2 Save  F10 Quit` that is
||| shown at the bottom of a screen. One list of hints draws the row and also
||| turns the keys and clicks into messages, so the two cannot disagree. The
||| row itself reacts to clicks; the keys go through `keyInput`.
||| See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.KeyGuide

import Data.List
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Len
import TermUI.Width
import public TermUI.Widget.Label

%default total

||| The function key (1 for F1), its label and the message it means.
public export
record Hint msg where
  constructor MkHint
  fkey : Nat
  label : Label
  action : msg

-- Two hints are one cell apart.
keyText : Hint msg -> String
keyText h = "F" ++ show h.fkey

hintWidth : Hint msg -> Len
hintWidth h = stringWidth (keyText h) + 1 + labelWidth h.label

||| The message of the hint at a column of the row, counted from its left edge.
export
keyClick : List (Hint msg) -> (column : Len) -> Maybe msg
keyClick [] _ = Nothing
keyClick (h :: rest) c =
  if c < hintWidth h then Just h.action
  else if c == hintWidth h then Nothing
  else keyClick rest (c `monus` (hintWidth h + 1))

||| The row of hints, the keys inverse. It takes the left mouse button: a click
||| on a hint sends its message. It takes no key, so Tab moves on from it.
export
keyGuide : List (Hint msg) -> Node msg
keyGuide hints = focusable (\_ => row [gap 1] (map hint hints)) clicked
  where
    hint : Hint msg -> Node msg
    hint h = row [] [ Text (withAttr Inverse plain) Truncate (keyText h), labelNode plain " " "" h.label ]

    clicked : Input -> Maybe msg
    clicked (Mouse e) =
      case (e.button, e.action) of
        (LeftButton, ButtonDown) => keyClick hints e.column
        _ => Nothing
    clicked _ = Nothing

||| The message of a function key, for an `OnInput` subscription. A key with
||| Ctrl, Alt or Shift is not taken.
export
keyInput : List (Hint msg) -> Input -> Maybe msg
keyInput hints (Press (KF n) mods) =
  if mods.ctrl || mods.alt || mods.shift then Nothing
  else map action (find (\h => h.fkey == n) hints)
keyInput _ _ = Nothing
