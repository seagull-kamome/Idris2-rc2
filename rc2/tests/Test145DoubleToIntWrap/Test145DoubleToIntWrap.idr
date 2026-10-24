module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `cast` from a `Double` to a fixed-width integer truncates toward zero and
-- wraps to the type's width, as Chez does; C leaves a value out of the type's
-- range undefined. A NaN or an infinity has no integer value and gives 0 (Chez
-- raises an exception there). The values come from the command line so nothing
-- folds at compile time. Checked on the native path (each cast feeds a
-- comparison) and on the boxed path (the values go through a list and `show`).

import Data.String
import System

%default total

-- the value is named by its position: `show` of a Double is not what is tested
row : Nat -> Double -> String
row i d = "#" ++ show i ++ ": Int " ++ show (cast {to = Int} d) ++ " Int8 " ++ show (cast {to = Int8} d)
        ++ " Int16 " ++ show (cast {to = Int16} d) ++ " Int32 " ++ show (cast {to = Int32} d)
        ++ " Int64 " ++ show (cast {to = Int64} d) ++ " Bits8 " ++ show (cast {to = Bits8} d)
        ++ " Bits16 " ++ show (cast {to = Bits16} d) ++ " Bits32 " ++ show (cast {to = Bits32} d)
        ++ " Bits64 " ++ show (cast {to = Bits64} d)

-- each element with its position, counted from `start`
indexed : Nat -> List a -> List (Nat, a)
indexed _ [] = []
indexed start (x :: xs) = (start, x) :: indexed (S start) xs

-- native: the cast result is only compared, never boxed
native : Double -> String
native d = unwords [ show (cast {to = Int8} d == 0), show (cast {to = Int16} d > 100)
                   , show (cast {to = Int32} d < 0), show (cast {to = Int} d < 0)
                   , show (cast {to = Bits8} d == 255), show (cast {to = Bits16} d > 1000)
                   , show (cast {to = Bits32} d > 3000000000), show (cast {to = Bits64} d > 9000000000000000000) ]

main : IO ()
main = do
  args <- getArgs
  let n : Double = cast (length args) - 1
  let finite = map (+ n) [1.0e30, -1.0e30, 3.0e9, 300.7, -129.5, -1.5, 1.0e19, 9.3e18, -9.3e18, 70000.9, 2147483648.0, -2147483649.0, 0.9, -0.9]
  traverse_ (\(i, d) => putStrLn (row i d)) (indexed 0 finite)
  traverse_ (\(i, d) => putStrLn ("#" ++ show i ++ " native: " ++ native d)) (indexed 0 finite)
  -- no integer value: 0 (not run by Chez)
  let nan = 0.0 / n
  let inf = 1.0 / n
  traverse_ (\(i, d) => putStrLn (row i d)) (indexed 100 [nan, inf, negate inf])
