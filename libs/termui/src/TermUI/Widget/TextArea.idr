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

||| What the last edit was, to put the typing of a word in one undo step.
public export
data Edit = NoEdit | Typing | Backspacing | Deleting | Other

||| A text and a cursor position to go back to.
public export
record Snap where
  constructor MkSnap
  sAbove : List (List Char)
  sBefore, sAfter : List Char
  sBelow : List (List Char)
  sLine, sCount : Nat

||| The cursor line is `reverse before ++ after`; `above` and `below` hold the
||| other lines, the nearest first. `line` is the number of the cursor line and
||| `count` the number of lines. `want` is the column in cells that vertical
||| moves aim at. `mark` is the other end of the selection (line and column in
||| characters), the cursor being the first.
public export
record Model where
  constructor MkModel
  cells, rows : Nat
  top, left : Nat
  above : List (List Char)
  before, after : List Char
  below : List (List Char)
  line, count : Nat
  want : Maybe Nat
  mark : Maybe (Nat, Nat)
  history, future : List Snap
  lastEdit : Edit
  clip : String

||| The number of lines.
export
lineCount : Model -> Nat
lineCount m = m.count

-- Scroll as little as needed to keep the cursor in the viewport; the last
-- column is the scroll bar.
scrolled : Model -> Model
scrolled m =
  let first = min m.top (m.count `minus` m.rows)
      top = if m.line < first then m.line
            else if m.rows > 0 && m.line >= first + m.rows then (m.line + 1) `minus` m.rows
            else first
      room = m.cells `minus` 1
      lineWidth = sum (map charWidth m.before) + sum (map charWidth m.after) + 1
      left = if lineWidth <= room then 0 else leftFor room (cursorWidth m.after) m.left m.before
  in { top := top, left := left } m

||| An empty editor `cells` wide and `rows` high.
export
empty : (cells : Nat) -> (rows : Nat) -> Model
empty cells rows = MkModel cells rows 0 0 [] [] [] [] 0 1 Nothing Nothing [] [] NoEdit ""

||| The same editor in a viewport of another size.
export
resize : (cells : Nat) -> (rows : Nat) -> Model -> Model
resize cells rows m = scrolled ({ cells := cells, rows := rows } m)

-- All the lines.
flatten : Model -> List (List Char)
flatten m = reverse m.above ++ [reverse m.before ++ m.after] ++ m.below

-- The zipper of `lines` with the cursor at the line and column (in characters).
build : List (List Char) -> (line : Nat) -> (col : Nat) -> Model -> Model
build ls ln col m =
  let cur = fromMaybe [] (getAt ln ls) in
  { above := reverse (take ln ls), before := reverse (take col cur), after := drop col cur
  , below := drop (S ln) ls, line := ln, count := length ls, want := Nothing } m

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
  let ls = splitLines s
      ln = length ls `minus` 1
  in scrolled (build ls ln (length (fromMaybe [] (getAt ln ls))) (empty cells rows))

||| The text, lines joined with line breaks.
export
value : Model -> String
value m = joinBy "\n" (map pack (flatten m))

-------------------------------------------------------------------------------
-- Selection

position : Model -> (Nat, Nat)
position m = (m.line, length m.before)

earlier : (Nat, Nat) -> (Nat, Nat) -> Bool
earlier (l1, c1) (l2, c2) = l1 < l2 || (l1 == l2 && c1 < c2)

-- The selected range, first end first, if there is a selection.
selection : Model -> Maybe ((Nat, Nat), (Nat, Nat))
selection m =
  case m.mark of
    Nothing => Nothing
    Just mk =>
      let cur = position m in
      if mk == cur then Nothing
      else Just (if earlier mk cur then (mk, cur) else (cur, mk))

-- The text of a range of lines.
slice : ((Nat, Nat), (Nat, Nat)) -> List (List Char) -> String
slice ((l1, c1), (l2, c2)) ls =
  joinBy "\n" (map pack (pieces (take (S (l2 `minus` l1)) (drop l1 ls))))
  where
    lastTo : List (List Char) -> List (List Char)
    lastTo [] = []
    lastTo [y] = [take c2 y]
    lastTo (y :: ys) = y :: lastTo ys

    pieces : List (List Char) -> List (List Char)
    pieces [] = []
    pieces [x] = [take (c2 `minus` c1) (drop c1 x)]
    pieces (x :: xs) = drop c1 x :: lastTo xs

||| The selected text, empty when nothing is selected.
export
selectedText : Model -> String
selectedText m = maybe "" (\r => slice r (flatten m)) (selection m)

-- Remove the selected text; the cursor goes to where it was.
deleteSelection : Model -> Model
deleteSelection m =
  case selection m of
    Nothing => m
    Just ((l1, c1), (l2, c2)) =>
      let ls = flatten m
          merged = take c1 (fromMaybe [] (getAt l1 ls)) ++ drop c2 (fromMaybe [] (getAt l2 ls))
      in build (take l1 ls ++ [merged] ++ drop (S l2) ls) l1 c1 ({ mark := Nothing } m)

-------------------------------------------------------------------------------
-- Moves

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
            (l :: ls) => { above := ls, before := reverse l, after := [], below := m.after :: m.below
                         , line $= (`minus` 1), want := Nothing } m
            [] => m
moveRight m =
  case m.after of
    (a :: as) => { before := a :: m.before, after := as, want := Nothing } m
    [] => case m.below of
            (l :: ls) => { above := reverse m.before :: m.above, before := [], after := l, below := ls
                         , line $= S, want := Nothing } m
            [] => m

-- The column in cells that a vertical move aims at.
aim : Model -> Nat
aim m = fromMaybe (sum (map charWidth m.before)) m.want

-- Onto the line above or below, at the same column in cells. The text after
-- the cursor goes with the line left behind.
moveUp, moveDown : Model -> Model
moveUp m =
  case m.above of
    [] => m
    (l :: ls) =>
      let idx = reach (aim m) l 0 in
      { above := ls, before := reverse (take idx l), after := drop idx l
      , below := (reverse m.before ++ m.after) :: m.below, line $= (`minus` 1), want := Just (aim m) } m
moveDown m =
  case m.below of
    [] => m
    (l :: ls) =>
      let idx = reach (aim m) l 0 in
      { above := (reverse m.before ++ m.after) :: m.above, before := reverse (take idx l)
      , after := drop idx l, below := ls, line $= S, want := Just (aim m) } m

-------------------------------------------------------------------------------
-- Messages

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
  | DragTo Nat Nat       -- the same, with the button held: stretches the selection
  | Extend Msg           -- a move that stretches the selection
  | SelectAll
  | Copy
  | Cut
  | Paste
  | Undo
  | Redo

-- The moves, without regard to the selection.
move : Msg -> Model -> Model
move MoveLeft m = moveLeft m
move MoveRight m = moveRight m
move MoveUp m = moveUp m
move MoveDown m = moveDown m
move LineStart m = toLineStart m
move LineEnd m = toLineEnd m
move PageUp m = repeatN (max 1 m.rows) moveUp m
move PageDown m = repeatN (max 1 m.rows) moveDown m
move DocStart m = toLineStart (repeatN m.line moveUp ({ want := Just 0 } m))
move DocEnd m = toLineEnd (repeatN (m.count `minus` (m.line + 1)) moveDown ({ want := Just 0 } m))
move _ m = m

-- Which way a page message moves the viewport (True: down).
page : Msg -> Maybe Bool
page PageDown = Just True
page PageUp = Just False
page (Extend x) = page x
page _ = Nothing

-- Put the cursor under the cell of the viewport.
clickAt : Nat -> Nat -> Model -> Model
clickAt col row m =
  let target = min (m.count `minus` 1) (m.top + row)
      m1 = if target < m.line then repeatN (m.line `minus` target) moveUp m
           else repeatN (target `minus` m.line) moveDown m
      text = reverse m1.before ++ m1.after
      idx = reach col (drop m1.left text) m1.left
  in { before := reverse (take idx text), after := drop idx text, want := Nothing } m1

-- Text with line breaks inserted at the cursor.
insertText : String -> Model -> Model
insertText s m =
  case splitLines s of
    [] => m
    (first :: more) =>
      let m1 = { before := reverse first ++ m.before, want := Nothing } m in
      foldl (\acc, l => { above := reverse acc.before :: acc.above, before := reverse l
                        , line $= S, count $= S } acc) m1 more

-------------------------------------------------------------------------------
-- Editing and undo

snapOf : Model -> Snap
snapOf m = MkSnap m.above m.before m.after m.below m.line m.count

restore : Snap -> Model -> Model
restore s m =
  { above := s.sAbove, before := s.sBefore, after := s.sAfter, below := s.sBelow
  , line := s.sLine, count := s.sCount, want := Nothing, mark := Nothing, lastEdit := NoEdit } m

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
      unchanged = not replacing && done.line == m.line && done.count == m.count
                  && done.before == m.before && done.after == m.after
  in if unchanged then { mark := Nothing } m
     else { lastEdit := if replacing then Other else kind, mark := Nothing } done

-- An edit that only removes the selection when there is one, and otherwise
-- does `f`.
erasing : Edit -> (Model -> Model) -> Model -> Model
erasing kind f m = if isJust (selection m) then edit Other id m else edit kind f m

-- A move or a click: the selection goes and the next typing is a new step.
moved : (Model -> Model) -> Model -> Model
moved f m = { mark := Nothing, lastEdit := NoEdit } (f m)

-- A move that stretches the selection from where it started.
stretched : (Model -> Model) -> Model -> Model
stretched f m =
  let start = fromMaybe (position m) m.mark
      m1 = f m
  in { mark := if start == position m1 then Nothing else Just start, lastEdit := NoEdit } m1

step : Msg -> Model -> Model
step (Insert c) m = edit Typing (\x => { before := reverse (clean c) ++ x.before, want := Nothing } x) m
step (InsertText s) m = edit Other (insertText s) m
step Newline m =
  edit Other (\x => { above := reverse x.before :: x.above, before := [], line $= S, count $= S, want := Nothing } x) m
step Backspace m = erasing Backspacing erase m
  where
    erase : Model -> Model
    erase x =
      case x.before of
        (_ :: bs) => { before := bs, want := Nothing } x
        [] => case x.above of
                (l :: ls) => { above := ls, before := reverse l, line $= (`minus` 1)
                             , count $= (`minus` 1), want := Nothing } x
                [] => x
step DeleteForward m = erasing Deleting erase m
  where
    erase : Model -> Model
    erase x =
      case x.after of
        (_ :: as) => { after := as, want := Nothing } x
        [] => case x.below of
                (l :: ls) => { after := l, below := ls, count $= (`minus` 1), want := Nothing } x
                [] => x
step KillToEnd m = erasing Other (\x => { after := [], want := Nothing } x) m
step KillToStart m = erasing Other (\x => { before := [], want := Nothing } x) m
-- the last column is the scroll bar: a click there does nothing, a drag over it stops at the text
step (ClickAt col row) m = if col + 1 >= m.cells then m else moved (clickAt col row) m
step (DragTo col row) m = stretched (clickAt (min col (m.cells `minus` 2)) row) m
step (Extend x) m = stretched (move x) m
step SelectAll m = stretched (move DocEnd) (moved (move DocStart) m)
step Copy m = if isJust (selection m) then { clip := selectedText m } m else m
step Cut m = if isJust (selection m) then edit Other id ({ clip := selectedText m } m) else m
step Paste m = edit Other (insertText m.clip) m
step Undo m =
  case m.history of
    [] => m
    (s :: rest) => restore s ({ history := rest, future := snapOf m :: m.future } m)
step Redo m =
  case m.future of
    [] => m
    (s :: rest) => restore s ({ future := rest, history := snapOf m :: m.history } m)
step msg m = moved (move msg) m

||| Apply a message. PageUp and PageDown move the viewport by a page as well
||| as the cursor.
export
update : Msg -> Model -> Model
update msg m =
  let m1 = step msg m
      maxTop = m1.count `minus` m1.rows
  in scrolled $ case page msg of
       Just True => { top := min maxTop (m.top + m.rows) } m1
       Just False => { top := m.top `minus` m.rows } m1
       Nothing => m1

||| The text the editor keeps for pasting with `Paste`, filled by `Copy` and `Cut`.
export
clipboard : Model -> String
clipboard m = m.clip

-- The move a key with Shift stands for.
extendedKey : Key -> Maybe Msg
extendedKey KLeft = Just MoveLeft
extendedKey KRight = Just MoveRight
extendedKey KUp = Just MoveUp
extendedKey KDown = Just MoveDown
extendedKey KHome = Just LineStart
extendedKey KEnd = Just LineEnd
extendedKey KPageUp = Just PageUp
extendedKey KPageDown = Just PageDown
extendedKey _ = Nothing

||| The message a key means to the editor; Tab and the keys with no meaning
||| here are left to others. Enter is a line break.
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
            KChar 'a' => Just LineStart
            KChar 'e' => Just LineEnd
            KChar 'k' => Just KillToEnd
            KChar 'u' => Just KillToStart
            KChar 'b' => Just MoveLeft
            KChar 'f' => Just MoveRight
            KChar 'p' => Just MoveUp
            KChar 'n' => Just MoveDown
            KChar 'd' => Just DeleteForward
            KChar 'w' => Just Cut
            KChar 'y' => Just Paste
            KChar '_' => Just Undo
            KChar '^' => Just Redo
            KHome => Just (if mods.shift then Extend DocStart else DocStart)
            KEnd => Just (if mods.shift then Extend DocEnd else DocEnd)
            _ => Nothing
  else if mods.shift
     then maybe (plain key) (Just . Extend) (extendedKey key)
  else plain key
  where
    plain : Key -> Maybe Msg
    plain (KChar c) = Just (Insert c)
    plain KEnter = Just Newline
    plain KBackspace = Just Backspace
    plain KDelete = Just DeleteForward
    plain KLeft = Just MoveLeft
    plain KRight = Just MoveRight
    plain KUp = Just MoveUp
    plain KDown = Just MoveDown
    plain KHome = Just LineStart
    plain KEnd = Just LineEnd
    plain KPageUp = Just PageUp
    plain KPageDown = Just PageDown
    plain _ = Nothing
keyMsg (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just (ClickAt e.column e.row)
    (LeftButton, Drag) => Just (DragTo e.column e.row)
    (WheelUp, _) => Just MoveUp
    (WheelDown, _) => Just MoveDown
    _ => Nothing

-------------------------------------------------------------------------------
-- View

selectionStyle : Style
selectionStyle = bgColor (Indexed 4) (fgColor white plain)

-- The part of line `idx` (`len` characters long) that is selected, as a range
-- of character indexes, and whether its line break is.
selectedPart : Maybe ((Nat, Nat), (Nat, Nat)) -> (idx : Nat) -> (len : Nat) -> Maybe (Nat, Nat, Bool)
selectedPart selected idx len =
  case selected of
    Nothing => Nothing
    Just ((l1, c1), (l2, c2)) =>
      if idx < l1 || idx > l2 then Nothing
      else Just (if idx == l1 then c1 else 0, if idx == l2 then c2 else len, idx < l2)

-- A character with its style and whether it is the cursor.
Cell : Type
Cell = (Char, Style, Bool)

-- The cells that fit in `room` cells.
fitting : Nat -> List Cell -> List Cell
fitting _ [] = []
fitting room (c@(ch, _, _) :: cs) =
  if charWidth ch <= room then c :: fitting (room `minus` charWidth ch) cs else []

-- Runs of equal style and kind.
spans : List Cell -> List (Style, Bool, List Char)
spans [] = []
spans ((ch, st, cur) :: rest) =
  case spans rest of
    ((st', cur', cs) :: more) => if st' == st && cur' == cur && not cur
                                    then (st, cur, ch :: cs) :: more
                                    else (st, cur, [ch]) :: (st', cur', cs) :: more
    [] => [(st, cur, [ch])]

lineView : (focused : Bool) -> Model -> Maybe ((Nat, Nat), (Nat, Nat)) -> (idx : Nat) -> List Char -> Node msg
lineView focused m selected idx chars =
  let len = length chars
      sel = selectedPart selected idx len
      cursorAt = if idx == m.line then Just (length m.before) else Nothing
      cursorStyle = if focused then withAttr Inverse plain else plain
      styleOf = \k => if focused && cursorAt == Just k then cursorStyle
                      else case sel of
                             Just (lo, hi, _) => if k >= lo && k < hi then selectionStyle else plain
                             Nothing => plain
      onCursor = \k => focused && cursorAt == Just k
      shown = map (\(k, ch) => (if onCursor k && charWidth ch == 0 then ' ' else ch, styleOf k, onCursor k))
                  (indexed m.left (cutTo m.cells (drop m.left chars)))
      end = if focused && cursorAt == Just len
               then [(' ', cursorStyle, True)]
               else case sel of
                      Just (_, _, True) => [(' ', selectionStyle, False)]
                      _ => []
  in box [direction Row] (map node (spans (fitting (m.cells `minus` 1) (shown ++ end))))
  where
    indexed : Nat -> List a -> List (Nat, a)
    indexed i xs = reverse (go i xs [])
      where
        go : Nat -> List a -> List (Nat, a) -> List (Nat, a)
        go _ [] acc = acc
        go j (y :: ys) acc = go (S j) ys ((j, y) :: acc)

    node : (Style, Bool, List Char) -> Node msg
    node (st, cur, cs) =
      if cur then box [cursorHere, shrink 0] [Text st Truncate (pack cs)]
      else Text st Truncate (pack cs)

||| The editor drawn `cells` x `rows`, with a scroll bar on the right; with
||| `focused` the cursor is shown.
export
view : (focused : Bool) -> Model -> Node msg
view focused m =
  let aboveShown = reverse (take (m.line `minus` m.top) m.above)
      numbered = zip' m.top (aboveShown ++ [reverse m.before ++ m.after] ++ take m.rows m.below)
      selected = selection m
      visible = take m.rows (map (\(i, l) => lineView focused m selected i l) numbered)
  in box [direction Row, width (Cells m.cells), height (Cells m.rows)]
       [ box [grow 1] visible
       , scrollBar m.rows m.count m.top
       ]
  where
    zip' : Nat -> List a -> List (Nat, a)
    zip' _ [] = []
    zip' i (x :: xs) = (i, x) :: zip' (S i) xs

||| The editor as a focusable node. `wrap` turns its messages into the program's.
export
area : (wrap : Msg -> msg) -> Model -> Node msg
area wrap m = focusable (\focused => view focused m) (\i => map wrap (keyMsg i))
