||| The check box, the buttons and the menu bar: what each sends for a key or
||| a click, how the menu moves, and the drawing by rendering to text; under a
||| row, `^` marks the cells drawn inverse and `s` those on the blue highlight.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import TermUI.Frame
import TermUI.Input
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Button
import TermUI.Widget.Checkbox
import TermUI.Widget.MenuBar as M

%default covering

-- The rows of a view and, under a row that has inverse or highlighted cells,
-- a mark under each of them.
draw : Node msg -> Len -> Len -> IO ()
draw v w h = do
  f <- render v w h
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cells <- traverse (\x => getCell f x y) (if w <= 0 then [] else [0 .. w - 1])
               let marks = pack (map (\c => if hasAttr Inverse c.style then '^' else if c.style.bg == Indexed 4 then 's' else ' ') cells)
               when (any (\c => c == '^' || c == 's') (unpack marks)) $
                 putStrLn ("|" ++ pack (reverse (dropWhile (== ' ') (reverse (unpack marks))))))
            (zip [0 .. count ls] ls)

-- The focusable of a widget, for its drawing while focused and its handler.
focusOf : Node msg -> Maybe (Bool -> Node msg, Input -> Maybe msg)
focusOf (Focusable _ body h) = Just (body, h)
focusOf (Box _ [Focusable _ body h]) = Just (body, h)
focusOf _ = Nothing

showFocused : Node msg -> Len -> Len -> IO ()
showFocused n w h =
  case focusOf n of
    Just (body, _) => draw (body True) w h
    Nothing => putStrLn "no focusable"

sends : Show msg => Node msg -> Input -> IO ()
sends n i =
  case focusOf n of
    Just (_, h) => putStrLn (maybe "nothing" show (h i))
    Nothing => putStrLn "no focusable"

key : Key -> Input
key k = Press k noMods

press : Char -> Input
press c = Press (KChar c) noMods

click : Len -> Len -> Input
click c r = Mouse (MkMouseEvent LeftButton ButtonDown c r noMods 1)

data Ev = Toggle | Press1 | FromMenu M.Msg | Chose String

Show Ev where
  show Toggle = "Toggle"
  show Press1 = "Press1"
  show (FromMenu _) = "FromMenu"
  show (Chose s) = "Chose " ++ s

menus : M.Model Ev
menus = M.fromMenus
  [ MkMenu "File" [Item "Open" (Chose "open"), Item "Save" (Chose "save"), Separator, Item "Quit" (Chose "quit")]
  , MkMenu "Edit" [Item "Undo" (Chose "undo"), Item "Redo" (Chose "redo")]
  ]

-- Apply messages in turn; the messages the items chose are listed.
run : List M.Msg -> M.Model Ev -> (M.Model Ev, List String)
run [] m = (m, [])
run (x :: xs) m =
  let (m', chose) = M.update x m
      (m'', rest) = run xs m'
  in (m'', maybe rest (\c => show c :: rest) chose)

report : String -> List M.Msg -> IO ()
report name msgs = do
  let (m, chose) = run msgs menus
  putStrLn (name ++ ": active=" ++ show m.active ++ " open=" ++ show m.isOpen ++ " cursor=" ++ show m.cursor ++ " chose=" ++ show chose)

main : IO ()
main = do
  putStrLn "-- check box"
  draw (checkbox "agree" False Toggle) 12 1
  draw (checkbox "agree" True Toggle) 12 1
  showFocused (checkbox "agree" True Toggle) 12 1
  for_ [key KEnter, press ' ', press 'x', Press KEnter (MkMods False True False), click 1 0] (sends (checkbox "agree" False Toggle))

  putStrLn "-- buttons"
  draw (button Framed "OK" Press1) 10 3
  showFocused (button Framed "OK" Press1) 10 3
  draw (button Flat "OK" Press1) 10 1
  showFocused (button Flat "OK" Press1) 10 1
  draw (button Link "docs" Press1) 10 1
  showFocused (button Link "docs" Press1) 10 1
  for_ [key KEnter, press ' ', click 2 1, key KEscape] (sends (button Framed "OK" Press1))

  putStrLn "-- menu bar, closed"
  draw (menuBar FromMenu menus) 20 6
  showFocused (menuBar FromMenu menus) 20 6
  putStrLn "-- menu bar, File open"
  showFocused (menuBar FromMenu ({ isOpen := True } menus)) 20 7
  putStrLn "-- menu bar, Edit open on Redo"
  showFocused (menuBar FromMenu ({ active := 1, isOpen := True, cursor := 1 } menus)) 20 7
  putStrLn "-- menu bar, open but not focused"
  draw (menuBar FromMenu ({ isOpen := True } menus)) 20 7

  putStrLn "-- menu moves"
  report "open" [M.Open]
  report "down, down" [M.Open, M.Down, M.Down]
  report "down past the separator" [M.Open, M.Down, M.Down, M.Down]
  report "wrap down" [M.Open, M.Down, M.Down, M.Down, M.Down]
  report "wrap up" [M.Open, M.Up]
  report "up when closed" [M.Up]
  report "down when closed opens" [M.Down]
  report "next, open" [M.Open, M.Next]
  report "prev wraps" [M.Prev]
  report "next wraps" [M.Next, M.Next]
  report "activate chooses" [M.Open, M.Down, M.Activate]
  report "activate when closed opens" [M.Activate]
  report "close" [M.Open, M.Close]
  putStrLn "-- menu keys"
  let h = menuBar FromMenu menus
  for_ [key KLeft, key KRight, key KDown, key KUp, key KEnter, press ' ', key KEscape, key KTab, press 'f'] (sends h)
  let ho = menuBar FromMenu ({ isOpen := True } menus)
  sends ho (key KEscape)
  putStrLn "-- menu clicks"
  report "title Edit" [M.Click 7 0]
  report "title File twice" [M.Click 2 0, M.Click 2 0]
  report "title File then Edit" [M.Click 2 0, M.Click 8 0]
  report "beside the titles" [M.Click 18 0]
  report "item Save" [M.Click 2 0, M.Click 3 3]
  report "item Quit" [M.Click 2 0, M.Click 3 5]
  report "separator" [M.Click 2 0, M.Click 3 4]
  report "top border" [M.Click 2 0, M.Click 3 1]
  report "outside the menu" [M.Click 2 0, M.Click 15 3]
  report "below the menu" [M.Click 2 0, M.Click 3 9]
  report "item when closed" [M.Click 3 3]
