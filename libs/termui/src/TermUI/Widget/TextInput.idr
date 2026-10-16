||| A single-line text field: a Model, its Msgs and `update`, and a `field`
||| view that takes the keyboard focus. See libs/termui/doc/design.md
||| ("Widgets") for what it does and does not handle.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.TextInput

import Data.List
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Width

%default total

-------------------------------------------------------------------------------
-- Model

||| The text around the cursor (`before` is reversed), the width of the
||| field in cells, and the number of characters scrolled out on the left.
public export
record Model where
  constructor MkModel
  cells : Nat
  offset : Nat
  before, after : List Char

-- Line breaks and tabs become spaces; other control characters are dropped.
clean : Char -> List Char
clean c =
  if c == '\n' || c == '\r' || c == '\t' then [' ']
  else if charWidth c == 0 && ord c < 0xA0 then []
  else [c]

-- The cursor cell is as wide as the character under it, and at least one.
cursorWidth : Model -> Nat
cursorWidth m = case m.after of
                  (c :: _) => max 1 (charWidth c)
                  [] => 1

-- Scroll as little as needed to keep the cursor cell inside the field.
scrolled : Model -> Model
scrolled m =
  let pos = length m.before
      start = min m.offset pos
  in { offset := settle pos start (S pos) } m
  where
    -- cells from character `from` up to the cursor, with the cursor cell
    used : Nat -> Nat -> Nat
    used pos from = sum (map charWidth (take (pos `minus` from) (drop from (reverse m.before)))) + cursorWidth m

    settle : Nat -> Nat -> Nat -> Nat
    settle _ from Z = from
    settle pos from (S fuel) =
      if used pos from > m.cells && from < pos then settle pos (S from) fuel else from

||| An empty field `cells` wide.
export
empty : (cells : Nat) -> Model
empty cells = MkModel cells 0 [] []

||| A field `cells` wide holding the text, with the cursor at its end.
export
fromString : (cells : Nat) -> String -> Model
fromString cells s = scrolled (MkModel cells 0 (reverse (concatMap clean (unpack s))) [])

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

step : Msg -> Model -> Model
step (Insert c) m = { before := reverse (clean c) ++ m.before } m
step (InsertText s) m = { before := reverse (concatMap clean (unpack s)) ++ m.before } m
step Backspace m = { before $= drop 1 } m
step DeleteForward m = { after $= drop 1 } m
step MoveLeft (MkModel w o (c :: bs) as) = MkModel w o bs (c :: as)
step MoveLeft m = m
step MoveRight (MkModel w o bs (c :: as)) = MkModel w o (c :: bs) as
step MoveRight m = m
step MoveHome m = { before := [], after := reverse m.before ++ m.after } m
step MoveEnd m = { before := reverse m.after ++ m.before, after := [] } m
step KillToEnd m = { after := [] } m
step KillToStart m = { before := [] } m

export
update : Msg -> Model -> Model
update msg m = scrolled (step msg m)

||| The message a key means to a text field; Enter, Tab and the keys with
||| no meaning here are left to others.
export
keyMsg : Input -> Maybe Msg
keyMsg (Paste s) = Just (InsertText s)
keyMsg (Press key mods) =
  if mods.alt then Nothing
  else if mods.ctrl
     then case key of
            KChar 'a' => Just MoveHome
            KChar 'e' => Just MoveEnd
            KChar 'k' => Just KillToEnd
            KChar 'u' => Just KillToStart
            KChar 'b' => Just MoveLeft
            KChar 'f' => Just MoveRight
            KChar 'd' => Just DeleteForward
            _ => Nothing
     else case key of
            KChar c => Just (Insert c)
            KBackspace => Just Backspace
            KDelete => Just DeleteForward
            KLeft => Just MoveLeft
            KRight => Just MoveRight
            KHome => Just MoveHome
            KEnd => Just MoveEnd
            _ => Nothing
keyMsg _ = Nothing

-------------------------------------------------------------------------------
-- View

||| The field drawn `cells` wide; with `focused` the cursor is shown, as an
||| inverse cell (a blank one when the character under it has no width).
export
view : (focused : Bool) -> Model -> Node msg
view focused m =
  let shown = reverse (take (length m.before `minus` m.offset) m.before)
      under = case m.after of
                (c :: _) => if charWidth c == 0 then ' ' else c
                [] => ' '
      room = (m.cells `minus` sum (map charWidth shown)) `minus` cursorWidth m
      cursorStyle = if focused then withAttr Inverse plain else plain
  in box [direction Row, width (Cells m.cells), height (Cells 1)]
       [ Text plain Truncate (pack shown)
       , Text cursorStyle Truncate (pack [under])
       , Text plain Truncate (pack (cut room (drop 1 m.after)))
       ]
  where
    cut : Nat -> List Char -> List Char
    cut _ [] = []
    cut room (c :: cs) = if charWidth c <= room then c :: cut (room `minus` charWidth c) cs else []

||| The field as a focusable node. `wrap` turns its messages into the
||| program's; `submit` is the message for Enter, if Enter means something.
export
field : (wrap : Msg -> msg) -> (submit : Maybe msg) -> Model -> Node msg
field wrap submit m =
  focusable (\focused => view focused m) handler
  where
    handler : Input -> Maybe msg
    handler (Press KEnter _) = submit
    handler i = map wrap (keyMsg i)
