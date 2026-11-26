module Main

import System

-- rc2/doc/const-caf-fold.md, "Casts between Char and integers" and
-- "Identities": a cast between `Char` and an integer constant folds as
-- the runtime computes it (a codepoint, else NUL), and an `Integer`'s
-- `x + 0`, `0 + x` and `x - 0` and a string's `"" ++ s` and `s ++ ""` are
-- the other operand.

%noinline
big : Integer -> Integer
big x = (x + 0) * (0 + x) - (x - 0)

main : IO ()
main = do
  printLn (map ord [cast (the Int 160), cast (the Int 0xD7FF), cast (the Int 0xD800), cast (the Int 0xDFFF),
                    cast (the Int 0xE000), cast (the Int 0x10FFFF), cast (the Int 0x110000), cast (the Int (-1))])
  printLn (map ord [cast (the Int8 (-3)), cast (the Bits8 200), cast (the Bits64 18446744073709551615),
                    cast (the Integer 65), cast (the Integer 100000000000000000000)])
  printLn (the Int (cast 'A'), the Integer (cast '\x1F600'), the Bits32 (cast 'z'), the Int64 (cast '\x10FFFF'))
  k <- cast . length <$> getArgs
  printLn (big (k * 100000000000000000000 + 7))
  let s = show k
  putStrLn ("" ++ s ++ "")
