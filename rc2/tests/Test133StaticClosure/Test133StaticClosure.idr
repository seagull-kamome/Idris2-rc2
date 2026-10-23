module Main

import System

-- Closures over constants only are file-scope statics (`doc/static-closures.md`).
-- `mk` returns a partial application of `adder` to two constants; every call
-- gets the same immortal closure, which must stay intact when it is applied
-- again and again. `tailer` tail-calls the recursive `g` with constant
-- arguments: a saturated closure that the trampoline runs, once per call.

%noinline
adder : Int -> Int -> Int -> Int
adder a b c = a * 100 + b * 10 + c

%noinline
mk : Int -> (Int -> Int)
mk b = if b == 0 then adder 1 2 else adder 3 4

%noinline
g : Int -> Int -> List Int
g 0 _ = []
g n m = m :: g (n - 1) m

%noinline
tailer : Int -> List Int
tailer b = if b == 0 then g 5 7 else g 3 8

-- A partial application of constants that is never used: its dead `let` must not free
-- the static.
%noinline
unused : Int -> Int
unused b = let dead : Int -> Int := (if b == 0 then adder 4 5 else adder 6 7) in 1

%noinline
run : Int -> IO ()
run n = do
  printLn (map (mk n) [1, 2, 3, 4, 5])
  printLn (map (mk (1 - n)) [6, 7])
  printLn (tailer n)
  printLn (tailer (1 - n))
  printLn (length (concatMap tailer [n, 1 - n, n]))
  printLn (unused n + unused (1 - n))

main : IO ()
main = do
  -- the selector is only known at run time, so nothing below is folded away
  args <- getArgs
  run (cast (length args))  -- 1: getArgs holds the program name
