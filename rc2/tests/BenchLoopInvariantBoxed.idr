module Main

-- Measures Compiler.RC2.Loop's own "reuse the original Boxed value for
-- a surviving Boxed-context read of a loop-invariant parameter"
-- optimisation (see rc2/doc/loop-conversion.md's own "Loop-invariant
-- parameter elision" section): `limit` here is loop-invariant, read
-- both natively (`n >= limit`) and in a Boxed context (placed as-is
-- into a freshly-built `Pair`'s own first field) on the loop's own
-- *continue* path -- re-executed once per iteration -- within the
-- same loop body. `limit`'s own value (3000000) is deliberately
-- outside the 0-99 small-int cache (`support/rc2/memory.c`) so the
-- reallocation this measures is a real `malloc`, not a free cache
-- hit; it also doubles as the iteration count.

data Pair = MkPair Int Int

useLimit : Pair -> Int
useLimit (MkPair l a) = l + a

loop : Int -> Int -> Int -> Int
loop limit acc n =
  if n >= limit
     then acc
     else loop limit (useLimit (MkPair limit acc)) (n + 1)

main : IO ()
main = printLn (loop 3000000 0 0)
