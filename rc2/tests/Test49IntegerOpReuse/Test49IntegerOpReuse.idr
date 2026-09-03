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
-- self-tail recursion. Also covers the same mechanism's extension to
-- Int64/Bits64/Double, formerly a separate Test50FixedWidthOpReuse.idr
-- (merged in further below, see that section's own header note).
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

-- Extends the coverage above from `Integer` (GMP `mpz_t`-backed) to
-- `Int64`/`Bits64`/`Double` -- formerly a separate
-- Test50FixedWidthOpReuse.idr, merged in below: same reuse-consuming
-- idea (rc2/support/rc2/numeric.h's Add/Sub/Mul/Div/Mod/BAnd/BOr/BXOr/
-- ShiftL/ShiftR/Neg on these three types), but simpler -- fixed-size
-- payloads, so a unique operand's own struct field gets overwritten in
-- place instead of a GMP mutation. Unlike Integer, Int8/16/32/
-- Bits8/16/32 are deliberately NOT extended this way (always a tagged
-- pointer, never a real heap allocation -- see
-- Compiler.RC2.EmitUtil's isReuseConsumingOp own doc comment).
--
-- `sumInt64`/`sumBits64`/`sumDouble` each accumulate past the
-- small-int cache ([0,100), immortal, never a reuse candidate) via a
-- self-tail recursive loop, so the accumulator is dying and uniquely
-- referenced on every iteration once past that boundary.
sumInt64 : Int64 -> Int64 -> Int64
sumInt64 0 acc = acc
sumInt64 n acc = sumInt64 (n - 1) (acc + n * 1000)

sumBits64 : Bits64 -> Bits64 -> Bits64
sumBits64 0 acc = acc
sumBits64 n acc = sumBits64 (n - 1) (acc + n * 1000)

sumDouble : Int64 -> Double -> Double
sumDouble 0 acc = acc
sumDouble n acc = sumDouble (n - 1) (acc + cast n * 1000.0)

-- Div/Mod/bitwise coverage across both int types (first time any of
-- these are exercised at a magnitude past the small-int cache for
-- Int64/Bits64). `bitOpsInt64` also covers the reuse-consuming `Neg`
-- rewrite for a fixed-width type via a direct `negate` call (`Bits64`
-- has no `Neg` instance to exercise the same way).
bitOpsInt64 : Int64 -> Int64
bitOpsInt64 n =
  let a = n .&. (n + 1)
      b = a .|. (n * 2)
      c = xor b (n - 1)
      d = c `shiftL` 3
      e = d `shiftR` 1
  in negate (e `div` (n + 1)) `mod` (n + 1000)

bitOpsBits64 : Bits64 -> Bits64
bitOpsBits64 n =
  let a = n .&. (n + 1)
      b = a .|. (n * 2)
      c = xor b (n - 1)
      d = c `shiftL` 3
      e = d `shiftR` 1
  in (e `div` (n + 1)) `mod` (n + 1000)

main : IO ()
main = do
  printLn (bigFactorial 30 1)
  printLn (bigFactorial 0 1)
  printLn (the Integer (negate (bigFactorial 25 1)))
  printLn (bigBitOps (bigFactorial 25 1))
  printLn (sumInt64 100000 0)
  printLn (sumBits64 100000 0)
  printLn (sumDouble 100000 0.0)
  printLn (bitOpsInt64 123456789)
  printLn (bitOpsBits64 123456789)
