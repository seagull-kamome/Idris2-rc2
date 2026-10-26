||| Turns the difference between two frames into the terminal output that
||| transforms the screen from one to the other.
||| Cursor moves and SGR sequences are emitted only when needed; the whole
||| update is one string, meant to be written with a single write(2).
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Output

import Control.ANSI.CSI
import Data.List
import Data.Maybe
import Data.SortedMap
import TermUI.Frame
import TermUI.Len
import TermUI.Style
import TermUI.Width

%default covering

-------------------------------------------------------------------------------
-- SGR

colorCode : (base : Nat) -> (bright : Nat) -> (ext : Nat) -> Color -> String
colorCode _ _ _ Inherit = ""
colorCode _ _ _ Default = ""
colorCode base br ext (Indexed n) =
  let i = cast {to = Nat} n in
  if i < 8 then ";" ++ show (base + i)
  else if i < 16 then ";" ++ show (br + i `minus` 8)
  else ";" ++ show ext ++ ";5;" ++ show i
colorCode _ _ ext (RGB r g b) =
  ";" ++ show ext ++ ";2;" ++ show r ++ ";" ++ show g ++ ";" ++ show b

attrCode : Attr -> String
attrCode Bold = ";1"
attrCode Dim = ";2"
attrCode Italic = ";3"
attrCode Underline = ";4"
attrCode Inverse = ";7"
attrCode Strike = ";9"

||| The sequence that sets exactly `s`, whatever was set before.
export
sgr : Style -> String
sgr s =
  "\ESC[0"
    ++ concatMap attrCode (filter (\a => hasAttr a s) allAttrs)
    ++ colorCode 30 90 38 s.fg
    ++ colorCode 40 100 48 s.bg
    ++ "m"

-------------------------------------------------------------------------------
-- Diff

record St where
  constructor MkSt
  out : List String            
  cursor : Maybe (Len, Len)
  current : Maybe Style

glyphWidth : Char -> Len
glyphWidth c = max 1 (charWidth c)

emitCell : Len -> Len -> Len -> St -> Cell -> St
emitCell fw x y st c =
  let moved = if st.cursor == Just (x, y) then [] else [cursorMove (cast (y + 1)) (cast (x + 1))]
      styled = if st.current == Just c.style then [] else [sgr c.style]
      next = x + glyphWidth c.glyph
  in MkSt (pack (c.glyph :: c.combining) :: styled ++ moved ++ st.out)
          (if next >= fw then Nothing else Just (next, y))
          (Just c.style)

-- The output for the cells of `next` that are not as `prev` shows them (nothing
-- is shown if `prev` is `Nothing`), written from the state `start`.
diffCore : Maybe Frame -> Frame -> St -> IO String
diffCore prev next start = do
  st <- goRows (span 0 next.frameHeight) start
  pure (if null st.out then "" else concat (reverse ("\ESC[0m" :: st.out)))
  where
    goCols : Len -> Len -> St -> IO St
    goCols y x st =
      if x >= next.frameWidth then pure st else do
        g <- glyphAt next x y
        if g == continuation then goCols y (x + 1) st else do
          same <- maybe (blankAt next x y) (\p => sameAt p next x y) prev
          st' <- if same then pure st else emitCell next.frameWidth x y st <$> getCell next x y
          goCols y (x + glyphWidth g) st'

    goRows : List Len -> St -> IO St
    goRows [] st = pure st
    goRows (y :: ys) st = goCols y 0 st >>= goRows ys

-- How a row of `next` and the row `k` below it in `prev` compare.
data Match = NoMatch | BlankMatch | RowMatch

-- The first and the last row of the longest run of matching rows (blank rows
-- may be inside it but do not count and do not end it), and how many of them
-- are not blank.
longestRun : List Match -> (Len, Len, Nat)
longestRun = go 0 Nothing (0, 0, 0)
  where
    -- `run`: the first and the last non-blank row of the run so far and their count
    better : (Len, Len, Nat) -> (Len, Len, Nat) -> (Len, Len, Nat)
    better (s, e, n) (s', e', n') = if n' > n then (s', e', n') else (s, e, n)

    close : Maybe (Len, Len, Nat) -> (Len, Len, Nat) -> (Len, Len, Nat)
    close Nothing best = best
    close (Just r) best = better best r

    go : (i : Len) -> (run : Maybe (Len, Len, Nat)) -> (best : (Len, Len, Nat)) -> List Match -> (Len, Len, Nat)
    go _ run best [] = close run best
    go i run best (RowMatch :: rest) =
      go (i + 1) (Just (case run of
                          Nothing => (i, i, 1)
                          Just (s, _, n) => (s, i, S n))) best rest
    go i run best (BlankMatch :: rest) = go (i + 1) run best rest
    go i run best (NoMatch :: rest) = go (i + 1) Nothing (close run best) rest

-- The rows (top, bottom) to scroll for a shift `k`: the longest run of rows of
-- `next` that are the rows `k` below them in `prev`, and the rows that come in.
regionFor : (h : Len) -> (hp, hn : SortedMap Len Bits64) -> (k : Len) -> Maybe (Len, Len, Len)
regionFor h hp hn k =
  let matches = \y => if y + k < 0 || y + k >= h || SortedMap.lookup y hn /= SortedMap.lookup (y + k) hp then NoMatch
                       else if SortedMap.lookup y hn == Just emptyRowHash then BlankMatch else RowMatch
      (start, end, n) = longestRun (map matches (span 0 h))
  in if n < 3 then Nothing
     else if k > 0 then Just (start, end + k, k)
     else Just (start + k, end, k)

-- Where the rows of `next` are rows of `prev` that have moved up or down by the
-- same number of rows: for each such shift (the two that most rows agree on), the
-- rows `(top, bottom)` a terminal has to scroll and the shift `k` (up is
-- positive). Rows are compared by their hash but for the last column and the
-- marks; rows with nothing in them do not count, and fewer than 3 rows are not
-- worth a scroll. Only the longest run of rows is scrolled.
scrolls : Frame -> Frame -> IO (List (Len, Len, Len))
scrolls prev next = do
  let rows = span 0 next.frameHeight
  hp <- traverse (rowHash prev) rows
  hn <- traverse (rowHash next) rows
  let prevRows = foldl (\acc, (y, hy) => SortedMap.insertWith (++) hy [y] acc) SortedMap.empty (zip rows hp)
      votes = foldl (\acc, (y, hy) =>
                       if hy == emptyRowHash then acc
                       else foldl (\acc', y' => if y' == y then acc' else SortedMap.insertWith (+) (y' - y) (the Nat 1) acc')
                                  acc (fromMaybe [] (SortedMap.lookup hy prevRows)))
                    SortedMap.empty (zip rows hn)
      ranked = take 2 (sortBy (\a, b => compare (snd b) (snd a)) (filter (\(_, n) => n >= 3) (SortedMap.toList votes)))
      mapOf = \hs => SortedMap.fromList (zip rows hs)
  pure (mapMaybe (regionFor next.frameHeight (mapOf hp) (mapOf hn) . fst) ranked)

-- The size of the output, in characters, from which a scroll is looked for.
searchFrom : Nat
searchFrom = 192

||| The output that turns the screen showing `prev` into `next`. Without a
||| previous frame (or after a resize) the screen is cleared first. When rows have
||| scrolled, the terminal is asked to scroll them (a scroll region and `CSI S` or
||| `CSI T`) and only what is still different is written, if that is shorter.
export
diffFrames : Maybe Frame -> Frame -> IO String
diffFrames prev0 next =
  case prev0 of
    Just p =>
      if p.frameWidth == next.frameWidth && p.frameHeight == next.frameHeight
         then do
           plain <- diffCore (Just p) next (MkSt [] Nothing Nothing)
           -- a small difference is not worth the search
           if length plain < searchFrom then pure plain else do
             cands <- scrolls p next
             scrolled <- traverse (viaScroll p) cands
             pure (foldl (\best, s => if length s < length best then s else best) plain scrolled)
         else fresh
    Nothing => fresh
  where
    fresh : IO String
    fresh = diffCore Nothing next (MkSt [eraseScreen All, "\ESC[0m"] Nothing Nothing)

    -- The scroll, then the difference between what the terminal shows and `next`.
    viaScroll : Frame -> (Len, Len, Len) -> IO String
    viaScroll p (top, bottom, k) = do
      shifted <- shiftRows p top bottom k
      let (n, command) = if k > 0 then (k, "S") else (negate k, "T")
          scroll = "\ESC[0m\ESC[" ++ show (top + 1) ++ ";" ++ show (bottom + 1) ++ "r\ESC[" ++ show n ++ command ++ "\ESC[r"
      diffCore (Just shifted) next (MkSt [scroll] Nothing (Just (settle plain)))
