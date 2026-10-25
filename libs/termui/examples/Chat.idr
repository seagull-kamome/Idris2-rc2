||| A chat log: type a line and press Enter to send it; a bot talks now and then,
||| a word at a time (`extendLast`). The log is styled text (names in colour,
||| lines wrapped with a hanging indent) in a `LogView`, which follows the end
||| until you scroll up with the arrows, Page Up/Down or the wheel (Tab moves
||| the focus to it). The window size comes from `OnResize`. Ctrl-C or Esc quits.
|||
||| Build: idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -o chat Chat.idr
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Widget.LogView as L
import TermUI.Widget.Scrolling as Sc
import TermUI.Widget.StyledText
import TermUI.Widget.TextInput as T

%default covering

data AppMsg = Edit T.Msg | Send | Bot | Word | Resized Len Len | Scroll Sc.Msg | Quit'

record AppModel where
  constructor MkModel
  log : L.Model
  input : T.Model
  queued : List String        -- what the bot says next
  typing : List String        -- the words of the message it is typing

-- A message: the name in colour, the text wrapped under it.
message : Color -> String -> String -> Para
message c who what =
  MkPara [spanOf (withAttr Bold (fgColor c plain)) (who ++ "  ")] [spanOf plain (pack (replicate (length who + 2) ' '))]
         WrapWords [spanOf plain what]

botLines : List String
botLines =
  [ "Wide characters take two cells: 日本語のテキストも折り返されます。"
  , "A long line is wrapped at the spaces and the rest hangs under the name, so that you can see where one message ends."
  , "Scroll up with the arrow keys, Page Up or the wheel; the log stops following the end until you scroll back to it."
  , "ok"
  , "Resize the window: the log wraps again to the new width."
  ]

-- Room for the log: all but the line of the input and its border.
logRows : Len -> Len
logRows r = r `monus` 3

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate Send m =
  let entered = T.value m.input in
  if entered == "" then (m, NoCmd)
  else
    -- What the bot has not typed yet is typed at once, so that it does not
    -- go to the end of the message of the user.
    let said = if null m.typing then id else L.extendLast [spanOf plain (unwords m.typing)]
    in ({ input := T.empty 30, typing := [], log $= L.update ToEnd . L.append [message green "you" entered] . said } m, NoCmd)
appUpdate Bot m =
  if not (null m.typing) then (m, NoCmd)
  else
    let (line, rest) = case m.queued of
                         (l :: ls) => (l, ls ++ [l])
                         _ => ("...", [])
    in ({ queued := rest, typing := words line, log $= L.append [message cyan "bot" ""] } m, NoCmd)
appUpdate Word m =
  case m.typing of
    (w :: ws) => ({ typing := ws, log $= L.extendLast [spanOf plain (w ++ " ")] } m, NoCmd)
    _ => (m, NoCmd)
appUpdate (Resized c r) m = ({ log $= L.resize (logRows r) c } m, NoCmd)
appUpdate (Scroll s) m = ({ log $= L.update s } m, NoCmd)
appUpdate Quit' m = (m, Quit)

appView : AppModel -> Node AppMsg
appView m =
  column []
    [ box [grow 1] [L.viewer Scroll m.log]
    , box [border Single] [T.field Edit (Just Send) m.input]
    ]

appSubs : AppModel -> List (Sub AppMsg)
appSubs m =
  [ MouseFocus
  , OnResize Resized
  , Every "bot" 6000 Bot
  , OnInput (\i => case i of
                     Press KEscape _ => Just Quit'
                     Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
                     _ => Nothing)
  ]
  ++ (if null m.typing then [] else [Every "typing" 150 Word])

main : IO ()
main = do
  let log0 = L.append [message cyan "bot" "Hello! Say something."] (L.empty 20 60)
  r <- runProgram (MkProgram (MkModel log0 (T.empty 30) botLines [], NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("termui chat needs a terminal: " ++ show e)
    Right _ => putStrLn "bye"
