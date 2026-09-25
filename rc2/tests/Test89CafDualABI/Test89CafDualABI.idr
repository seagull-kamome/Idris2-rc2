module Main

-- A CAF that can't be folded to a constant is memoized
-- (`doc/caf-memoization.md`), and its body must still get everything
-- an ordinary function body gets after RC annotation: DualABI's
-- native call-site rewrite, its inline FFI splicing, and Sink.
-- `table` calls a `%foreign` function on a value computed by a
-- `%noinline` function, so ConstFold can't fold it and the call has
-- to be spliced inside the memoized body.

%foreign "C:abs,libc,stdlib.h"
prim__abs : Int -> Int

%noinline
offset : Int -> Int
offset x = x - 10

table : Int
table = prim__abs (offset 3) * 1000 + prim__abs (offset 25)

main : IO ()
main = do
  printLn table
  printLn (table + 1)
