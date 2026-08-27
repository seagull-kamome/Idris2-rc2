module Main

import Data.Bits

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.Emit's ROp reuse-in-place for Boxed
-- Integer arithmetic (rc2/support/rc2/numeric.h's Add/Sub/Mul/Mod/BAnd/
-- BOr/BXOr/ShiftL/ShiftR/Neg now consuming both their operands and
-- reusing a uniquely-referenced one's own mpz_t storage in place instead
-- of always allocating fresh -- see rc2/doc/rop-reuse.md). `bigFactorial`
-- computes a factorial well past both the small-int cache ([0,100),
-- immortal, so never a reuse candidate) and 64-bit range, forcing
-- genuine GMP heap allocations. Its accumulator `acc` is dying and
-- uniquely referenced on every self-tail-call iteration (no other
-- reference to the previous `acc` survives), so once `acc` first grows
-- past the small-int cache, every later `acc * n` should reuse that same
-- one heap allocation in place rather than allocating a fresh Integer
-- per iteration -- verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks" despite the deep
-- self-tail recursion.
bigFactorial : Integer -> Integer -> Integer
bigFactorial 0 acc = acc
bigFactorial n acc = bigFactorial (n - 1) (acc * n)

-- `Mod`/`BAnd`/`BOr`/`BXOr`/`ShiftL`/`ShiftR` coverage (via `Data.Bits`'s
-- `Bits Integer`, backed by `prim__and_Integer`/etc.) -- none of these
-- were previously exercised at a magnitude past the small-int cache
-- anywhere in this suite, so this doubles as first-time correctness
-- coverage for the reuse-consuming rewrite of each one, cross-checked
-- against the pinned reference `idris2 --cg refc` same as every other
-- smoke test.
bigBitOps : Integer -> Integer
bigBitOps n =
  let a = n .&. (n + 1)
      b = a .|. (n * 2)
      c = xor b (n - 1)
      d = c `shiftL` 3
      e = d `shiftR` 1
  in e `mod` (n + 1)

main : IO ()
main = do
  printLn (bigFactorial 30 1)
  printLn (bigFactorial 0 1)
  printLn (the Integer (negate (bigFactorial 25 1)))
  printLn (bigBitOps (bigFactorial 25 1))
