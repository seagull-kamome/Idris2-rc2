module Main

import Data.Bits
import System

-- ConstFold folds `Int` like `Int64` (rc2's `Int` is C's `int64_t`), and
-- reads large `Integer` literals, so `fromInteger` of an `Int` literal
-- no longer builds an `Integer` at run time. Each line is printed twice:
-- once from literals only (folded at compile time) and once through
-- `one`, which is only known at run time, so the two must agree. Signed
-- overflow is left out: it is undefined in C.

main : IO ()
main = do
  args <- getArgs
  let one : Int = cast (length args)
  printLn (the Int 1000 + 2345, one * 1000 + 2345)
  printLn (the Int 9223372036854775807, one * 9223372036854775807)
  printLn (the Int (-9223372036854775807) - 1, one * (-9223372036854775807) - 1)
  printLn (div (the Int (-7)) 2, div (one * (-7)) 2)
  printLn (mod (the Int (-7)) 2, mod (one * (-7)) 2)
  printLn (div (the Int 7) (-2), div (one * 7) (-2))
  printLn (shiftL (the Int 1) 40, shiftL one 40)
  printLn (shiftR (the Int 1099511627776) 20, shiftR (one * 1099511627776) 20)
  printLn (cast {to = Int} (the Integer 18446744073709551621),
           cast {to = Int} (the Integer 18446744073709551620 + cast one))
  printLn (cast {to = Int} (the Integer (-1)), cast {to = Int} (the Integer 0 - cast one))
  printLn (cast {to = Integer} (the Int 4611686018427387904) * 4,
           cast {to = Integer} (one * 4611686018427387904) * 4)
  printLn (show (the Int 123456789), show (one * 123456789))
  printLn (the Integer 1000000 * 1000000, the Integer 1000000 * 1000000 * cast one)
