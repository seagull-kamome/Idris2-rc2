||| Display-only widgets: a spinner, a progress bar and a table.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Display

import Data.List
import TermUI.Node
import TermUI.Style

%default total

-------------------------------------------------------------------------------
-- Spinner

spinnerFrames : List String
spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

||| One frame of a spinner; advance `tick` from an `Every` subscription.
export
spinner : (tick : Nat) -> Node msg
spinner tick =
  let i = cast {to = Nat} (mod (cast {to = Integer} tick) (cast (length spinnerFrames))) in
  text (fromMaybe " " (head' (drop i spinnerFrames)))
  where
    fromMaybe : String -> Maybe String -> String
    fromMaybe d Nothing = d
    fromMaybe _ (Just x) = x

-------------------------------------------------------------------------------
-- Progress bar

||| A bar `cells` wide filled to `percent` (0 to 100).
export
progressBar : (cells : Nat) -> (percent : Nat) -> Node msg
progressBar cells percent =
  let filled = cast {to = Nat} (div (cast {to = Integer} cells * cast (min 100 percent)) 100) in
  row []
    [ styled (fgColor green plain) (concat (replicate filled "█"))
    , styled (fgColor (Indexed 8) plain) (concat (replicate (cells `minus` filled) "░"))
    ]

-------------------------------------------------------------------------------
-- Table

||| A table: `columns` gives each header and width in cells, `rows` the
||| cells of each row. Cells are cut at the width of their column; columns
||| are separated by one space.
export
table : (columns : List (String, Nat)) -> (rows : List (List String)) -> Node msg
table columns rows =
  column [] (line (withAttr Bold plain) (map fst columns) :: map (line plain) rows)
  where
    cell : Style -> (String, Nat) -> String -> Node msg
    cell st (_, w) str = box [width (Cells w), height (Cells 1)] [Text st Truncate str]

    line : Style -> List String -> Node msg
    line st cells = row [gap 1] (zipWith (cell st) columns cells)
