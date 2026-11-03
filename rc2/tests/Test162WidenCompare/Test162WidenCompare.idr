module Main

import Data.Bits
import Data.Fin
import System

-- A narrower integer cast to `Integer` and compared with a literal is
-- compared in the narrower type, or decided at once when the literal is out
-- of its range (`doc/widening-compare.md`). Each function below is called with
-- values on both sides of the literal; `check.sh` looks for the `Integer`
-- comparisons that are left.

%noinline
intLe : Int -> Bool
intLe x = 0 <= cast {to = Integer} x

%noinline
intNat : Int -> Integer
intNat x = let i = cast {to = Integer} x in if 0 <= i then i else 0

%noinline
litFirst : Int -> Bool
litFirst x = 100 > cast {to = Integer} x

%noinline
eq8 : Bits8 -> Bool
eq8 x = cast {to = Integer} x == 200

%noinline
outHigh8 : Bits8 -> Bool
outHigh8 x = cast {to = Integer} x < 300

%noinline
outLow8 : Bits8 -> Bool
outLow8 x = cast {to = Integer} x >= (-1)

%noinline
outEq8 : Bits8 -> Bool
outEq8 x = cast {to = Integer} x == 256

%noinline
signed8 : Int8 -> Bool
signed8 x = cast {to = Integer} x <= (-5)

%noinline
signedOut : Int8 -> Bool
signedOut x = (-129) < cast {to = Integer} x

%noinline
big : Int64 -> Bool
big x = cast {to = Integer} x > 9223372036854775807

%noinline
bits64 : Bits64 -> Bool
bits64 x = cast {to = Integer} x >= 18446744073709551615

%noinline
chr' : Char -> Bool
chr' c = cast {to = Integer} c < 65

%noinline
chrOut : Char -> Bool
chrOut c = cast {to = Integer} c <= 1114111

%noinline
int16 : Int16 -> Bool
int16 x = cast {to = Integer} x < (-32768)

%noinline
int16In : Int16 -> Bool
int16In x = cast {to = Integer} x >= 100

%noinline
int32 : Int32 -> Bool
int32 x = cast {to = Integer} x > 2147483647

%noinline
int32In : Int32 -> Bool
int32In x = cast {to = Integer} x == (-7)

%noinline
bits16 : Bits16 -> Bool
bits16 x = cast {to = Integer} x <= 65535

%noinline
bits32 : Bits32 -> Bool
bits32 x = 4294967296 > cast {to = Integer} x

%noinline
intOut : Int -> Bool
intOut x = cast {to = Integer} x < 9223372036854775808

%noinline
int8High : Int8 -> Bool
int8High x = cast {to = Integer} x > 127

%noinline
chrNeg : Char -> Bool
chrNeg c = cast {to = Integer} c > (-1)

%noinline
chrHigh : Char -> Bool
chrHigh c = cast {to = Integer} c < 1114112

%noinline
chrSurrogate : Char -> Bool
chrSurrogate c = cast {to = Integer} c == 55296

%noinline
use : Int -> Integer
use x = let i = cast {to = Integer} x in if i > 5 then i * 2 else i + 1

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  printLn [intLe (k - 2), intLe (k - 1), intLe k]
  printLn [intNat (k - 3), intNat k, intNat (k + 3)]
  printLn [litFirst (k + 98), litFirst (k + 99), litFirst (k + 100)]
  printLn [eq8 (cast (k + 199)), eq8 (cast (k + 200))]
  printLn [outHigh8 (cast (k + 254)), outLow8 (cast (k + 254)), outEq8 (cast (k + 254))]
  printLn [signed8 (cast (k - 6)), signed8 (cast (k - 5)), signed8 (cast (k - 4))]
  printLn [signedOut (cast (k - 128)), signedOut (cast k)]
  printLn [big (cast k), big (cast (k - 100))]
  printLn [bits64 (cast (k - 1) - 1), bits64 (cast k)]
  printLn [chr' (cast (64 + k - 1)), chr' (cast (64 + k)), chrOut 'z']
  printLn [use (k + 4), use (k + 5), use (k + 6)]
  printLn [int16 (cast (k - 32769)), int16 (cast (k - 1)), int16In (cast (k + 98)), int16In (cast (k + 99))]
  printLn [int32 (cast (k + 2147483646)), int32In (cast (k - 8)), int32In (cast (k - 7))]
  printLn [bits16 (cast (k + 65534)), bits16 (cast k), bits32 (cast (k - 2)), bits32 (cast k)]
  printLn [intOut (cast k), int8High (cast k), int8High (cast (k + 126))]
  printLn [chrNeg 'a', chrHigh 'a', chrSurrogate 'a', chrSurrogate (cast (55295 + k))]
  printLn [bits64 (cast (k - 1)), bits64 (cast (k - 2)), bits64 (cast k)]
