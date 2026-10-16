||| A multi-line text editor: a Model, its Msgs and `update`, and an `area`
||| view that takes the keyboard focus. Lines are not wrapped: the view
||| scrolls horizontally. See libs/termui/doc/design.md ("Widgets").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.TextArea

import Data.List
import Data.List1
import Data.String
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.ScrollBar
import TermUI.Width

%default total

-------------------------------------------------------------------------------
-- Model

||| The cursor line is `reverse before ++ after`; `above` and `below` hold the
||| other lines, the nearest first.
public export
record Model where
  constructor MkModel
  cells, rows : Nat                -- the size of the viewport
  top : Nat                        -- the first visible line
  left : Nat                       -- characters scrolled out on the left
  above : List (List Char)
  before, after : List Char
  below : List (List Char)
  want : Maybe Nat                 -- the column vertical moves aim at

-- Tabs become spaces; other control characters are dropped.
clean : Char -> List Char
clean c =
  if c == '\t' then [' ']
  else if charWidth c == 0 && ord c < 0xA0 then []
  else [c]

cursorWidth : Model -> Nat
cursorWidth m = case m.after of
                  (c :: _) => max 1 (charWidth c)
                  [] => 1

||| The number of lines.
export
lineCount : Model -> Nat
lineCount m = length m.above + 1 + length m.below

-- Cells from character `from` of the cursor line to the cursor, with the cursor cell.
used : Model -> Nat -> Nat
used m from = sum (map charWidth (take (length m.before `minus` from) (drop from (reverse m.before)))) + cursorWidth m

-- Scroll as little as needed to keep the cursor in the viewport.
scrolled : Model -> Model
scrolled m =
  let line = length m.above
      top = if line < m.top then line
            else if m.rows > 0 && line >= m.top + m.rows then (line + 1) `minus` m.rows
            else m.top
      pos = length m.before
  in { top := top, left := settle pos (min m.left pos) (S pos) } m
  where
    settle : Nat -> Nat -> Nat -> Nat
    settle _ from Z = from
    settle pos from (S fuel) =
      if used m from > (m.cells `minus` 1) && from < pos then settle pos (S from) fuel else from

||| An empty editor `cells` wide and `rows` high.
export
empty : (cells : Nat) -> (rows : Nat) -> Model
empty cells rows = MkModel cells rows 0 0 [] [] [] [] Nothing

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

splitAtCol : Nat -> List Char -> (List Char, List Char)
splitAtCol n l = (reverse (take n l), drop n l)

-- Fields are listed in full where the order matters.
left' : Model -> Model
left' m@(MkModel c r t l ab (b :: bs) af be w) = { before := bs, after := b :: af, want := Nothing } m
left' m =
  case m.above of
    (l :: ls) => { above := ls, before := reverse l, after := [], below := (reverse m.before ++ m.after) :: m.below, want := Nothing } m
    [] => m

right' : Model -> Model
right' m =
  case m.after of
    (a :: as) => { before := a :: m.before, after := as, want := Nothing } m
    [] => case m.below of
            (l :: ls) => { above := reverse m.before :: m.above, before := [], after := l, below := ls, want := Nothing } m
            [] => m

up' : Model -> Model
up' m =
  case m.above of
    [] => m
    (l :: ls) =>
      let col = fromMaybe' (length m.before) m.want
          (bf, af) = splitAtCol col l
      in { above := ls, before := bf, after := af
         , below := (reverse m.before ++ m.after) :: m.below, want := Just col } m
  where
    fromMaybe' : Nat -> Maybe Nat -> Nat
    fromMaybe' d Nothing = d
    fromMaybe' _ (Just x) = x

down' : Model -> Model
down' m =
  case m.below of
    [] => m
    (l :: ls) =>
      let col = fromMaybe' (length m.before) m.want
          (bf, af) = splitAtCol col l
      in { above := (reverse m.before ++ m.after) :: m.above, before := bf, after := af
         , below := ls, want := Just col } m
  where
    fromMaybe' : Nat -> Maybe Nat -> Nat
    fromMaybe' d Nothing = d
    fromMaybe' _ (Just x) = x

repeatN : Nat -> (a -> a) -> a -> a
repeatN Z _ x = x
repeatN (S k) f x = repeatN k f (f x)

-- Move to line `target` keeping the column.
gotoLine : Nat -> Model -> Model
gotoLine target m =
  let line = length m.above in
  if target < line then repeatN (line `minus` target) up' m
  else repeatN (target `minus` line) down' m

toLineEnd : Model -> Model
toLineEnd m = { before := reverse m.after ++ m.before, after := [], want := Nothing } m

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
step MoveLeft m = left' m
step MoveRight m = right' m
step MoveUp m = up' m
step MoveDown m = down' m
step LineStart m = { before := [], after := reverse m.before ++ m.after, want := Nothing } m
step LineEnd m = toLineEnd m
step PageUp m = repeatN (max 1 m.rows) up' m
step PageDown m = repeatN (max 1 m.rows) down' m
step DocStart m = repeatN (length m.above) up' ({ want := Just 0 } m)
step DocEnd m = toLineEnd (repeatN (length m.below) down' ({ want := Just 0 } m))
step KillToEnd m = { after := [], want := Nothing } m
step KillToStart m = { before := [], want := Nothing } m
step (ClickAt col row) m =
  let m1 = gotoLine (min (lineCount m `minus` 1) (m.top + row)) m
      text = reverse m1.before ++ m1.after
      idx = reach col (drop m1.left text) m1.left
  in { before := reverse (take idx text), after := drop idx text, want := Nothing } m1
  where
    reach : Nat -> List Char -> Nat -> Nat
    reach _ [] i = i
    reach c (x :: xs) i = if charWidth x > c then i else reach (c `minus` charWidth x) xs (S i)

export
update : Msg -> Model -> Model
update msg m = scrolled (step msg m)

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
      textCells = m.cells `minus` 1
      room = (textCells `minus` sum (map charWidth shown)) `minus` cursorWidth m
      cursorStyle = if focused then withAttr Inverse plain else plain
  in box [direction Row]
       [ Text plain Truncate (pack shown)
       , box (if focused then [cursorHere] else []) [Text cursorStyle Truncate (pack [under])]
       , Text plain Truncate (pack (cut room (drop 1 m.after)))
       ]
  where
    cut : Nat -> List Char -> List Char
    cut _ [] = []
    cut room (c :: cs) = if charWidth c <= room then c :: cut (room `minus` charWidth c) cs else []

||| The editor drawn `cells` x `rows`, with a scroll bar on the right; with
||| `focused` the cursor is shown.
export
view : (focused : Bool) -> Model -> Node msg
view focused m =
  let line = length m.above
      first = m.top
      lines = reverse m.above ++ [reverse m.before ++ m.after] ++ m.below
      visible = take m.rows (drop first (zip' [0 ..] lines))
  in box [direction Row, width (Cells m.cells), height (Cells m.rows)]
       [ box [grow 1] (map (\(i, l) => if i == line then cursorLine focused m else plainLine m l) visible)
       , scrollBar m.rows (lineCount m) m.top
       ]
  where
    zip' : Stream Nat -> List (List Char) -> List (Nat, List Char)
    zip' _ [] = []
    zip' (i :: is) (x :: xs) = (i, x) :: zip' is xs

||| The editor as a focusable node. `wrap` turns its messages into the program's.
export
area : (wrap : Msg -> msg) -> Model -> Node msg
area wrap m = focusable (\focused => view focused m) (\i => map wrap (keyMsg i))
