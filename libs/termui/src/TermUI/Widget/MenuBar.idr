||| A menu bar with drop-down menus. The bar is one row of titles; the open
||| menu drops below the active title over whatever is there. The menu is placed
||| by the box it is a child of (`absolute`, at its top left), and that box must
||| be one that does not clip it: the root of the view, or a box as tall as the
||| screen. The application leaves the first row of that box free for the bar.
||| See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.MenuBar

import Data.Fin
import Data.List
import Data.Maybe
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Width

%default total

-------------------------------------------------------------------------------
-- Model

||| An item sends its message to the application when chosen.
public export
data Entry msg = Item String msg | Separator

public export
record Menu msg where
  constructor MkMenu
  title : String
  entries : List (Entry msg)

||| `active` is the title under the cursor, `cursor` the entry of its menu.
public export
record Model msg where
  constructor MkModel
  menus : List (Menu msg)
  active : Nat
  isOpen : Bool
  cursor : Nat

||| A closed bar with the first title active.
export
fromMenus : List (Menu msg) -> Model msg
fromMenus ms = MkModel ms 0 False 0

-- 0, 1 .. n-1
upto : Nat -> List Nat
upto n = go n []
  where
    go : Nat -> List Nat -> List Nat
    go Z acc = acc
    go (S k) acc = go k (k :: acc)

selectable : Entry msg -> Bool
selectable (Item _ _) = True
selectable Separator = False

entriesOf : Model msg -> List (Entry msg)
entriesOf m = maybe [] entries (getAt m.active m.menus)

-- A title is drawn with a space on each side.
titleLeft : Nat -> List (Menu msg) -> Nat
titleLeft i ms = sum (map (\mn => stringWidth mn.title + 2) (take i ms))

-- The width of the entries of a menu, without its frame.
bodyWidth : List (Entry msg) -> Nat
bodyWidth es = foldl max 0 (map w es) + 2
  where
    w : Entry msg -> Nat
    w (Item s _) = stringWidth s
    w Separator = 0

-------------------------------------------------------------------------------
-- Update

public export
data Msg = Prev | Next | Up | Down | Open | Close | Activate | Click Nat Nat

||| The new state and, when an item was chosen, its message.
export
update : Msg -> Model msg -> (Model msg, Maybe msg)
update ev m =
  case ev of
    Prev => (switchTo (if m.active == 0 then count `minus` 1 else m.active `minus` 1) m, Nothing)
    Next => (switchTo (if S m.active >= count then 0 else S m.active) m, Nothing)
    Open => (opened m, Nothing)
    Close => (closed m, Nothing)
    Down => if m.isOpen then ({ cursor := move True } m, Nothing) else (opened m, Nothing)
    Up => if m.isOpen then ({ cursor := move False } m, Nothing) else (m, Nothing)
    Activate => if m.isOpen then pick m.cursor else (opened m, Nothing)
    Click c r =>
      if r == 0
         then case titleAt c of
                Nothing => (closed m, Nothing)
                Just i => if m.isOpen && i == m.active
                             then (closed m, Nothing)
                             else ({ isOpen := True } (switchTo i m), Nothing)
         else if m.isOpen && c >= left && c < left + bodyWidth es + 2 && r <= length es + 2
                 then (if r < 2 || r == length es + 2 then (m, Nothing) else pick (r `minus` 2))
                 else (closed m, Nothing)
  where
    count : Nat
    count = length m.menus

    es : List (Entry msg)
    es = entriesOf m

    left : Nat
    left = titleLeft m.active m.menus

    closed : Model msg -> Model msg
    closed s = { isOpen := False } s

    firstItem : Model msg -> Nat
    firstItem s = maybe 0 finToNat (findIndex selectable (entriesOf s))

    opened : Model msg -> Model msg
    opened s = { isOpen := True, cursor := firstItem s } s

    switchTo : Nat -> Model msg -> Model msg
    switchTo i s =
      let s' : Model msg
          s' = { active := i } s
      in { cursor := firstItem s' } s'

    -- The next selectable entry, going down or up and wrapping round.
    move : Bool -> Nat
    move down =
      let ix = upto (length es)
          order = if down then drop (S m.cursor) ix ++ take (S m.cursor) ix
                  else reverse (take m.cursor ix) ++ reverse (drop m.cursor ix)
      in fromMaybe m.cursor (find (\j => maybe False selectable (getAt j es)) order)

    pick : Nat -> (Model msg, Maybe msg)
    pick j =
      case getAt j es of
        Just (Item _ x) => (closed m, Just x)
        _ => (m, Nothing)

    titleAt : Nat -> Maybe Nat
    titleAt c = find (\i => c >= titleLeft i m.menus && c < titleLeft (S i) m.menus) (upto count)

-------------------------------------------------------------------------------
-- Keys

||| The message a key or a click means, which depends on whether a menu is open.
export
keyMsg : Model msg -> Input -> Maybe Msg
keyMsg m (Press key mods) =
  if mods.alt || mods.ctrl || mods.shift then Nothing
  else case key of
         KLeft => Just Prev
         KRight => Just Next
         KDown => Just Down
         KUp => Just Up
         KEnter => Just Activate
         KChar ' ' => Just Activate
         KEscape => if m.isOpen then Just Close else Nothing
         _ => Nothing
keyMsg _ (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just (Click e.column e.row)
    _ => Nothing
keyMsg _ _ = Nothing

-------------------------------------------------------------------------------
-- View

barStyle, highlight : Style
barStyle = fgColor (Indexed 0) (bgColor (Indexed 7) plain)
highlight = fgColor (Indexed 7) (bgColor (Indexed 4) plain)

||| The bar and, while the menu has the focus and one is open, its drop-down.
||| Put it among the children of the root box, after the rest of the view.
export
menuBar : (wrap : Msg -> msg) -> Model msg -> Node msg
menuBar wrap m = focusable body (\i => map wrap (keyMsg m i))
  where
    es : List (Entry msg)
    es = entriesOf m

    title : (focused : Bool) -> Nat -> Menu msg -> Node msg
    title focused i mn =
      Text (if focused && i == m.active then highlight else plain) Truncate (" " ++ mn.title ++ " ")

    line : Nat -> Entry msg -> Node msg
    line j (Item s _) = box [style (if j == m.cursor then highlight else plain)] [Text plain Truncate (" " ++ s ++ " ")]
    line _ Separator = Text plain Truncate (concat (replicate (bodyWidth es) "─"))

    dropdown : Node msg
    dropdown =
      row []
        [ box [width (Cells (titleLeft m.active m.menus))] []
        , box [border Single, style barStyle] (zipWith line (upto (length es)) es) ]

    body : Bool -> Node msg
    body focused =
      box [absolute, top 0, left 0, right 0]
        (row [style barStyle] (zipWith (title focused) (upto (length m.menus)) m.menus)
           :: (if focused && m.isOpen then [dropdown] else []))
