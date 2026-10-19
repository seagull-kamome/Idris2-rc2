||| Display-only widgets: a spinner, a progress bar and a table.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.Display

import TermUI.Len
import Data.List
import Data.Maybe
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

-------------------------------------------------------------------------------
-- Progress bar

||| A bar `cells` wide filled to `percent` (0 to 100).
export
progressBar : (cells : Len) -> (percent : Len) -> Node msg
progressBar cells percent =
  let filled = (cells * min 100 percent) `div` 100 in
  row []
    [ truncated (fgColor green plain) (concat (replicate (cast filled) "█"))
    , truncated (fgColor (Indexed 8) plain) (concat (replicate (cast (cells `monus` filled)) "░"))
    ]

-------------------------------------------------------------------------------
-- Table

||| One row of a table: the cells cut at the width of their column, a row with
||| fewer cells than there are columns padded with empty ones, extra cells
||| dropped. Columns are separated by one space.
export
tableRow : Style -> (columns : List (String, Len)) -> List String -> Node msg
tableRow st columns cells =
  row [gap 1] (zipWith cell columns (cells ++ replicate (length columns `minus` length cells) ""))
  where
    cell : (String, Len) -> String -> Node msg
    cell (_, w) str = box [width (Cells w), height (Cells 1)] [Text st Truncate str]

||| A table: `columns` gives each header and width in cells, `rows` the
||| cells of each row (see `tableRow`). For a table that scrolls see
||| `TermUI.Widget.Table`.
export
table : (columns : List (String, Len)) -> (rows : List (List String)) -> Node msg
table columns rows =
  column [] (tableRow (withAttr Bold plain) columns (map fst columns) :: map (tableRow plain columns) rows)
