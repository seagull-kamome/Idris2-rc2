||| A single-line text field: a Model, its Msgs and `update`, and a `field`
||| view that takes the keyboard focus. See libs/termui/doc/design.md
||| ("Widgets") for what it does and does not handle.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.TextInput

import Data.List
import Data.Maybe
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Width
import TermUI.Widget.LineEdit

%default total

-------------------------------------------------------------------------------
-- Model

||| What the last edit was, to put the typing of a word in one undo step.
public export
data Edit = NoEdit | Typing | Backspacing | Deleting | Other

||| A text and a cursor position to go back to: the characters before the
||| cursor (reversed) and after it.
public export
record Snap where
  constructor MkSnap
  sBefore, sAfter : List Char

||| The text around the cursor (`before` is reversed), the width of the
||| field in cells, and the number of characters scrolled out on the left.
||| `mark` is the other end of the selection (a character index), the cursor
||| being the first.
public export
record Model where
  constructor MkModel
  cells : Nat
  offset : Nat
  before, after : List Char
  mark : Maybe Nat
  history, future : List Snap
  lastEdit : Edit
  clip : String

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
empty cells = MkModel cells 0 [] [] Nothing [] [] NoEdit ""

||| A field `cells` wide holding the text, with the cursor at its end.
export
fromString : (cells : Nat) -> String -> Model
fromString cells s = scrolled ({ before := cleanedRev (unpack s) [] } (empty cells))

export
value : Model -> String
value m = pack (reverse m.before ++ m.after)

-------------------------------------------------------------------------------
-- Selection

-- The selected range of character indexes, if there is a selection.
selection : Model -> Maybe (Nat, Nat)
selection m =
  case m.mark of
    Nothing => Nothing
    Just mk =>
      let cur = length m.before
      in if mk == cur then Nothing else Just (min mk cur, max mk cur)

selectedText : Model -> String
selectedText m =
  case selection m of
    Nothing => ""
    Just (lo, hi) => pack (take (hi `minus` lo) (drop lo (reverse m.before ++ m.after)))

deleteSelection : Model -> Model
deleteSelection m =
  case selection m of
    Nothing => m
    Just (lo, hi) =>
      let text = reverse m.before ++ m.after
      in { before := reverse (take lo text), after := drop hi text, mark := Nothing } m

||| The text the field keeps for pasting with `Paste`, filled by `Copy` and `Cut`.
export
clipboard : Model -> String
clipboard m = m.clip

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
  | DragTo Nat       -- the same, with the button held: stretches the selection
  | Extend Msg       -- a move that stretches the selection
  | SelectAll
  | Copy
  | Cut
  | Paste
  | Undo
  | Redo

-- The cursor on the character under cell `col`.
clickAt : Nat -> Model -> Model
clickAt col m =
  let text = reverse m.before ++ m.after
      idx = reach col (drop m.offset text) m.offset
  in { before := reverse (take idx text), after := drop idx text } m

-- The moves, without regard to the selection.
move : Msg -> Model -> Model
move MoveLeft (MkModel w o (c :: bs) as k h f e cl) = MkModel w o bs (c :: as) k h f e cl
move MoveRight (MkModel w o bs (c :: as) k h f e cl) = MkModel w o (c :: bs) as k h f e cl
move MoveHome m = { before := [], after := reverse m.before ++ m.after } m
move MoveEnd m = { before := reverse m.after ++ m.before, after := [] } m
move (ClickAt col) m = clickAt col m
move (DragTo col) m = clickAt col m
move _ m = m

snapOf : Model -> Snap
snapOf m = MkSnap m.before m.after

restore : Snap -> Model -> Model
restore s m = { before := s.sBefore, after := s.sAfter, mark := Nothing, lastEdit := NoEdit } m

grouped : Edit -> Edit -> Bool
grouped Typing Typing = True
grouped Backspacing Backspacing = True
grouped Deleting Deleting = True
grouped _ _ = False

-- Make `f` an edit: a selection is replaced, the state before it is kept for
-- undo (once for a run of typed characters or of erasures). An edit that
-- changes nothing leaves the history alone.
edit : Edit -> (Model -> Model) -> Model -> Model
edit kind f m =
  let replacing = isJust (selection m)
      kept = if grouped kind m.lastEdit && not replacing
                then m
                else { history := take 100 (snapOf m :: m.history), future := [] } m
      done = f (deleteSelection kept)
      unchanged = not replacing && done.before == m.before && done.after == m.after
  in if unchanged then { mark := Nothing } m
     else { lastEdit := if replacing then Other else kind, mark := Nothing } done

-- An edit that only removes the selection when there is one, and otherwise
-- does `f`.
erasing : Edit -> (Model -> Model) -> Model -> Model
erasing kind f m = if isJust (selection m) then edit Other id m else edit kind f m

-- A move or a click: the selection goes and the next typing is a new step.
moved : Msg -> Model -> Model
moved msg m = { mark := Nothing, lastEdit := NoEdit } (move msg m)

-- A move that stretches the selection from where it started.
stretched : Msg -> Model -> Model
stretched msg m =
  let start = fromMaybe (length m.before) m.mark
      m1 = move msg m
  in { mark := if start == length m1.before then Nothing else Just start, lastEdit := NoEdit } m1

inserted : String -> Model -> Model
inserted s = edit Other (\x => { before := cleanedRev (unpack s) x.before } x)

step : Msg -> Model -> Model
step (Insert c) m = edit Typing (\x => { before := reverse (clean' c) ++ x.before } x) m
step (InsertText s) m = inserted s m
step Backspace m = erasing Backspacing (\x => { before $= drop 1 } x) m
step DeleteForward m = erasing Deleting (\x => { after $= drop 1 } x) m
step KillToEnd m = erasing Other (\x => { after := [] } x) m
step KillToStart m = erasing Other (\x => { before := [] } x) m
step (Extend x) m = stretched x m
step (DragTo col) m = stretched (DragTo col) m
step SelectAll m = stretched MoveEnd (moved MoveHome m)
step Copy m = if isJust (selection m) then { clip := selectedText m } m else m
step Cut m = if isJust (selection m) then edit Other id ({ clip := selectedText m } m) else m
step Paste m = inserted m.clip m
step Undo m =
  case m.history of
    [] => m
    (s :: rest) => restore s ({ history := rest, future := snapOf m :: m.future } m)
step Redo m =
  case m.future of
    [] => m
    (s :: rest) => restore s ({ future := rest, history := snapOf m :: m.history } m)
step msg m = moved msg m

export
update : Msg -> Model -> Model
update msg m = scrolled (step msg m)

||| The text a message copies, to hand to the clipboard of the desktop
||| (`SetClipboard`): the selection that `Copy` or `Cut` takes from the model
||| the message is about to be applied to.
export
copyText : Msg -> Model -> Maybe String
copyText Copy m = if isJust (selection m) then Just (selectedText m) else Nothing
copyText Cut m = if isJust (selection m) then Just (selectedText m) else Nothing
copyText _ _ = Nothing

||| The message a key means to a text field; Enter, Tab and the keys with
||| no meaning here are left to others. Shift stretches a move into a selection.
export
keyMsg : Input -> Maybe Msg
keyMsg (Paste s) = Just (InsertText s)
keyMsg (Press key mods) =
  if mods.alt
     then case key of
            KChar 'w' => Just Copy
            KChar 'a' => Just SelectAll
            _ => Nothing
  else if mods.ctrl
     then case key of
            KChar 'a' => Just MoveHome
            KChar 'e' => Just MoveEnd
            KChar 'k' => Just KillToEnd
            KChar 'u' => Just KillToStart
            KChar 'b' => Just MoveLeft
            KChar 'f' => Just MoveRight
            KChar 'd' => Just DeleteForward
            KChar 'w' => Just Cut
            KChar 'y' => Just Paste
            KChar '_' => Just Undo
            KChar '^' => Just Redo
            _ => Nothing
  else if mods.shift
     then maybe (plain key) (Just . Extend) (extendedKey key)
  else plain key
  where
    extendedKey : Key -> Maybe Msg
    extendedKey KLeft = Just MoveLeft
    extendedKey KRight = Just MoveRight
    extendedKey KHome = Just MoveHome
    extendedKey KEnd = Just MoveEnd
    extendedKey _ = Nothing

    plain : Key -> Maybe Msg
    plain (KChar c) = Just (Insert c)
    plain KBackspace = Just Backspace
    plain KDelete = Just DeleteForward
    plain KLeft = Just MoveLeft
    plain KRight = Just MoveRight
    plain KHome = Just MoveHome
    plain KEnd = Just MoveEnd
    plain _ = Nothing
keyMsg (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just (ClickAt e.column)
    (LeftButton, Drag) => Just (DragTo e.column)
    _ => Nothing

-------------------------------------------------------------------------------
-- View

selectionStyle : Style
selectionStyle = bgColor (Indexed 4) (fgColor white plain)

||| The field drawn `cells` wide; with `focused` the cursor is shown, as an
||| inverse cell (a blank one when the character under it has no width).
export
view : (focused : Bool) -> Model -> Node msg
view focused m =
  let pos = length m.before
      shown = reverse (take (pos `minus` m.offset) m.before)
      under = case m.after of
                (c :: _) => if charWidth c == 0 then ' ' else c
                [] => ' '
      room = (m.cells `minus` sum (map charWidth shown)) `minus` cursorWidth m.after
      chosen = selection m
      underSelected : Bool
      underSelected = maybe False (\r => fst r <= pos && pos < snd r) chosen
      cursorStyle : Style
      cursorStyle = if focused then withAttr Inverse plain
                    else if underSelected then selectionStyle else plain
  in box [direction Row, width (Cells m.cells), height (Cells 1)]
       (runs chosen m.offset shown
        ++ [box (if focused then [cursorHere] else []) [Text cursorStyle Truncate (pack [under])]]
        ++ runs chosen (S pos) (cutTo room (drop 1 m.after)))
  where
    -- the characters `chars`, which start at index `start`, as Texts, those
    -- in the selection with its style
    runs : Maybe (Nat, Nat) -> (start : Nat) -> List Char -> List (Node msg)
    runs Nothing _ chars = [Text plain Truncate (pack chars)]
    runs (Just (lo, hi)) start chars =
      let len = length chars
          a = min len (lo `minus` start)
          b = min len (hi `minus` start)
      in [ Text plain Truncate (pack (take a chars))
         , Text selectionStyle Truncate (pack (take (b `minus` a) (drop a chars)))
         , Text plain Truncate (pack (drop b chars)) ]

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
