||| A check box: `[x] label` or `[ ] label`. The state belongs to the parent,
||| the box only says when it was pressed. See libs/termui/doc/00_getting.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Checkbox

import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Activate

%default total

||| A check box that takes the keyboard focus. Enter, Space and a click send
||| `toggle`; the parent flips `checked` when it gets it.
export
checkbox : (label : String) -> (checked : Bool) -> (toggle : msg) -> Node msg
checkbox label checked toggle =
  row [] [ focusable body (\i => if activates i then Just toggle else Nothing) ]
  where
    body : Bool -> Node msg
    body focused =
      Text (if focused then withAttr Inverse plain else plain) Truncate
        ((if checked then "[x] " else "[ ] ") ++ label)
