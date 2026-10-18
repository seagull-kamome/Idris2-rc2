||| A function-key guide: a row such as `F1 Help  F2 Save  F10 Quit` that is
||| shown at the bottom of a screen. One list of hints draws the row and also
||| turns the keys and clicks into messages, so the two cannot disagree.
||| See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.KeyGuide

import Data.List
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Width

%default total

||| The function key (1 for F1), its label and the message it means.
public export
record Hint msg where
  constructor MkHint
  fkey : Nat
  label : String
  action : msg

-- Two hints are one cell apart.
keyText : Hint msg -> String
keyText h = "F" ++ show h.fkey

hintWidth : Hint msg -> Nat
hintWidth h = stringWidth (keyText h) + 1 + stringWidth h.label

||| The row of hints, the keys inverse.
export
keyGuide : List (Hint msg) -> Node msg
keyGuide hints = row [gap 1] (map hint hints)
  where
    hint : Hint msg -> Node msg
    hint h = row [] [ Text (withAttr Inverse plain) Truncate (keyText h), Text plain Truncate (" " ++ h.label) ]

||| The message of a function key, for an `OnInput` subscription. A key with
||| Ctrl, Alt or Shift is not taken.
export
keyInput : List (Hint msg) -> Input -> Maybe msg
keyInput hints (Press (KF n) mods) =
  if mods.ctrl || mods.alt || mods.shift then Nothing
  else map action (find (\h => h.fkey == n) hints)
keyInput _ _ = Nothing

||| The message of the hint at a column of the row (counted from the left edge
||| of the row), for an `OnMouse` subscription that checks the row first.
export
keyClick : List (Hint msg) -> (column : Nat) -> Maybe msg
keyClick [] _ = Nothing
keyClick (h :: rest) c =
  if c < hintWidth h then Just h.action
  else if c == hintWidth h then Nothing
  else keyClick rest (c `minus` (hintWidth h + 1))
