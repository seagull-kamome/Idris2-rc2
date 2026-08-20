module Main

-- Measures Compiler.RC2.ConAltNative's own "reuse the original Boxed
-- field for surviving Boxed-context reads" optimisation (see
-- rc2/doc/con-alt-native.md): `x` here is destructured out of `Pair`
-- and read both natively (`x + y`) and in a Boxed context (placed
-- as-is into the freshly-built `Pair`'s own first field) within the
-- same alt -- exactly the shape that used to force a fresh
-- `idris2rc2_mkInt64` reallocation on every call before this
-- optimisation, and now shares the original field's own identity via
-- an ordinary `dup` instead. `x`'s own value (123456) is deliberately
-- outside the 0-99 small-int cache (`support/rc2/memory.c`) so the
-- reallocation this measures is a real `malloc`, not a free cache hit.

data Pair = MkPair Int Int

work : Pair -> Pair
work (MkPair x y) = MkPair x (x + y)

loop : Int -> Pair -> Pair
loop 0 p = p
loop n (MkPair x y) = loop (n - 1) (work (MkPair x (y + 1)))

main : IO ()
main = case loop 3000000 (MkPair 123456 0) of
            MkPair x y => printLn (x, y)
