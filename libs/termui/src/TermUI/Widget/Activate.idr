||| What presses a button-like widget: Enter, Space, or the left mouse button.
||| Shared by `Button` and `Checkbox`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Activate

import TermUI.Input

%default total

||| Whether the input presses the widget that has the focus. A key with Ctrl
||| or Alt is left to the application.
export
activates : Input -> Bool
activates (Press KEnter mods) = not (mods.ctrl || mods.alt)
activates (Press (KChar ' ') mods) = not (mods.ctrl || mods.alt)
activates (Mouse e) =
  case (e.button, e.action) of
    (LeftButton, ButtonDown) => True
    _ => False
activates _ = False
