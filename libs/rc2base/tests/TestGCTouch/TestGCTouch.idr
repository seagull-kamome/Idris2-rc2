module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.GC.RC2.touch: callable on heap values (String, list, closure)
-- and on values rc2 represents natively at the call site (a computed and
-- a loop-carried Int, an Int beyond the immediate range, Double, Char,
-- Bits8, Bits64, Bool), each touched after a guarded action, without
-- changing what the program prints. The ordering of the touch against a
-- value's drop and the boxing of native arguments are checked by
-- check.sh on the generated C.

import Data.IORef
import System.GC.RC2

loop : Int -> Int -> IO Int
loop 0 acc = pure acc
loop n acc = do
  touch acc
  loop (n - 1) (acc + n)

main : IO ()
main = do
  r <- newIORef (the Int 0)
  let s = "hello" ++ " world"
  putStrLn "before"
  modifyIORef r (+ 1)
  touch s
  n <- readIORef r
  modifyIORef r (+ 1)
  touch (n * 3)
  touch (n * 4611686018427387904)
  touch (cast {to=Double} n + 0.5)
  touch (if n > 0 then 'x' else 'y')
  touch (cast {to=Bits8} n + 200)
  touch (cast {to=Bits64} n + 18446744073709551000)
  touch (n > 0)
  touch (the (List Int) [n, 2, 3])
  touch (\y : Int => y + n)
  m <- loop 10 n
  touch m
  putStrLn ("after " ++ show m)
