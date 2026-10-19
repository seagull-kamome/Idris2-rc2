||| A read-only scrolling view of lines of text with a scroll bar; the messages
||| (`Msg`, `LineDown` ...) are those of `TermUI.Widget.Scrolling`. See
||| libs/termui/doc/design.md ("Widgets").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Scroll

import Data.List
import TermUI.Input
import TermUI.Len
import TermUI.Node
import TermUI.Style
import public TermUI.Widget.Scrolling
import TermUI.Widget.ScrollBar

%default total

-------------------------------------------------------------------------------
-- Viewer

public export
record Model where
  constructor MkModel
  rows : Len
  lines : List String
  top : Len

||| A viewer showing `rows` lines at a time.
export
fromLines : (rows : Len) -> List String -> Model
fromLines rows ls = MkModel rows ls 0

||| Scroll.
export
update : Msg -> Model -> Model
update msg m = { top := scrollTop m.rows (count m.lines) m.top msg } m

||| The same viewer with a window of another height.
export
resize : (rows : Len) -> Model -> Model
resize rows m = { rows := rows, top := min m.top (count m.lines `monus` rows) } m

||| The window with the scroll bar on its right.
export
view : Model -> Node msg
view m =
  let first = min m.top (count m.lines `monus` m.rows) in
  box [direction Row, height (Cells m.rows)]
    [ box [grow 1] (map (Text plain Truncate) (take (cast m.rows) (drop (cast first) m.lines)))
    , scrollBar m.rows (count m.lines) first
    ]

||| The viewer as a focusable node, so that the keys and the wheel reach it.
export
viewer : (wrap : Msg -> msg) -> Model -> Node msg
viewer wrap m = focusable (\_ => view m) (\i => map wrap (keyMsg i))
