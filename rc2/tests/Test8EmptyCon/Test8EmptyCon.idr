module Main

-- Exercises the new RCNull/RCEmptyCon shortcut: nullary constructors
-- used as operands (function arguments, case scrutinees) should need
-- no synthetic `var_N` binding at all.

data Color = Red | Green | Blue | Yellow

Eq Color where
  Red == Red = True
  Green == Green = True
  Blue == Blue = True
  Yellow == Yellow = True
  _ == _ = False

Show Color where
  show Red = "Red"
  show Green = "Green"
  show Blue = "Blue"
  show Yellow = "Yellow"

-- Mixed ADT (nullary + non-nullary constructors) -- Color above is a
-- *pure* enum (every constructor nullary), which Idris2's own frontend
-- already compiles to a plain integer switch before rc2 ever sees it,
-- so it doesn't actually exercise RCEmptyCon/RConCase at all. Shape
-- does, since NoShape can't be erased the same way once Circle/Square
-- carry real field data.
data Shape = Circle Double | NoShape | Square Double

area : Shape -> Double
area (Circle r) = 3.14159 * r * r
area NoShape = 0.0
area (Square s) = s * s

describe : Color -> String
describe Red = "warm"
describe Green = "cool"
describe Blue = "cool"
describe Yellow = "warm"

useTwice : Color -> String
useTwice c = describe c ++ "/" ++ describe c

main : IO ()
main = do
  -- nullary constructor as a direct function argument
  putStrLn (describe Red)
  putStrLn (describe Blue)
  -- nullary constructor result compared for equality
  printLn (Red == Red)
  printLn (Red == Blue)
  -- case-matching directly on a variable bound to a nullary constructor
  let c = Yellow
  putStrLn (describe c)
  -- nullary constructor used more than once via a real let-bound var
  putStrLn (useTwice Green)
  -- Prelude Bool/Ordering literals (also nullary+tagged)
  printLn (compare 3 5)
  printLn (compare 5 3)
  printLn (compare 3 3)
  printLn True
  printLn False
  -- existing List/Maybe/Nat/Unit (NIL/NOTHING/ZERO/UNIT) paths, unchanged
  printLn (the (List Int) [])
  printLn (the (Maybe Int) Nothing)
  printLn (the Nat 0)
  printLn (length [Red, Green, Blue, Yellow])
  -- mixed ADT: NoShape used as an argument, then matched
  printLn (area (Circle 2.0))
  printLn (area NoShape)
  printLn (area (Square 3.0))
  let shapes = [Circle 1.0, NoShape, Square 2.0, NoShape]
  printLn (map area shapes)
