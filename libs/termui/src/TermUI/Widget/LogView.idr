||| A log: styled text that grows at the end and is shown a window at a time
||| with a scroll bar, for a chat, the messages of a game or text that arrives
||| in pieces (`extendLast`). The paragraphs are wrapped once and the lines kept
||| in a sequence, so that appending, extending the last paragraph and showing
||| a window cost the new text, the last paragraph and the window, with a
||| factor of the log of the length of the log; only a change of the width
||| wraps everything again. The log has no limit. While the window is at the
||| end it follows new text; scrolling up stops that, and scrolling back to the
||| end starts it again. The size is the program's to give, from `OnResize`: the
||| log wraps to the width less the scroll bar (to a character a line when that
||| is 0 or 1). The messages (`Msg`, `LineDown` ...) are those of
||| `TermUI.Widget.Scrolling`. See libs/termui/doc/design.md ("Widgets").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.LogView

import Data.List
import Data.Seq.Unsized as Q
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
  paras : Seq Para
  lines : Seq (List Span)     -- `paras` wrapped to the width less the bar
  lastStart : Nat             -- the index in `lines` of the first line of the last paragraph
  top : Len                   -- the first line shown
  follow : Bool               -- the window stays at the end

textWidth : Len -> Len
textWidth w = w `monus` 1

||| The number of lines the log has at its width.
export
lineCount : Model -> Len
lineCount m = cast (Q.length m.lines)

lastTop : Model -> Len
lastTop m = lineCount m `monus` m.rows

||| An empty log in a window `rows` high and `width` wide.
export
empty : (rows, width : Len) -> Model
empty rows width = MkModel (nonneg rows) (nonneg width) Q.empty Q.empty 0 0 True

-- After the text changed: at the end if the window was following it, else
-- the same line, kept in range; `follow` says whether it is at the end.
settle : (following : Bool) -> Model -> Model
settle following m =
  let top' : Len
      top' = if following then lastTop m else min m.top (lastTop m)
  in { top := top', follow := top' >= lastTop m } m

||| Add paragraphs at the end.
export
append : StyledText -> Model -> Model
append t m = settle m.follow (foldl add m t)
  where
    add : Model -> Para -> Model
    add acc p =
      { paras $= (`snoc` p)
      , lines := Q.(++) acc.lines (Q.fromList (layoutPara (textWidth acc.width) p))
      , lastStart := Q.length acc.lines } acc

-- The paragraph with spans at the end.
extended : List Span -> Para -> Para
extended spans p = { body := Prelude.Types.List.(++) p.body spans } p

||| Add spans to the end of the last paragraph, or as a paragraph of their own
||| if there is none. Only that paragraph is wrapped again.
export
extendLast : List Span -> Model -> Model
extendLast spans m =
  case Q.viewr m.paras of
    Nothing => append [paragraph spans] m
    Just (before, p) =>
      let p' = extended spans p
      in settle m.follow
           ({ paras := before `snoc` p'
            , lines := Q.(++) (Q.take m.lastStart m.lines) (Q.fromList (layoutPara (textWidth m.width) p')) } m)

||| Scroll.
export
update : Msg -> Model -> Model
update msg m =
  let top' = scrollTop m.rows (lineCount m) m.top msg
  in { top := top', follow := top' >= lastTop m } m

-- Every paragraph wrapped to the width.
rewrap : Model -> Model
rewrap m =
  case foldl step (Q.empty, 0) (toList m.paras) of
    (ls, start) => { lines := ls, lastStart := start } m
  where
    step : (Seq (List Span), Nat) -> Para -> (Seq (List Span), Nat)
    step (acc, _) p = (Q.(++) acc (Q.fromList (layoutPara (textWidth m.width) p)), Q.length acc)

||| The same log in a window of another size; it is wrapped again if the width
||| changed, and a window that is not following the end stays at the same line
||| number, which is another text after a rewrap.
export
resize : (rows, width : Len) -> Model -> Model
resize rows width m =
  let m' = { rows := nonneg rows, width := nonneg width } m
      m'' = if m'.width == m.width then m' else rewrap m'
      top' = if m.follow then lastTop m'' else min m''.top (lastTop m'')
  in { top := top', follow := top' >= lastTop m'' } m''

||| The window with the scroll bar on its right.
export
view : Model -> Node msg
view m =
  let first = min m.top (lastTop m)
      shown = Q.take (cast m.rows) (Q.drop (cast first) m.lines)
  in box [direction Row, height (Cells m.rows), width (Cells m.width)]
       [ box [grow 1] (map lineView (toList shown))
       , scrollBar m.rows (lineCount m) first
       ]

||| The log as a focusable node, so that the keys and the wheel reach it.
export
viewer : (wrap : Msg -> msg) -> Model -> Node msg
viewer wrap m = focusable (\_ => view m) (\i => map wrap (keyMsg i))
