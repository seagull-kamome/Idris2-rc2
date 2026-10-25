||| A log: styled text that grows at the end and is shown a window at a time
||| with a scroll bar, for a chat or the messages of a game. Appended text is
||| wrapped once and kept as lines (and wrapped again when the width changes).
||| Appending and viewing are linear in the number of lines, and the log has
||| no limit: a program that runs for long keeps the end of it. While the
||| window is at the end it follows new text; scrolling up stops that, and
||| scrolling back to the end starts it again. The size is the program's to
||| give, from `OnResize`: the log wraps to the width less the scroll bar (to a
||| character a line when that is 0 or 1). The messages (`Msg`, `LineDown` ...) are those of
||| `TermUI.Widget.Scrolling`. See libs/termui/doc/design.md ("Widgets").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.LogView

import Data.List
import TermUI.Input
import TermUI.Len
import TermUI.Node
import TermUI.Style
import public TermUI.Widget.Scrolling
import TermUI.Widget.ScrollBar
import TermUI.Widget.StyledText

%default covering

public export
record Model where
  constructor MkModel
  rows : Len                  -- the height of the window
  width : Len                 -- the width of the window, scroll bar included
  paras : List Para
  lines : List (List Span)    -- `paras` wrapped to the width less the bar
  top : Len                   -- the first line shown
  follow : Bool               -- the window stays at the end

textWidth : Len -> Len
textWidth w = w `monus` 1

lastTop : Model -> Len
lastTop m = count m.lines `monus` m.rows

||| An empty log in a window `rows` high and `width` wide.
export
empty : (rows, width : Len) -> Model
empty rows width = MkModel (nonneg rows) (nonneg width) [] [] 0 True

||| Add text at the end.
export
append : StyledText -> Model -> Model
append t m =
  let m' = { paras := m.paras ++ t, lines := m.lines ++ layoutLines (textWidth m.width) t } m
  in if m.follow then { top := lastTop m' } m' else m'

||| Scroll.
export
update : Msg -> Model -> Model
update msg m =
  let top' = scrollTop m.rows (count m.lines) m.top msg
  in { top := top', follow := top' >= lastTop m } m

||| The same log in a window of another size; it is wrapped again if the width
||| changed, and a window that is not following the end stays at the same line
||| number, which is another text after a rewrap.
export
resize : (rows, width : Len) -> Model -> Model
resize rows width m =
  let m' = { rows := nonneg rows, width := nonneg width } m
      m'' = if m'.width == m.width then m' else { lines := layoutLines (textWidth m'.width) m'.paras } m'
      top' = if m.follow then lastTop m'' else min m''.top (lastTop m'')
  in { top := top', follow := top' >= lastTop m'' } m''

||| The window with the scroll bar on its right.
export
view : Model -> Node msg
view m =
  let first = min m.top (lastTop m) in
  box [direction Row, height (Cells m.rows), width (Cells m.width)]
    [ box [grow 1] (map lineView (take (cast m.rows) (drop (cast first) m.lines)))
    , scrollBar m.rows (count m.lines) first
    ]

||| The log as a focusable node, so that the keys and the wheel reach it.
export
viewer : (wrap : Msg -> msg) -> Model -> Node msg
viewer wrap m = focusable (\_ => view m) (\i => map wrap (keyMsg i))
