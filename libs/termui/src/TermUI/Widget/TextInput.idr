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
import TermUI.Widget.LineEdit

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

-- Line breaks become spaces too.
clean' : Char -> List Char
clean' c = if c == '\n' || c == '\r' then [' '] else clean c

-- The cleaned characters of a text, reversed, in front of `acc`.
cleanedRev : List Char -> List Char -> List Char
cleanedRev [] acc = acc
cleanedRev (c :: cs) acc = cleanedRev cs (reverse (clean' c) ++ acc)

-- Scroll as little as needed to keep the cursor cell inside the field.
scrolled : Model -> Model
scrolled m = { offset := leftFor m.cells (cursorWidth m.after) m.offset m.before } m

||| An empty field `cells` wide.
export
empty : (cells : Nat) -> Model
empty cells = MkModel cells 0 [] []

||| A field `cells` wide holding the text, with the cursor at its end.
export
fromString : (cells : Nat) -> String -> Model
fromString cells s = scrolled (MkModel cells 0 (cleanedRev (unpack s) []) [])

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
  | ClickAt Nat      -- the cell of the field that was clicked

step : Msg -> Model -> Model
step (Insert c) m = { before := reverse (clean' c) ++ m.before } m
step (InsertText s) m = { before := cleanedRev (unpack s) m.before } m
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
step (ClickAt col) m =
  let text = reverse m.before ++ m.after
      idx = reach col (drop m.offset text) m.offset
  in { before := reverse (take idx text), after := drop idx text } m

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
keyMsg (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just (ClickAt e.column)
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
      room = (m.cells `minus` sum (map charWidth shown)) `minus` cursorWidth m.after
      cursorStyle = if focused then withAttr Inverse plain else plain
  in box [direction Row, width (Cells m.cells), height (Cells 1)]
       [ Text plain Truncate (pack shown)
       , box (if focused then [cursorHere] else []) [Text cursorStyle Truncate (pack [under])]
       , Text plain Truncate (pack (cutTo room (drop 1 m.after)))
       ]

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
