||| A piece of text in one style: what styled text and the labels of the widgets
||| are made of.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Span

import TermUI.Style

%default total

||| A piece of text in one style. A `\n` in it starts a new line (in styled
||| text; a label is one line).
public export
record Span where
  constructor MkSpan
  spanStyle : Style
  spanText : String

export
Eq Span where
  MkSpan s t == MkSpan s' t' = t == t' && s == s'

||| A span of the style.
public export
spanOf : Style -> String -> Span
spanOf = MkSpan

