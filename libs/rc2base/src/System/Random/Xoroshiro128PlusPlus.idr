module System.Random.Xoroshiro128PlusPlus

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- xoshiro128++ (Blackman & Vigna, 2018, public domain), the 32-bit-output
-- member of the xoshiro/xoroshiro family: 128 bits of state held as four
-- Bits32 words, not two Bits64 words -- unlike the more famous
-- xoroshiro128++ (64-bit output, 2x64 state), which is a different
-- algorithm with different rotation constants and a different state
-- shape, not just a truncated/packed variant of this one.
--
-- Original C reference implementations this module ports (both public
-- domain, Blackman & Vigna):
--   https://prng.di.unimi.it/xoshiro128plusplus.c  (the `next` step)
--   https://prng.di.unimi.it/splitmix64.c           (`seed`'s expansion)
--
-- Deliberately kept as 4 Bits32 fields rather than packed into 2 Bits64
-- fields, even though that looks like the more "natural" 128-bit layout:
-- `Bits32` (and every other <=32-bit scalar) is one of rc2's own
-- alwaysUnboxed types (`Compiler.RC2.Types.alwaysUnboxed`) -- a tagged
-- pointer, never a real heap allocation, with `idris2rc2_dup`/`drop`
-- already a no-op against it and every arithmetic op
-- (`rc2/support/rc2/numeric.h`'s `IDRIS2RC2_INTTYPES_TAGGED` macros)
-- pure pointer-tag manipulation. `Bits64` is not in that set -- it's a
-- real heap-boxed value needing an allocation and refcount traffic per
-- new value. Packing to 2x64 would shrink `Gen`'s own constructor
-- (`args[]` of 2 slots instead of 4), but would need to box a fresh
-- Bits64 for each repacked half on every `next` call, plus the actual
-- pack/unpack shifting to get back at the algorithm's own 32-bit halves
-- -- very likely a net loss, not a win, under rc2's own cost model.

import Data.Bits
import Data.IORef
import System
import System.Clock

||| 128 bits of xoshiro128++ state, as four Bits32 words (`s[0..3]` in the
||| reference implementation).
public export
record Gen where
  constructor MkGen
  s0, s1, s2, s3 : Bits32

-- splitmix64 (Vigna, public domain) -- used only to expand a single Bits64
-- seed into four well-mixed Bits32 words for `Gen`'s own initial state,
-- not part of xoshiro128++ itself. Returns (output, next splitmix64 state).
splitmix64Next : Bits64 -> (Bits64, Bits64)
splitmix64Next state =
  let state' = state + 0x9e3779b97f4a7c15
      z0     = state'
      z1     = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
      z2     = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  in (z2 `xor` (z2 `shiftR` 31), state')

||| Expand a single 64-bit seed into a full `Gen` via two splitmix64 steps
||| (one per pair of Bits32 words), each split into its upper/lower half.
export
seed : Bits64 -> Gen
seed s =
  let (a, s')  = splitmix64Next s
      (b, _)   = splitmix64Next s'
  in MkGen (cast (a `shiftR` 32)) (cast a) (cast (b `shiftR` 32)) (cast b)

rotl32 : Bits32 -> (k : Fin 32) -> (nk : Fin 32) -> Bits32
rotl32 x k nk = (x `shiftL` k) .|. (x `shiftR` nk)

||| One xoshiro128++ step: returns the next 32-bit output and the
||| successor state.
export
next : Gen -> (Bits32, Gen)
next (MkGen s0 s1 s2 s3) =
  let result = rotl32 (s0 + s3) 7 25 + s0
      t      = s1 `shiftL` 9
      s2'    = s2 `xor` s0
      s3'    = s3 `xor` s1
      s1'    = s1 `xor` s2'
      s0'    = s0 `xor` s3'
      s2''   = s2' `xor` t
      s3''   = rotl32 s3' 11 21
  in (result, MkGen s0' s1' s2'' s3'')

||| A step's output mapped to a uniform `Double` in `[0,1)`, at the
||| generator's own native 32-bit precision (`output / 2^32`).
export
nextDouble : Gen -> (Double, Gen)
nextDouble g =
  let (v, g') = next g
  in (cast v / 4294967296.0, g')

-- IORef-based convenience wrappers. Deliberately just `IORef Gen`, not an
-- opaque handle bundling a Mutex: a plain read-next-write cycle here is
-- not safe under concurrent access from multiple threads onto the *same*
-- `IORef` (the read and the write are two separate operations, not one
-- atomic step) -- a caller needing that guards the `IORef` with their own
-- `Mutex` (`System.Concurrency`), same as any other shared mutable state.
-- A fresh `IORef Gen` per thread needs no such guard at all.

||| Draw the next 32-bit output from a generator held in an `IORef`,
||| updating it in place.
export
nextBits32 : HasIO io => IORef Gen -> io Bits32
nextBits32 ref = do
  g <- readIORef ref
  let (v, g') = next g
  writeIORef ref g'
  pure v

||| Draw the next `Double` in `[0,1)` from a generator held in an `IORef`,
||| updating it in place.
export
nextDoubleIO : HasIO io => IORef Gen -> io Double
nextDoubleIO ref = do
  g <- readIORef ref
  let (v, g') = nextDouble g
  writeIORef ref g'
  pure v

||| Convenience constructor: a fresh `IORef Gen`, seeded from the
||| monotonic clock and the current process id. Not cryptographically
||| secure, just a reasonable non-fixed default -- use `seed` directly
||| (via `newIORef . seed`) for a reproducible, caller-chosen seed.
export
newSeeded : HasIO io => io (IORef Gen)
newSeeded = do
  clk <- liftIO (clockTime Monotonic)
  pid <- getPID
  let mixed = cast (toNano clk) `xor` cast pid
  newIORef (seed mixed)
