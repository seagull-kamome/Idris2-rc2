||| A single-line text field: a Model, its Msgs and `update`, and a `field`
||| view that takes the keyboard focus. The cursor is drawn as an inverse
||| cell. Characters are counted as one cell each, so wide characters are
||| clipped at the right edge of the field rather than scrolled correctly.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.TextInput

import Data.List
import Data.String
import TermUI.Input
import TermUI.Node
import TermUI.Style

%default total

-------------------------------------------------------------------------------
-- Model

||| The text around the cursor; `before` is reversed.
public export
record Model where
  constructor MkModel
  before, after : List Char

public export
empty : Model
empty = MkModel [] []

||| A field holding the text, with the cursor at its end.
export
fromString : String -> Model
fromString s = MkModel (reverse (unpack s)) []

export
value : Model -> String
value m = pack (reverse m.before ++ m.after)

-------------------------------------------------------------------------------
-- Update

public export
data Msg
  = Insert Char
  | InsertText String
  | Backspace
  | DeleteForward
  | MoveLeft
  | MoveRight
  | MoveHome
  | MoveEnd
  | KillToEnd
  | KillToStart

export
update : Msg -> Model -> Model
update (Insert c) m = { before $= (c ::) } m
update (InsertText s) m = { before := reverse (map flat (unpack s)) ++ m.before } m
  where
    flat : Char -> Char
    flat c = if c == '\n' || c == '\r' || c == '\t' then ' ' else c
update Backspace m = { before $= drop 1 } m
update DeleteForward m = { after $= drop 1 } m
update MoveLeft m@(MkModel (c :: bs) as) = MkModel bs (c :: as)
update MoveLeft m = m
update MoveRight m@(MkModel bs (c :: as)) = MkModel (c :: bs) as
update MoveRight m = m
update MoveHome m = MkModel [] (reverse m.before ++ m.after)
update MoveEnd m = MkModel (reverse m.after ++ m.before) []
update KillToEnd m = { after := [] } m
update KillToStart m = { before := [] } m

||| The message a key means to a text field; Enter, Tab and the keys with
||| no meaning here are left to others.
export
keyMsg : Input -> Maybe Msg
keyMsg (Paste s) = Just (InsertText s)
keyMsg (Press key mods) =
  if mods.ctrl
     then case key of
            KChar 'a' => Just MoveHome
            KChar 'e' => Just MoveEnd
            KChar 'k' => Just KillToEnd
            KChar 'u' => Just KillToStart
            KChar 'b' => Just MoveLeft
            KChar 'f' => Just MoveRight
            KChar 'h' => Just Backspace
            KChar 'd' => Just DeleteForward
            _ => Nothing
     else if mods.alt then Nothing
     else case key of
            KChar c => Just (Insert c)
            KBackspace => Just Backspace
            KDelete => Just DeleteForward
            KLeft => Just MoveLeft
            KRight => Just MoveRight
            KHome => Just MoveHome
            KEnd => Just MoveEnd
            _ => Nothing

-------------------------------------------------------------------------------
-- View

||| The field drawn `width` cells wide; with `focused` the cursor is shown.
||| Text wider than the field scrolls so that the cursor stays visible.
export
view : (cells : Nat) -> (focused : Bool) -> Model -> Node msg
view cells focused m =
  let pos = length m.before
      start = pos `minus` (cells `minus` 1)
      shownBefore = reverse (take (pos `minus` start) m.before)
      cursor = case m.after of
                 (c :: _) => c
                 [] => ' '
      tailRoom = (cells `minus` length shownBefore) `minus` 1
      cursorStyle = if focused then withAttr Inverse plain else plain
  in box [direction Row, width (Cells cells), height (Cells 1)]
       [ Text plain Truncate (pack shownBefore)
       , Text cursorStyle Truncate (singleton cursor)
       , Text plain Truncate (pack (take tailRoom (drop 1 m.after)))
       ]

||| The field as a focusable node; `wrap` turns its messages into the
||| program's.
export
field : (cells : Nat) -> (wrap : Msg -> msg) -> Model -> Node msg
field cells wrap m =
  focusable (\focused => view cells focused m) (\i => map wrap (keyMsg i))
