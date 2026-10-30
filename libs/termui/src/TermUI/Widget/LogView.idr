||| A log: styled text that grows at the end and is shown a window at a time
||| with a scroll bar, for a chat, the messages of a game or text that arrives
||| in pieces (`extendLast`). It is a `MarkdownView` whose segments are the
||| paragraphs given to `append`, with a theme in which nothing folds and no
||| blank rows are put between paragraphs: the paragraphs are wrapped once and
||| the lines kept in a sequence, so that appending, extending the last
||| paragraph and showing a window cost the new text, the last paragraph and the
||| window; only a change of the width wraps everything again. The log has no
||| limit. While the window is at the end it follows new text; scrolling up
||| stops that, and scrolling back to the end starts it again. The size is the
||| program's to give, from `OnResize`: the log wraps to the width less the
||| scroll bar. The messages (`Msg`, `LineDown` ...) are those of
||| `TermUI.Widget.Scrolling`. Use `MarkdownView` itself for text in Markdown or
||| for blocks that fold. See libs/termui/doc/design.md ("Widgets").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.LogView

import Data.Seq.Unsized
import TermUI.Input
import TermUI.Len
import TermUI.Markdown.Theme
import TermUI.Node
import public TermUI.Widget.Scrolling
import TermUI.Widget.MarkdownView as V
import TermUI.Widget.StyledText

%default covering

||| The log: a viewer of `MarkdownView` inside.
export
record Model where
  constructor MkLog
  inner : V.Model

logTheme : MdTheme
logTheme = { gap := 0, fold := const NoFold } defaultTheme

||| The height of the window.
export
rows : TermUI.Widget.LogView.Model -> Len
rows (MkLog m) = V.Model.rows m

||| The width of the window, the scroll bar included.
export
width : TermUI.Widget.LogView.Model -> Len
width (MkLog m) = V.Model.width m

||| The first line shown.
export
top : TermUI.Widget.LogView.Model -> Len
top (MkLog m) = V.Model.top m

||| Whether the window stays at the end.
export
follow : TermUI.Widget.LogView.Model -> Bool
follow (MkLog m) = V.Model.follow m

||| The lines of the log.
export
lines : TermUI.Widget.LogView.Model -> Seq (List Span)
lines (MkLog m) = V.Model.lines m

||| The number of lines the log has at its width.
export
lineCount : TermUI.Widget.LogView.Model -> Len
lineCount (MkLog m) = V.lineCount m

||| An empty log in a window `rows` high and `width` wide.
export
empty : (rows, width : Len) -> TermUI.Widget.LogView.Model
empty rows width = MkLog (V.empty logTheme rows width)

||| Add paragraphs at the end.
export
append : StyledText -> TermUI.Widget.LogView.Model -> TermUI.Widget.LogView.Model
append t (MkLog m) = MkLog (addStyled t m)

||| Add spans to the end of the last paragraph, or as a paragraph of their own
||| if there is none. Only that paragraph is wrapped again.
export
extendLast : List Span -> TermUI.Widget.LogView.Model -> TermUI.Widget.LogView.Model
extendLast spans (MkLog m) = MkLog (extendStyled spans m)

||| Scroll.
export
update : Msg -> TermUI.Widget.LogView.Model -> TermUI.Widget.LogView.Model
update msg (MkLog m) = MkLog (V.update (V.Scroll msg) m)

||| The same log in a window of another size; it is wrapped again if the width
||| changed, and a window that is not following the end stays at the same line
||| number, which is another text after a rewrap.
export
resize : (rows, width : Len) -> TermUI.Widget.LogView.Model -> TermUI.Widget.LogView.Model
resize rows width (MkLog m) = MkLog (V.resize rows width m)

||| The window with the scroll bar on its right.
export
view : TermUI.Widget.LogView.Model -> Node msg
view (MkLog m) = V.view m

||| The log as a focusable node, so that the keys and the wheel reach it.
export
viewer : (wrap : Msg -> msg) -> TermUI.Widget.LogView.Model -> Node msg
viewer wrap (MkLog m) = focusable (\_ => V.view m) (\i => map wrap (TermUI.Widget.Scrolling.keyMsg i))
