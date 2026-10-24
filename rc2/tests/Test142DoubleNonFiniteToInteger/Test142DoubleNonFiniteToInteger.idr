module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `cast` from a `Double` that is NaN or infinite to `Integer` has no value to
-- return. GMP's `mpz_set_d` raises SIGFPE on it (so does RefC); rc2 returns 0
-- instead of killing the process. The operands come from the command line so
-- nothing folds at compile time.

import System

%default total

main : IO ()
main = do
  args <- getArgs
  let n : Double = cast (length args) - 1
  let nan : Double = 0.0 / n
  let inf : Double = 1.0 / n
  let ninf : Double = -1.0 / n
  putStrLn ("NaN: " ++ show (the Integer (cast nan)))
  putStrLn ("inf: " ++ show (the Integer (cast inf)))
  putStrLn ("-inf: " ++ show (the Integer (cast ninf)))
  -- finite values are unchanged
  putStrLn ("big: " ++ show (the Integer (cast (1.0e30 + n))))
  putStrLn ("small: " ++ show (the Integer (cast (-2.75 + n))))
