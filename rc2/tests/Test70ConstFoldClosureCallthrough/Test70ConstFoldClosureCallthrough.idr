module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Correctness/leak regression for dispatching through a
-- Compiler.RC2.ConstFold-folded interface dictionary (see
-- Test69ConstFoldClosureDict for the structural fold itself), modeled
-- directly on Test18ClosureInPlaceGrow's own rigor: call the folded
-- dictionary's own methods many times in a loop, confirming correct
-- output on every iteration AND valgrind-cleanliness.
--
-- `Greeter Dog`'s own dictionary is built exactly once, folded to a
-- single immortal `RCConstCon` referencing two `RCConstClosure`
-- fields, and that one static is what `loopCall`'s own self-tail loop
-- (`Compiler.RC2.Loop`) reads on every one of its 500 iterations --
-- `idris2rc2_applyClosure`'s own non-unique dispatch path
-- (`idris2rc2_dispatchWithExtra`/`idris2rc2_trampoline`) therefore runs
-- against an object whose header is permanently
-- `IDRIS2RC2_REFCOUNT_MAX` every single time, never a freshly-`dup`'d
-- ordinary refcount. If the `REFCOUNT_MAX` reasoning behind treating
-- such an object as immortal were ever wrong (e.g. some path
-- decrementing its refcount as if it were an ordinary value), repeated
-- dispatch would eventually corrupt the marker down to a real finite
-- count, producing a use-after-free or a wrong answer on a *later*
-- iteration -- not merely a one-shot leak -- which is exactly what
-- running this for hundreds of iterations under valgrind is meant to
-- catch that a single call could not.

interface Greeter a where
  greet : a -> String
  loud : a -> String

data Dog = MkDog

Greeter Dog where
  greet MkDog = "woof"
  loud MkDog = "WOOF!!"

useGreeter : Greeter a => a -> Int -> String
useGreeter x n = greet x ++ show n ++ " " ++ loud x

loopCall : Int -> Int -> IO ()
loopCall n limit =
  if n >= limit
     then pure ()
     else do
       putStrLn (useGreeter MkDog n)
       loopCall (n + 1) limit

main : IO ()
main = loopCall 0 500
