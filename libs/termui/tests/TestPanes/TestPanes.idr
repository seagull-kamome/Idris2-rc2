||| The function-key guide, the tab strip and the splitter: the messages keys
||| and clicks mean, the model updates, and the drawing by rendering to text;
||| under a row, `^` marks inverse cells, `u` underlined ones, `s` the blue
||| background and `g` the grey one.
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
import TermUI.Widget.KeyGuide
import TermUI.Widget.Splitter as P
import TermUI.Widget.TabStrip as T

%default covering

mark : Cell -> Char
mark c =
  if hasAttr Inverse c.style then '^'
  else if hasAttr Underline c.style then 'u'
  else if c.style.bg == Indexed 4 then 's'
  else if c.style.bg == Indexed 8 then 'g'
  else ' '

draw : Node msg -> Len -> Len -> IO ()
draw v w h = do
  f <- render v w h
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cells <- traverse (\x => getCell f x y) (if w <= 0 then [] else [0 .. w - 1])
               let marks = pack (map mark cells)
               when (any (/= ' ') (unpack marks)) $
                 putStrLn ("|" ++ pack (reverse (dropWhile (== ' ') (reverse (unpack marks))))))
            (zip [0 .. count ls] ls)

-- The focusable of a widget, for its drawing while focused and its handler.
focusOf : Node msg -> Maybe (Bool -> Node msg, Input -> Maybe msg)
focusOf (Focusable _ body h) = Just (body, h)
focusOf (Box _ kids) = firstOf kids
  where
    firstOf : List (Node msg) -> Maybe (Bool -> Node msg, Input -> Maybe msg)
    firstOf [] = Nothing
    firstOf (k :: ks) = maybe (firstOf ks) Just (focusOf k)
focusOf _ = Nothing

showFocused : Node msg -> Len -> Len -> IO ()
showFocused n w h =
  case focusOf n of
    Just (body, _) => draw (body True) w h
    Nothing => putStrLn "no focusable"

key : Key -> Input
key k = Press k noMods

press : Char -> Input
press c = Press (KChar c) noMods

mouse : MouseButton -> MouseAction -> Len -> Len -> Input
mouse b a c r = Mouse (MkMouseEvent b a c r noMods 1)

data Ev = Help | Save | Quit | FromTab T.Msg | FromSplit P.Msg

Show Ev where
  show Help = "Help"
  show Save = "Save"
  show Quit = "Quit"
  show (FromTab _) = "FromTab"
  show (FromSplit _) = "FromSplit"

hints : List (Hint Ev)
hints = [MkHint 1 "Help" Help, MkHint 2 "Save" Save, MkHint 10 "Quit" Quit]

shown : Show a => Maybe a -> String
shown = maybe "nothing" show

main : IO ()
main = do
  putStrLn "-- function-key guide"
  draw (keyGuide hints) 30 1
  for_ [key (KF 1), key (KF 10), key (KF 3), Press (KF 2) (MkMods False True False), press 'a'] (putStrLn . shown . keyInput hints)
  for_ [0, 1, 4, 5, 6, 7, 10, 11, 12, 18, 19, 20] (\c => putStrLn (show c ++ ": " ++ shown (keyClick hints c)))
  putStrLn "-- function-key guide, clicks on the row"
  for_ [mouse LeftButton ButtonDown 2 0, mouse LeftButton ButtonDown 7 0, mouse LeftButton ButtonDown 17 0, mouse LeftButton ButtonUp 2 0, mouse RightButton ButtonDown 2 0, mouse WheelUp ButtonDown 2 0, key (KF 1), key KTab, mouse LeftButton ButtonDown 40 0] (\i =>
    putStrLn (case focusOf (keyGuide hints) of
                Just (_, h) => shown (h i)
                Nothing => "no focusable"))

  putStrLn "-- tab strip"
  let tabs = T.fromTitles ["One", "Two", "Three"]
  draw (tabStrip FromTab tabs) 30 1
  draw (tabStrip FromTab (T.update Next tabs)) 30 1
  showFocused (tabStrip FromTab (T.update Next tabs)) 30 1
  let act = \msgs => T.activeIndex (foldl (flip T.update) tabs msgs)
  putStrLn ("next next next: " ++ show (act [Next, Next, Next]))
  putStrLn ("prev at first: " ++ show (act [Prev]))
  putStrLn ("last, first: " ++ show (act [Last, First]))
  putStrLn ("select 1, select 99: " ++ show (T.activeIndex (T.select 1 tabs)) ++ ", " ++ show (T.activeIndex (T.select 99 tabs)))
  for_ [0, 4, 5, 6, 10, 11, 12, 18, 19, 25, 40] (\c => putStrLn ("click " ++ show c ++ ": " ++ show (act [Click c])))
  draw (tabbed FromTab (T.update Next tabs) [text "page one", text "page two", text "page three"]) 30 5
  for_ [key KRight, key KLeft, key KHome, key KEnd, key KTab, mouse LeftButton ButtonDown 7 0, mouse LeftButton ButtonUp 7 0] (\i =>
    putStrLn (shown (map (\m => T.activeIndex (T.update m tabs)) (T.keyMsg i))))

  putStrLn "-- splitter, side by side"
  let side = P.withLimits 3 12 (P.fromSize LeftRight 6)
  draw (splitter "s" FromSplit side (text "left pane") (text "right pane")) 24 3
  draw (splitter "s" FromSplit (P.update Grow side) (text "left pane") (text "right pane")) 24 3
  showFocused (splitter "s" FromSplit side (text "left pane") (text "right pane")) 24 3
  putStrLn "-- splitter, stacked"
  let stack = P.fromSize TopBottom 2
  draw (splitter "s" FromSplit stack (text "top") (text "bottom")) 12 6
  putStrLn "-- splitter, sizes"
  let sz = \msgs => P.size (foldl (flip P.update) side msgs)
  putStrLn ("grow: " ++ show (sz [Grow]) ++ ", shrink: " ++ show (sz [Shrink]))
  putStrLn ("shrink to the limit: " ++ show (sz (replicate 20 Shrink)))
  putStrLn ("grow to the limit: " ++ show (sz (replicate 20 Grow)))
  putStrLn ("drag before grab: " ++ show (sz [Drag 9]))
  putStrLn ("grab, drag 9: " ++ show (sz [Grab, Drag 9]))
  putStrLn ("grab, drag 99: " ++ show (sz [Grab, Drag 99]))
  putStrLn ("grab, drag 0: " ++ show (sz [Grab, Drag 0]))
  putStrLn ("limits 5..9 on 6, on 20, on 1: " ++ show (P.size (P.withLimits 5 9 (P.fromSize LeftRight 6))) ++ ", " ++ show (P.size (P.withLimits 5 9 (P.fromSize LeftRight 20))) ++ ", " ++ show (P.size (P.withLimits 5 9 (P.fromSize LeftRight 1))))
  putStrLn ("limits 9..5 (hi below lo): " ++ show (P.size (P.withLimits 9 5 (P.fromSize LeftRight 7))) ++ ", hi " ++ show (P.hi (P.withLimits 9 5 (P.fromSize LeftRight 7))))
  putStrLn ("size past the default limit: " ++ show (P.size (P.fromSize LeftRight 5000)))
  putStrLn ("grab, drag, release, drag: " ++ show (sz [Grab, Drag 9, Release, Drag 4]))
  putStrLn "-- splitter, keys on the divider"
  let div = splitter "s" FromSplit side (text "l") (text "r")
  for_ [key KLeft, key KRight, key KUp, key KDown, mouse LeftButton ButtonDown 6 0, mouse WheelUp ButtonDown 6 0, key KTab] (\i =>
    putStrLn (case focusOf div of
                Just (_, h) => shown (h i)
                Nothing => "no focusable"))
  let divV = splitter "s" FromSplit stack (text "t") (text "b")
  for_ [key KUp, key KDown, key KLeft] (\i =>
    putStrLn (case focusOf divV of
                Just (_, h) => shown (h i)
                Nothing => "no focusable"))
  putStrLn "-- splitter, held"
  let held = P.update Grab side
  draw (splitter "s" FromSplit held (text "left pane") (text "right pane")) 24 3
  case focusOf (splitter "s" FromSplit held (text "l") (text "r")) of
    Just (_, h) => for_ [mouse LeftButton Drag 9 1, mouse LeftButton ButtonUp 9 1, mouse LeftButton ButtonDown 9 1, key KEscape, key KLeft] (\i => putStrLn (shown (h i)))
    Nothing => putStrLn "no focusable"
  for_ [mouse LeftButton ButtonUp 40 9, mouse LeftButton Drag 40 9] (\_ => pure ())
  case mouse LeftButton ButtonUp 40 9 of
    Mouse e => putStrLn (shown (map (\m => (P.update m held).held) (releasing held e)) ++ " / " ++ shown (map (\m => (P.update m side).held) (releasing side e)))
    _ => pure ()
