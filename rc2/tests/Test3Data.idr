module Main

import Data.Maybe

-- Native/Boxed-mixed data structures: custom ADTs holding numbers,
-- nested Maybe/List, exercising both the RC path (constructor fields
-- are always boxed) and the native-arithmetic path together.

data Shape
  = Circle Double
  | Rectangle Double Double
  | Triangle Double Double Double

area : Shape -> Double
area (Circle r) = 3.14159 * r * r
area (Rectangle w h) = w * h
area (Triangle a b c) =
  let s = (a + b + c) / 2
  in sqrt (s * (s - a) * (s - b) * (s - c))

record Point where
  constructor MkPoint
  px : Int
  py : Int

dist2 : Point -> Point -> Int
dist2 (MkPoint x1 y1) (MkPoint x2 y2) =
  let dx = x1 - x2
      dy = y1 - y2
  in dx * dx + dy * dy

safeDiv : Int -> Int -> Maybe Int
safeDiv _ 0 = Nothing
safeDiv x y = Just (x `div` y)

sumMaybes : List (Maybe Int) -> Int
sumMaybes = foldl (\acc, m => acc + fromMaybe 0 m) 0

main : IO ()
main = do
  let shapes = [Circle 2.0, Rectangle 3.0 4.0, Triangle 3.0 4.0 5.0]
  printLn (map area shapes)
  printLn (dist2 (MkPoint 0 0) (MkPoint 3 4))
  printLn (map (safeDiv 100) [0,1,3,7,25])
  printLn (sumMaybes (map (safeDiv 100) [0,1,3,7,25]))
