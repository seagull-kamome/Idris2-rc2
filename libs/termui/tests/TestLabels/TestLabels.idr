||| Labels with styles of their own on the widgets that have them: a button, a
||| check box, a strip of tabs, a menu bar and a function-key guide. The view is
||| rendered to text; under a row that has styled cells a line marks them: `^` bold,
||| `r` red, `i` inverse, `u` underlined, `g` the grey background.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.Maybe
import Data.String
import TermUI.Frame
import TermUI.Node
import TermUI.Style
import TermUI.Widget.Button
import TermUI.Widget.Checkbox
import TermUI.Widget.KeyGuide
import TermUI.Widget.MenuBar as M
import TermUI.Widget.TabStrip as T

%default covering

mark : Cell -> Char
mark c =
  if hasAttr Inverse c.style then 'i'
  else if c.style.fg == red then 'r'
  else if hasAttr Bold c.style then '^'
  else if hasAttr Underline c.style then 'u'
  else if c.style.bg == Indexed 8 then 'g'
  else ' '

draw : String -> Node () -> Len -> Len -> IO ()
draw title v w h = do
  putStrLn ("-- " ++ title)
  f <- render v w h
  ls <- frameLines f
  traverse_ (\(y, l) => do
               putStrLn ("|" ++ l)
               cs <- traverse (\x => getCell f x y) (if w <= 0 then [] else [0 .. w - 1])
               let m = pack (map mark cs)
               when (trim m /= "") $ putStrLn (" " ++ m))
            (zip [0 .. h - 1] ls)

hot : Label
hot = styledLabel [spanOf (withAttr Bold plain) "S", spanOf plain "ave ", spanOf (fgColor red plain) "now"]

main : IO ()
main = do
  draw "a string literal is a label" (button Flat "Plain" ()) 12 1
  draw "framed, with parts" (button Framed hot ()) 14 3
  draw "flat: the parts over the grey" (button Flat hot ()) 14 1
  draw "a link: the parts over the underline" (button Link hot ()) 14 1
  draw "a check box" (checkbox (styledLabel [spanOf plain "Use ", spanOf (fgColor red plain) "red"]) True ()) 14 1
  draw "a label under a base: inverse, as while the widget has the focus"
    (labelNode (withAttr Inverse plain) " " " " hot) 14 1
  draw "wide characters in a label" (button Flat (styledLabel [spanOf (withAttr Bold plain) "保存", spanOf plain " (S)"]) ()) 14 1

  putStrLn "-- plain labels in boxes narrower than they are: one piece, cut at the edge"
  traverse_ (\w => draw ("width " ++ show w) (box [] [box [width (Cells w)] [button Framed "Save" ()]]) 8 3) [3, 5, 6]
  traverse_ (\w => draw ("flat, width " ++ show w) (box [] [box [width (Cells w)] [button Flat "Save" ()]]) 8 1) [3, 5]
  traverse_ (\w => draw ("check box, width " ++ show w) (box [] [box [width (Cells w)] [checkbox "Save" False ()]]) 10 1) [4, 7]
  draw "a line feed in a label is dropped" (button Flat (styledLabel [spanOf plain "ab\ncd"]) ()) 8 1
  putStrLn (show (labelWidth (styledLabel [spanOf plain "ab\ncd"]), labelWidth "日本語"))

  let strip = T.fromTitles [styledLabel [spanOf (withAttr Bold plain) "A", spanOf plain "lpha"], "Beta", "日本"]
  draw "tabs" (T.tabStrip (const ()) strip) 24 1
  putStrLn "-- a click on the tabs: the columns of Alpha, Beta, 日本"
  traverse_ (\c => putStrLn (show c ++ " -> " ++ show (T.activeIndex (T.update (T.Click c) strip))))
            [0, 5, 6, 7, 10, 11, 12, 15]

  let bar = M.fromMenus [ MkMenu (styledLabel [spanOf (withAttr Bold plain) "F", spanOf plain "ile"]) [Item "Open" (), Separator, Item hot ()]
                        , MkMenu "View" [Item "Zoom" ()] ]
  draw "a menu bar" (M.menuBar (const ()) bar) 24 2
  putStrLn "-- a click on the bar: titles File and View"
  traverse_ (\c => putStrLn (show c ++ " -> " ++ show ((fst (M.update (M.Click c 0) bar)).isOpen, (fst (M.update (M.Click c 0) bar)).active)))
            [0, 1, 6, 7, 8, 13]

  let hints = [MkHint 1 (styledLabel [spanOf (withAttr Bold plain) "He", spanOf plain "lp"]) (), MkHint 10 "Quit" ()]
  draw "a function-key guide" (keyGuide hints) 24 1
  putStrLn "-- a click on the guide"
  traverse_ (\c => putStrLn (show c ++ " -> " ++ show (isJust (keyClick hints c)))) [0, 3, 6, 7, 8, 9, 10, 13]
