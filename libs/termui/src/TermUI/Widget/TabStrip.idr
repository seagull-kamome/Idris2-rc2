||| A strip of tabs: `One | Two | Three` with one tab active. The strip only
||| says which tab is active; the application shows the content of that tab,
||| or lets `tabbed` do it. A strip wider than its box is cut at the edge.
||| See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.TabStrip

import Data.List
import Data.Maybe
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Width

%default total

-------------------------------------------------------------------------------
-- Model

public export
record Model where
  constructor MkModel
  titles : List String
  active : Nat

||| A strip with the first tab active.
export
fromTitles : List String -> Model
fromTitles ts = MkModel ts 0

-- A title is drawn with a space on each side, tabs are one cell apart.
tabWidth : String -> Nat
tabWidth t = stringWidth t + 2

tabLeft : Nat -> List String -> Nat
tabLeft i ts = sum (map (\t => tabWidth t + 1) (take i ts))

-- 0, 1 .. n-1
upto : Nat -> List Nat
upto n = go n []
  where
    go : Nat -> List Nat -> List Nat
    go Z acc = acc
    go (S k) acc = go k (k :: acc)

-------------------------------------------------------------------------------
-- Update

||| `Click c`: the column `c` of the strip was clicked.
public export
data Msg = Prev | Next | First | Last | Click Nat

export
update : Msg -> Model -> Model
update msg m =
  case msg of
    Prev => { active := m.active `minus` 1 } m
    Next => { active := min (S m.active) lastTab } m
    First => { active := 0 } m
    Last => { active := lastTab } m
    Click c => maybe m (\i => MkModel m.titles i) (find (\i => c >= tabLeft i m.titles && c < tabLeft i m.titles + maybe 0 tabWidth (getAt i m.titles)) (upto (length m.titles)))
  where
    lastTab : Nat
    lastTab = length m.titles `minus` 1

||| The key or click a strip with the focus takes.
export
keyMsg : Input -> Maybe Msg
keyMsg (Press key mods) =
  if mods.alt || mods.ctrl || mods.shift then Nothing
  else case key of
         KLeft => Just Prev
         KRight => Just Next
         KHome => Just First
         KEnd => Just Last
         _ => Nothing
keyMsg (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => Just (Click e.column)
    _ => Nothing
keyMsg _ = Nothing

-------------------------------------------------------------------------------
-- View

||| The strip as a focusable node: the active tab is inverse while the strip
||| has the focus, and bold and underlined otherwise.
export
tabStrip : (wrap : Msg -> msg) -> Model -> Node msg
tabStrip wrap m = focusable body (\i => map wrap (keyMsg i))
  where
    tab : (focused : Bool) -> Nat -> String -> Node msg
    tab focused i t =
      Text (if i == m.active then (if focused then withAttr Inverse plain else withAttr Underline (withAttr Bold plain)) else plain)
        Truncate (" " ++ t ++ " ")

    body : Bool -> Node msg
    body focused =
      row [] (intersperse (Text (withAttr Dim plain) Truncate "│") (zipWith (tab focused) (upto (length m.titles)) m.titles))

||| The strip above a framed pane showing the content of the active tab (an
||| empty pane if there is none). `contents` is in the order of the titles.
export
tabbed : (wrap : Msg -> msg) -> Model -> (contents : List (Node msg)) -> Node msg
tabbed wrap m contents =
  column [grow 1]
    [ tabStrip wrap m
    , box [border Single, grow 1] (maybe [] (\c => [c]) (getAt m.active contents)) ]
