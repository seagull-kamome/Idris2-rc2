||| The label of a button, a check box, a tab, a menu or a key hint: one line of
||| text in which the parts can have styles of their own. A string literal is a
||| label (`button Framed "Save" Save`); for parts in other styles, build it with
||| `styledLabel [spanOf bold "S", spanOf plain "ave"]`, and `plainLabel` makes the
||| label of a `String` that is not a literal. The style the widget gives the
||| label (inverse while it has the focus, say) is the base of the style of each
||| part: what a part sets itself wins, the rest comes from the widget. See
||| libs/termui/doc/design.md ("Labels").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Label

import TermUI.Len
import TermUI.Node
import TermUI.Style
import TermUI.Width
import public TermUI.Widget.Span

%default total

public export
record Label where
  constructor MkLabel
  labelParts : List Span

-- A label is one line: a line feed is dropped.
oneLine : String -> String
oneLine = pack . filter (/= '\n') . unpack

||| A label without styles of its own.
export
plainLabel : String -> Label
plainLabel s = MkLabel [MkSpan plain (oneLine s)]

export
FromString Label where
  fromString = plainLabel

||| The labels of strings, for the titles of tabs and the like.
export
plainLabels : List String -> List Label
plainLabels = map plainLabel

||| A label of parts in different styles. A line feed in a part is dropped.
export
styledLabel : List Span -> Label
styledLabel ps = MkLabel (map (\s => MkSpan s.spanStyle (oneLine s.spanText)) ps)

||| The width of the label in cells.
export
labelWidth : Label -> Len
labelWidth l = sum (map (\s => stringWidth s.spanText) l.labelParts)

||| The text of the label without its styles.
export
labelText : Label -> String
labelText l = concat (map (\s => s.spanText) l.labelParts)

-- `before` and `after` go into the first and the last part when that has no style of
-- its own, and are parts of their own otherwise.
around : (before, after : String) -> List Span -> List Span
around before after ps = withAfter (withBefore ps)
  where
    withBefore : List Span -> List Span
    withBefore xs =
      if before == "" then xs
      else case xs of
             (p :: rest) => if p.spanStyle == plain then MkSpan plain (before ++ p.spanText) :: rest
                            else MkSpan plain before :: xs
             [] => [MkSpan plain before]

    withAfter : List Span -> List Span
    withAfter xs =
      if after == "" then xs
      else case reverse xs of
             (p :: rest) => if p.spanStyle == plain then reverse (MkSpan plain (p.spanText ++ after) :: rest)
                            else xs ++ [MkSpan plain after]
             [] => [MkSpan plain after]

||| The label in `base` with `before` and `after` around it (in `base` too), as one
||| row of text. A label with no style of its own is one `Text`, as a string was.
export
labelNode : (base : Style) -> (before, after : String) -> Label -> Node msg
labelNode base before after l =
  case around before after l.labelParts of
    [one] => Text (one.spanStyle `over` base) Truncate one.spanText
    pieces => row [] (map (\s => Text (s.spanStyle `over` base) Truncate s.spanText) pieces)
