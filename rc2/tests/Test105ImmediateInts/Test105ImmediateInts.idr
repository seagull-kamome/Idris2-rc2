module Main

-- Int, Int64 and Bits64 values stored in a heap cell are immediate within
-- 62 bits and boxed beyond (rc2/doc/immediate-ints.md). Each value below
-- sits in a list, so it is stored in that form; the arithmetic runs on
-- both sides of each boundary and must keep full 64-bit semantics.

import Data.Bits
import Data.String

ints : List Int
ints = [ 0, 1, -1, 99, 100, -100
       , 2305843009213693951, 2305843009213693952, -2305843009213693952, -2305843009213693953
       , 4611686018427387903, 4611686018427387904, -4611686018427387904
       , 9223372036854775807, -9223372036854775808 ]

int64s : List Int64
int64s = [ 0, -1, 2305843009213693951, 2305843009213693952, -2305843009213693953
         , 9223372036854775807, -9223372036854775808 ]

bits64s : List Bits64
bits64s = [ 0, 1, 99, 100, 4611686018427387903, 4611686018427387904
          , 9223372036854775808, 18446744073709551615 ]

intOps : Int -> String
intOps x = unwords
  [ show x, show (x + 1), show (x - 1), show (x * 2), show (x `div` 3), show (x `mod` 7)
  , show (negate x), show (cast {to = Integer} x), show (cast {to = Bits64} x)
  , show (x `shiftR` 1), show (x .&. 255), show (x < 0), show (compare x 4611686018427387904) ]

int64Ops : Int64 -> String
int64Ops x = unwords
  [ show x, show (x + 1), show (x - 1), show (x * 3), show (x `div` 5)
  , show (negate x), show (cast {to = Int} x), show (cast {to = Integer} x) ]

bits64Ops : Bits64 -> String
bits64Ops x = unwords
  [ show x, show (x + 1), show (x - 1), show (x * 2), show (x `div` 3), show (x `mod` 7)
  , show (x `shiftR` 1), show (x .|. 1), show (complement x), show (cast {to = Int} x)
  , show (cast {to = Integer} x), show (x > 4611686018427387903) ]

main : IO ()
main = do
  traverse_ (putStrLn . intOps) ints
  traverse_ (putStrLn . int64Ops) int64s
  traverse_ (putStrLn . bits64Ops) bits64s
  printLn (sum ints, sum int64s, sum bits64s)
  printLn (map (cast {to = Int}) ["2305843009213693952", "-9223372036854775808", "123"])
  printLn (map (cast {to = Bits64}) ["4611686018427387904", "18446744073709551615"])
