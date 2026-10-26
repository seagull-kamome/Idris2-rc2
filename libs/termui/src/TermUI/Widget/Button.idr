||| A button that takes the keyboard focus and sends a message when pressed
||| (Enter, Space or a click), drawn in a frame, flat, or as a link.
||| See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Button

import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Activate
import public TermUI.Widget.Label

%default total

||| `Framed`: in a rounded frame, heavy while focused. `Flat`: on a grey
||| background. `Link`: underlined, as a hyperlink. A focused button of any look
||| has its label inverse.
public export
data Look = Framed | Flat | Link

||| A button as wide as its label (a string literal, or a `Label` of styled parts).
export
button : Look -> (text : Label) -> (press : msg) -> Node msg
button look text press =
  row [] [ focusable body (\i => if activates i then Just press else Nothing) ]
  where
    body : Bool -> Node msg
    body focused =
      case look of
        Framed =>
          box [border (if focused then Heavy else Rounded)]
            [ labelNode (if focused then withAttr Inverse plain else plain) " " " " text ]
        Flat =>
          labelNode (if focused then withAttr Inverse plain else bgColor (Indexed 8) plain) " " " " text
        Link =>
          labelNode (withAttr Underline (if focused then withAttr Inverse plain else fgColor (bright blue) plain)) "" "" text
