||| Frame diffs, replayed: the output of `diffFrames` for a sequence of frames is
||| given to a small terminal emulator (cursor moves, SGR, erase, scroll region,
||| scroll up and down), and the screen it ends with must be the frame, cell by
||| cell with its style. The frames are random lines with wide characters that
||| scroll by several rows at once, up and down, with a scroll bar of their own in
||| the last column; the number of the steps that were written with a scroll and the
||| bytes written are printed too.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.IOArray
import Data.IORef
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import TermUI.Frame
import TermUI.Node
import TermUI.Output
import TermUI.Style
import TermUI.Width

%default covering

-------------------------------------------------------------------------------
-- A small terminal

record Screen where
  constructor MkScreen
  w, h : Len
  cells : IOArray (Char, String)
  cx, cy : IORef Len
  sgrNow : IORef String
  top, bottom : IORef Len     -- the scroll region, from 0

defaultSgr : String
defaultSgr = "\ESC[0m"

newScreen : Len -> Len -> IO Screen
newScreen w h = do
  cells <- newArray (cast (w * h))
  traverse_ (\i => writeArray cells i (' ', defaultSgr)) [0 .. cast (w * h) - 1]
  MkScreen w h cells <$> newIORef 0 <*> newIORef 0 <*> newIORef defaultSgr <*> newIORef 0 <*> newIORef (h - 1)

cellAtS : Screen -> Len -> Len -> IO (Char, String)
cellAtS s x y = fromMaybe (' ', defaultSgr) <$> readArray s.cells (cast (y * s.w + x))

putS : Screen -> Len -> Len -> (Char, String) -> IO ()
putS s x y c = when (x >= 0 && y >= 0 && x < s.w && y < s.h) $ ignore (writeArray s.cells (cast (y * s.w + x)) c)

clearAll : Screen -> IO ()
clearAll s = traverse_ (\i => writeArray s.cells i (' ', defaultSgr)) [0 .. cast (s.w * s.h) - 1]

-- Move the rows of the region: row r gets row r + k.
scrollBy : Screen -> (k : Len) -> IO ()
scrollBy s k = do
  t <- readIORef s.top
  b <- readIORef s.bottom
  cur <- readIORef s.sgrNow
  let rows = if k > 0 then [t .. b] else reverse [t .. b]
  for_ rows $ \y => do
    let src = y + k
    for_ [0 .. s.w - 1] $ \x =>
      if src >= t && src <= b then cellAtS s x src >>= putS s x y else putS s x y (' ', cur)

-- The parameters of a control sequence as numbers.
numbers : String -> List Len
numbers p = map (fromMaybe 0 . parsePositive) (filter (/= "") (forget (split (== ';') p)))

control : Screen -> String -> Char -> IO ()
control s params 'H' = do
  let ns = numbers params
  writeIORef s.cy (fromMaybe 1 (head' ns) - 1)
  writeIORef s.cx (fromMaybe 1 (head' (drop 1 ns)) - 1)
control s params 'J' = when (params == "2") (clearAll s)
control s params 'm' = writeIORef s.sgrNow ("\ESC[" ++ params ++ "m")
control s params 'r' = do
  case numbers params of
    [t, b] => writeIORef s.top (t - 1) *> writeIORef s.bottom (b - 1)
    _ => writeIORef s.top 0 *> writeIORef s.bottom (s.h - 1)
  writeIORef s.cx 0
  writeIORef s.cy 0
control s params 'S' = scrollBy s (fromMaybe 1 (head' (numbers params)))
control s params 'T' = scrollBy s (negate (fromMaybe 1 (head' (numbers params))))
control _ _ _ = pure ()

feed : Screen -> List Char -> IO ()
feed _ [] = pure ()
feed s ('\ESC' :: '[' :: rest) =
  let (params, after) = span (\c => not (isAlpha c)) rest
  in case after of
       (cmd :: more) => control s (pack params) cmd *> feed s more
       [] => pure ()
feed s (c :: rest) = do
  x <- readIORef s.cx
  y <- readIORef s.cy
  cur <- readIORef s.sgrNow
  case charWidth c of
    0 => pure ()
    2 => putS s x y (c, cur) *> putS s (x + 1) y ('\0', cur) *> writeIORef s.cx (x + 2)
    _ => putS s x y (c, cur) *> writeIORef s.cx (x + 1)
  feed s rest

-- How many cells differ from the frame, and the first one.
compareWith : Screen -> Frame -> IO (Nat, Maybe String)
compareWith s f = do
  cs <- for [(x, y) | y <- [0 .. s.h - 1], x <- [0 .. s.w - 1]] $ \(x, y) => do
    got <- cellAtS s x y
    c <- getCell f x y
    let want = (c.glyph, sgr c.style)
    pure (if got == want then Nothing else Just ("(" ++ show x ++ "," ++ show y ++ ") screen " ++ show got ++ " frame " ++ show want))
  let bad = catMaybes cs
  pure (length bad, head' bad)

-------------------------------------------------------------------------------
-- Random frames

next : Integer -> Integer
next s = (s * 6364136223846793005 + 1442695040888963407) `mod` 18446744073709551616

pickAt : Nat -> List a -> Maybe a
pickAt _ [] = Nothing
pickAt Z (x :: _) = Just x
pickAt (S k) (_ :: r) = pickAt k r

pick : Integer -> List a -> Maybe a
pick s xs = pickAt (cast ((s `div` 65536) `mod` cast (max 1 (length xs)))) xs

pool : List String
pool = ["", "a", "bb", "hello world", "日本語", "あいうえお", "x日y", "  indented", "    日本", "Lean は、Googles Cloud 的な", "```lean", "1. **bold**", "abcdefghijklmnopqrstuvwxyz", "ー"]

styles : List Style
styles = [plain, withAttr Bold plain, withAttr Dim plain, fgColor red plain, fgColor (RGB 1 2 3) plain, bgColor (Indexed 4) plain]

Line : Type
Line = List (Style, String)

genLine : Integer -> (Line, Integer)
genLine s0 = go (cast ((next s0 `div` 65536) `mod` 3 + 1)) (next s0) []
  where
    go : Nat -> Integer -> Line -> (Line, Integer)
    go Z s acc = (reverse acc, s)
    go (S k) s acc =
      let s1 = next s
          s2 = next s1
      in go k s2 ((fromMaybe plain (pick s1 styles), fromMaybe "" (pick s2 pool)) :: acc)

genLines : Nat -> Integer -> (List Line, Integer)
genLines Z s = ([], s)
genLines (S k) s = let (l, s1) = genLine s
                       (ls, s2) = genLines k s1
                   in (l :: ls, s2)

-- The lines in a box, and a bar of one column whose cells depend on the position
-- (as a scroll bar's do).
viewOf : Nat -> List Line -> Node ()
viewOf step ls =
  row [] [ box [grow 1] (map (\l => row [] (map (\(st, t) => Text st Truncate t) l)) ls)
         , column [width (Cells 1)] (map (\i => text (if mod' (i + step) 3 == 0 then "#" else "|")) [0 .. length ls `minus` 1]) ]
  where
    mod' : Nat -> Nat -> Nat
    mod' a b = cast (mod (cast {to = Integer} a) (cast b))

-- Scroll the lines by k rows, up or down, or replace them all.
mutate : Integer -> Nat -> List Line -> (List Line, Integer)
mutate s height ls =
  let s1 = next s
      kind : Integer
      kind = (s1 `div` 65536) `mod` 5
      k : Nat
      k = cast ((next s1 `div` 65536) `mod` cast (height + 1)) + 1
      s2 = next (next s1)
  in case kind of
       0 => let (new, s3) = genLines k s2 in (drop k ls ++ new, s3)
       1 => let (new, s3) = genLines k s2 in (take height (new ++ ls), s3)
       2 => genLines height s2
       3 => let (l, s3) = genLine s2
                i = cast ((s3 `div` 65536) `mod` cast height)
            in (take i ls ++ [l] ++ drop (i + 1) ls, next s3)
       _ => let (new, s3) = genLines 1 s2 in (drop 1 ls ++ new, s3)

record Totals where
  constructor MkTotals
  steps, wrong, scrolled, bytes : Nat

replay : Nat -> Nat -> Integer -> Screen -> Maybe Frame -> List Line -> Totals -> IO Totals
replay Z _ _ _ _ _ t = pure t
replay (S k) height s scr prev ls t = do
  let step = t.steps
  fr <- render (viewOf step ls) scr.w scr.h
  d <- diffFrames prev fr
  feed scr (unpack d)
  (bad, first) <- compareWith scr fr
  when (bad > 0 && t.wrong < 3) $ putStrLn ("step " ++ show step ++ ": " ++ show bad ++ " cells differ, e.g. " ++ fromMaybe "" first)
  let (ls', s') = mutate s height ls
  replay k height s' scr (Just fr) ls'
         ({ steps $= S, wrong := if bad > 0 then S t.wrong else t.wrong
          , scrolled := if isInfixOf "\ESC[r" d then S t.scrolled else t.scrolled
          , bytes := t.bytes + length d } t)

-------------------------------------------------------------------------------
-- A scroll by hand

escaped : String -> String
escaped s = concatMap f (unpack s)
  where
    f : Char -> String
    f '\ESC' = "<ESC>"
    f c = singleton c

-- Rows that have little in common, so that the rows that scrolled are the thing in common.
sentence : Nat -> List Line
sentence i =
  [[(plain, fromMaybe "" (pickAt i ["alpha beta gamma", "the quick brown fox", "日本語のテキスト", "pack my box with five", "dozen liquor jugs", "sphinx of black quartz", "judge my vow", "how vexingly quick", "daft zebras jump", "waltz, bad nymph", "for quick jigs vex", "glib jocks quiz", "nymph and crwth", "lazy dog sleeps", "mr jock, tv quiz phd", "crazy frederick bought"])) ]]

-- A long line, different from its neighbours.
longLine : Nat -> List Line
longLine i =
  let words = fromMaybe "" (pickAt (i * 7) ["the quick brown fox jumps over the lazy dog", "pack my box with five dozen liquor jugs", "日本語の長い文章がここに入ります", "sphinx of black quartz, judge my vow"])
  in [[(plain, "line " ++ show i ++ ": " ++ words ++ " and so on, up to the end of the row")]]

window : Nat -> Nat -> List Line
window from n = concatMap sentence [from .. from + n `minus` 1]

main : IO ()
main = do
  putStrLn "-- ten rows scroll up by three"
  f0 <- render (viewOf 0 (window 0 10)) 24 10
  f1 <- render (viewOf 0 (window 3 10)) 24 10
  d <- diffFrames (Just f0) f1
  putStrLn (escaped d)
  scr <- newScreen 24 10
  feed scr (unpack !(diffFrames Nothing f0))
  feed scr (unpack d)
  (bad, _) <- compareWith scr f1
  putStrLn ("cells that differ: " ++ show bad)

  putStrLn "-- the same, down by two"
  f2 <- render (viewOf 0 (window 1 10)) 24 10
  d2 <- diffFrames (Just f1) f2
  putStrLn (escaped d2)
  feed scr (unpack d2)
  (bad2, _) <- compareWith scr f2
  putStrLn ("cells that differ: " ++ show bad2)

  putStrLn "-- a full screen scrolls by one row: the bytes written, and the bytes of the whole screen"
  let bigRows = \from => concatMap longLine [from .. from + 31]
  b0 <- render (viewOf 0 (bigRows 0)) 147 33
  b1 <- render (viewOf 1 (bigRows 1)) 147 33
  dBig <- diffFrames (Just b0) b1
  dAll <- diffFrames Nothing b1
  putStrLn ("scrolled output: " ++ show (length dBig) ++ " bytes, whole screen: " ++ show (length dAll) ++ " bytes, shorter: " ++ show (length dBig * 5 < length dAll))
  bigScreen <- newScreen 147 33
  feed bigScreen (unpack !(diffFrames Nothing b0))
  feed bigScreen (unpack dBig)
  (badBig, _) <- compareWith bigScreen b1
  putStrLn ("cells that differ: " ++ show badBig)

  putStrLn "-- a header and a footer stay, the rows between them scroll by two"
  let scene = \from => [[(withAttr Bold plain, "HEADER")]] ++ window from 8 ++ [[(withAttr Bold plain, "FOOTER")]]
  h0 <- render (viewOf 0 (scene 0)) 24 10
  h1 <- render (viewOf 0 (scene 2)) 24 10
  dh <- diffFrames (Just h0) h1
  putStrLn (escaped dh)
  hs <- newScreen 24 10
  feed hs (unpack !(diffFrames Nothing h0))
  feed hs (unpack dh)
  (badH, _) <- compareWith hs h1
  putStrLn ("cells that differ: " ++ show badH)

  putStrLn "-- a few rows at the top of a tall screen, the rest blank"
  t0 <- render (viewOf 0 (concatMap longLine [0 .. 4] ++ replicate 25 [])) 90 30
  t1 <- render (viewOf 0 (concatMap longLine [1 .. 5] ++ replicate 25 [])) 90 30
  dt <- diffFrames (Just t0) t1
  putStrLn (escaped (pack (take 40 (unpack dt))))
  ts <- newScreen 90 30
  feed ts (unpack !(diffFrames Nothing t0))
  feed ts (unpack dt)
  (badT, _) <- compareWith ts t1
  putStrLn ("cells that differ: " ++ show badT ++ ", scrolled: " ++ show (isInfixOf "\ESC[r" dt))

  putStrLn "-- random frames"
  let (start, s0) = genLines 10 4242
  scr2 <- newScreen 30 10
  t <- replay 400 10 s0 scr2 Nothing start (MkTotals 0 0 0 0)
  putStrLn ("steps " ++ show t.steps ++ ", wrong " ++ show t.wrong ++ ", written with a scroll " ++ show t.scrolled)
