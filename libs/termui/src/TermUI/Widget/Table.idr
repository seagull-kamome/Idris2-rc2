||| A table that scrolls under a fixed header, with a scroll bar. The window
||| (`rows` body lines) is kept in the model; the keys and the wheel scroll as in
||| `TermUI.Widget.Scroll` (`TermUI.Widget.Scrolling`).
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Table

import Data.List
import TermUI.Input
import TermUI.Len
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Display
import TermUI.Widget.ScrollBar
import TermUI.Widget.Scrolling

%default total

public export
record Model where
  constructor MkModel
  columns : List (String, Len)
  cells : List (List String)
  rows : Len
  top : Len

||| A table with the given headers and widths, showing `rows` body lines.
export
fromRows : (columns : List (String, Len)) -> (rows : Len) -> List (List String) -> Model
fromRows columns rows cells = MkModel columns cells rows 0

||| Scroll the body.
export
update : Msg -> Model -> Model
update msg m = { top := scrollTop m.rows (count m.cells) m.top msg } m

||| The same table with a window of another height.
export
resize : (rows : Len) -> Model -> Model
resize rows m = { rows := rows, top := min m.top (count m.cells `monus` rows) } m

||| The header, then the window of the body with the scroll bar on its right.
export
view : Model -> Node msg
view m =
  let first = min m.top (count m.cells `monus` m.rows) in
  column []
       [ tableRow (withAttr Bold plain) m.columns (map fst m.columns)
       , box [direction Row, height (Cells m.rows)]
           [ column [grow 1] (map (tableRow plain m.columns) (take (cast m.rows) (drop (cast first) m.cells)))
           , scrollBar m.rows (count m.cells) first
           ]
       ]

||| The table as a focusable node.
export
table : (wrap : Msg -> msg) -> Model -> Node msg
table wrap m = focusable (\_ => view m) (\i => map wrap (keyMsg i))
