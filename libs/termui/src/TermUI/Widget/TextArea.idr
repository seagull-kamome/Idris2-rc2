||| A multi-line text editor: a Model, its Msgs and `update`, and an `area`
||| view that takes the keyboard focus. See libs/termui/doc/design.md
||| ("Widgets") for what it does and does not handle.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.TextArea

import Data.List
import Data.Maybe
import Data.String
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Width
import TermUI.Widget.LineEdit
import TermUI.Widget.ScrollBar

%default total

-------------------------------------------------------------------------------
-- Model

||| The cursor line is `reverse before ++ after`; `above` and `below` hold the
||| other lines, the nearest first. `want` is the column vertical moves aim at.
public export
record Model where
  constructor MkModel
  cells, rows : Nat
  top, left : Nat
  above : List (List Char)
  before, after : List Char
  below : List (List Char)
  want : Maybe Nat

||| The number of lines.
export
lineCount : Model -> Nat
lineCount m = length m.above + 1 + length m.below

-- Scroll as little as needed to keep the cursor in the viewport; the last
-- column is the scroll bar.
scrolled : Model -> Model
scrolled m =
  let line = length m.above
      first = min m.top (lineCount m `minus` m.rows)
      top = if line < first then line
            else if m.rows > 0 && line >= first + m.rows then (line + 1) `minus` m.rows
            else first
      room = m.cells `minus` 1
      lineWidth = sum (map charWidth m.before) + sum (map charWidth m.after) + 1
      left = if lineWidth <= room then 0 else leftFor room (cursorWidth m.after) m.left m.before
  in { top := top, left := left } m

||| An empty editor `cells` wide and `rows` high.
export
empty : (cells : Nat) -> (rows : Nat) -> Model
empty cells rows = MkModel cells rows 0 0 [] [] [] [] Nothing

||| The same editor in a viewport of another size.
export
resize : (cells : Nat) -> (rows : Nat) -> Model -> Model
resize cells rows m = scrolled ({ cells := cells, rows := rows } m)

-- Text with line breaks into the lines; CR LF and a lone CR count as one break.
splitLines : String -> List (List Char)
splitLines s = go (unpack s) [] []
  where
    go : List Char -> List Char -> List (List Char) -> List (List Char)
    go [] cur acc = reverse (reverse cur :: acc)
    go ('\r' :: '\n' :: cs) cur acc = go cs [] (reverse cur :: acc)
    go ('\r' :: cs) cur acc = go cs [] (reverse cur :: acc)
    go ('\n' :: cs) cur acc = go cs [] (reverse cur :: acc)
    go (c :: cs) cur acc = go cs (reverse (clean c) ++ cur) acc

||| An editor holding the text, with the cursor at its end.
export
fromString : (cells : Nat) -> (rows : Nat) -> String -> Model
fromString cells rows s =
  case reverse (splitLines s) of
    [] => empty cells rows
    (lastLine :: before) => scrolled ({ above := before, before := reverse lastLine } (empty cells rows))

||| The text, lines joined with line breaks.
export
value : Model -> String
value m =
  joinBy "\n" (map pack (reverse m.above ++ [reverse m.before ++ m.after] ++ m.below))

-------------------------------------------------------------------------------
-- Update

public export
data Msg
  = Insert Char
  | InsertText String
  | Newline
  | Backspace
  | DeleteForward
  | MoveLeft
  | MoveRight
  | MoveUp
  | MoveDown
  | LineStart
  | LineEnd
  | PageUp
  | PageDown
  | DocStart
  | DocEnd
  | KillToEnd
  | KillToStart
  | ClickAt Nat Nat      -- column and row of the viewport

repeatN : Nat -> (a -> a) -> a -> a
repeatN Z _ x = x
repeatN (S k) f x = repeatN k f (f x)

toLineStart, toLineEnd : Model -> Model
toLineStart m = { before := [], after := reverse m.before ++ m.after, want := Nothing } m
toLineEnd m = { before := reverse m.after ++ m.before, after := [], want := Nothing } m

moveLeft, moveRight : Model -> Model
moveLeft m =
  case m.before of
    (b :: bs) => { before := bs, after := b :: m.after, want := Nothing } m
    [] => case m.above of
            (l :: ls) => { above := ls, before := reverse l, after := []
                         , below := m.after :: m.below, want := Nothing } m
            [] => m
moveRight m =
  case m.after of
    (a :: as) => { before := a :: m.before, after := as, want := Nothing } m
    [] => case m.below of
            (l :: ls) => { above := reverse m.before :: m.above, before := [], after := l
                         , below := ls, want := Nothing } m
            [] => m

-- Onto the line above or below, aiming at the remembered column. The text
-- after the cursor goes with the line left behind.
moveUp, moveDown : Model -> Model
moveUp m =
  case m.above of
    [] => m
    (l :: ls) =>
      let col = fromMaybe (length m.before) m.want in
      { above := ls, before := reverse (take col l), after := drop col l
      , below := (reverse m.before ++ m.after) :: m.below, want := Just col } m
moveDown m =
  case m.below of
    [] => m
    (l :: ls) =>
      let col = fromMaybe (length m.before) m.want in
      { above := (reverse m.before ++ m.after) :: m.above, before := reverse (take col l)
      , after := drop col l, below := ls, want := Just col } m

step : Msg -> Model -> Model
step (Insert c) m = { before := reverse (clean c) ++ m.before, want := Nothing } m
step (InsertText s) m =
  case splitLines s of
    [] => m
    (first :: more) =>
      let m1 = { before := reverse first ++ m.before, want := Nothing } m in
      foldl (\acc, l => { above := reverse acc.before :: acc.above, before := reverse l } acc) m1 more
step Newline m = { above := reverse m.before :: m.above, before := [], want := Nothing } m
step Backspace m =
  case m.before of
    (_ :: bs) => { before := bs, want := Nothing } m
    [] => case m.above of
            (l :: ls) => { above := ls, before := reverse l, want := Nothing } m
            [] => m
step DeleteForward m =
  case m.after of
    (_ :: as) => { after := as, want := Nothing } m
    [] => case m.below of
            (l :: ls) => { after := l, below := ls, want := Nothing } m
            [] => m
step MoveLeft m = moveLeft m
step MoveRight m = moveRight m
step MoveUp m = moveUp m
step MoveDown m = moveDown m
step LineStart m = toLineStart m
step LineEnd m = toLineEnd m
step PageUp m = repeatN (max 1 m.rows) moveUp m
step PageDown m = repeatN (max 1 m.rows) moveDown m
step DocStart m = toLineStart (repeatN (length m.above) moveUp ({ want := Just 0 } m))
step DocEnd m = toLineEnd (repeatN (length m.below) moveDown ({ want := Just 0 } m))
step KillToEnd m = { after := [], want := Nothing } m
step KillToStart m = { before := [], want := Nothing } m
step (ClickAt col row) m =
  if col + 1 >= m.cells then m      -- the scroll bar
  else
    let target = min (lineCount m `minus` 1) (m.top + row)
        line = length m.above
        m1 = if target < line then repeatN (line `minus` target) moveUp m
             else repeatN (target `minus` line) moveDown m
        text = reverse m1.before ++ m1.after
        idx = reach col (drop m1.left text) m1.left
    in { before := reverse (take idx text), after := drop idx text, want := Nothing } m1

||| Apply a message. PageUp and PageDown move the viewport by a page as well
||| as the cursor.
export
update : Msg -> Model -> Model
update msg m =
  let m1 = step msg m
      maxTop = lineCount m1 `minus` m1.rows
  in scrolled $ case msg of
       PageUp => { top := m.top `minus` m.rows } m1
       PageDown => { top := min maxTop (m.top + m.rows) } m1
       _ => m1

||| The message a key means to the editor; Tab and the keys with no meaning
||| here are left to others. Enter is a line break.
export
keyMsg : Input -> Maybe Msg
keyMsg (Paste s) = Just (InsertText s)
keyMsg (Press key mods) =
  if mods.alt then Nothing
  else if mods.ctrl
     then case key of
            KChar 'a' => Just LineStart
            KChar 'e' => Just LineEnd
            KChar 'k' => Just KillToEnd
            KChar 'u' => Just KillToStart
            KChar 'b' => Just MoveLeft
            KChar 'f' => Just MoveRight
            KChar 'p' => Just MoveUp
            KChar 'n' => Just MoveDown
            KChar 'd' => Just DeleteForward
            KHome => Just DocStart
            KEnd => Just DocEnd
            _ => Nothing
     else case key of
            KChar c => Just (Insert c)
            KEnter => Just Newline
            KBackspace => Just Backspace
            KDelete => Just DeleteForward
            KLeft => Just MoveLeft
            KRight => Just MoveRight
            KUp => Just MoveUp
            KDown => Just MoveDown
            KHome => Just LineStart
            KEnd => Just LineEnd
            KPageUp => Just PageUp
            KPageDown => Just PageDown
            _ => Nothing
keyMsg (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just (ClickAt e.column e.row)
    (WheelUp, _) => Just MoveUp
    (WheelDown, _) => Just MoveDown
    _ => Nothing

-------------------------------------------------------------------------------
-- View

-- A line of the viewport, from the horizontal scroll position on.
plainLine : Model -> List Char -> Node msg
plainLine m l = Text plain Truncate (pack (drop m.left l))

cursorLine : (focused : Bool) -> Model -> Node msg
cursorLine focused m =
  let shown = reverse (take (length m.before `minus` m.left) m.before)
      under = case m.after of
                (c :: _) => if charWidth c == 0 then ' ' else c
                [] => ' '
      room = ((m.cells `minus` 1) `minus` sum (map charWidth shown)) `minus` cursorWidth m.after
      cursorStyle = if focused then withAttr Inverse plain else plain
  in box [direction Row]
       [ Text plain Truncate (pack shown)
       , box (if focused then [cursorHere] else []) [Text cursorStyle Truncate (pack [under])]
       , Text plain Truncate (pack (cutTo room (drop 1 m.after)))
       ]

||| The editor drawn `cells` x `rows`, with a scroll bar on the right; with
||| `focused` the cursor is shown.
export
view : (focused : Bool) -> Model -> Node msg
view focused m =
  let line = length m.above
      shownAbove = reverse (take (line `minus` m.top) m.above)
      visible = take m.rows (map (plainLine m) shownAbove
                             ++ [cursorLine focused m]
                             ++ map (plainLine m) (take m.rows m.below))
  in box [direction Row, width (Cells m.cells), height (Cells m.rows)]
       [ box [grow 1] visible
       , scrollBar m.rows (lineCount m) m.top
       ]

||| The editor as a focusable node. `wrap` turns its messages into the program's.
export
area : (wrap : Msg -> msg) -> Model -> Node msg
area wrap m = focusable (\focused => view focused m) (\i => map wrap (keyMsg i))
