module System.Random.Xoroshiro64StarStar

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- xoroshiro64** (Blackman & Vigna, public domain), the 32-bit-output,
-- 64-bit-state member of the xoshiro/xoroshiro family -- a different
-- algorithm from System.Random.Xoroshiro128PlusPlus (64-bit output,
-- 128-bit state), not a truncated variant of it.
--
-- Like Xoroshiro128PlusPlus, this module is a thin FFI wrapper around a
-- direct C port of the reference
-- implementation (support/c/xoroshiro64starstar.c, itself a mechanical
-- rename of https://prng.di.unimi.it/xoroshiro64starstar.c) -- kept in C
-- mainly so the reference's own jump()/long_jump()/jump_ce()/jump_n()
-- machinery (exposed below as jump/longJump/jumpCE/jumpN, plus their
-- *IO global-generator counterparts) stays available with no
-- from-scratch F2X-polynomial-arithmetic port to Idris needed.
--
-- The 8-byte state lives in a `Buffer`. Seeding it goes through the
-- standard `Data.Buffer.setBits32` (backed by "RefC:setBufferUInt32LE",
-- little-endian by construction), while `next` itself calls straight
-- into the reference C algorithm via the "C" tag: `Compiler.RC2.
-- EmitUtil`'s `extractValue CLangC CFBuffer` unwraps a `Buffer` argument
-- to a flat pointer straight at its data (no size header in the way), so
-- the C side can treat it exactly as the reference algorithm's own
-- `uint32_t s[2]`, reading both bytes 0..3 and 4..7 as native-endian
-- words. The two only agree on every realistic target (x86/x86_64/ARM in
-- their default little-endian mode) because "native" there already means
-- "little-endian" -- not a coincidence this project relies on elsewhere,
-- but not a real risk in practice either.

import Data.Bits
import Data.Buffer
import System
import System.Clock
import System.Linux.Random
import System.Posix.Errno

%default covering

||| A single instance's 64 bits of xoroshiro64** state, held as an 8-byte
||| `Buffer` (`s[0..1]` in the reference implementation) -- mutated in
||| place by `next`. `Gen` below is the pure counterpart.
export
data IOGen = MkIOGen Buffer

-- ----------------------------------------------------------------------------
-- FFI: support/c/xoroshiro64starstar.c

%foreign "C:idris2rc2_System_Random_set_system_seed,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__setSystemSeed : Bits64 -> PrimIO ()

%foreign "C:idris2rc2_System_Random_next_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__nextSys : PrimIO Bits32

%foreign "C:idris2rc2_System_Random_next,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__next : Buffer -> PrimIO Bits32

%foreign "C:idris2rc2_System_Random_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__jump : Buffer -> PrimIO ()

%foreign "C:idris2rc2_System_Random_jump_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__jumpSys : PrimIO ()

%foreign "C:idris2rc2_System_Random_long_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__longJump : Buffer -> PrimIO ()

%foreign "C:idris2rc2_System_Random_long_jump_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__longJumpSys : PrimIO ()

%foreign "C:idris2rc2_System_Random_jump_ce,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__jumpCE : Buffer -> Bits64 -> Bits32 -> PrimIO ()

%foreign "C:idris2rc2_System_Random_jump_ce_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__jumpCESys : Bits64 -> Bits32 -> PrimIO ()

%foreign "C:idris2rc2_System_Random_jump_n,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__jumpN : Buffer -> Bits64 -> PrimIO ()

%foreign "C:idris2rc2_System_Random_jump_n_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__jumpNSys : Bits64 -> PrimIO ()

-- ----------------------------------------------------------------------------
-- splitmix64 (Vigna, public domain) -- same construction as
-- Xoroshiro128PlusPlus.splitmix64Next, duplicated locally rather than
-- shared: both modules are otherwise self-contained, each citing its own
-- reference source directly. Used only to mix a caller-given Bits64 seed
-- into a well-diffused state, not part of xoroshiro64** itself.
splitmix64Next : Bits64 -> (Bits64, Bits64)
splitmix64Next state =
  let state' = state + 0x9e3779b97f4a7c15
      z0     = state'
      z1     = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
      z2     = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  in (z2 `xor` (z2 `shiftR` 31), state')

||| One splitmix64 step's full 64-bit output, split into `(s[0], s[1])`
||| halves in the same lower/upper order
||| `idris2rc2_System_Random_set_system_seed` uses (`s[0]` = low 32 bits
||| = buffer offset 0, `s[1]` = high 32 bits = buffer offset 4) --
||| matched deliberately so `newIOGen`/`next` and `setSystemSeed`/
||| `nextIO` reach the identical state, and therefore the identical
||| output sequence, from the same `Bits64` seed. This generator's entire
||| state is 64 bits (`s[0]`, `s[1]`), so (unlike Xoroshiro128PlusPlus.
||| seed, which needs two splitmix64 steps for its 128 bits) a single
||| step suffices here.
mixSeed : Bits64 -> (Bits32, Bits32)
mixSeed s = let (v, _) = splitmix64Next s in (cast v, cast (v `shiftR` 32))

-- ----------------------------------------------------------------------------

||| A fresh per-instance generator, seeded (via one splitmix64 step, to
||| avoid handing the algorithm a poorly-diffused or all-zero state) from
||| a caller-chosen `Bits64`. `Nothing` only on buffer allocation failure.
export
newIOGen : HasIO io => Bits64 -> io (Maybe IOGen)
newIOGen s = do
  Just buf <- newBuffer 8
    | Nothing => pure Nothing
  let (s0, s1) = mixSeed s
  setBits32 buf 0 s0
  setBits32 buf 4 s1
  pure $ Just $ MkIOGen buf

||| Clone a generator's current state into a fresh, independent
||| `IOGen` -- the copy produces the exact same output sequence as the
||| original from this point on, but mutating one (via `next`/`jump`*)
||| has no effect on the other, since each holds its own `Buffer`.
||| `Nothing` only on the new buffer's own allocation failure.
export
copyIOGen : HasIO io => IOGen -> io (Maybe IOGen)
copyIOGen (MkIOGen buf) = do
  Just buf' <- newBuffer 8
    | Nothing => pure Nothing
  copyData buf 0 8 buf' 0
  pure $ Just $ MkIOGen buf'

||| Draw the next 32-bit output from a generator, updating its state
||| (held in the underlying `Buffer`) in place.
export
next : HasIO io => IOGen -> io Bits32
next (MkIOGen buf) = primIO $ prim__next buf

||| A step's output mapped to a uniform `Double` in `[0,1)`, at the
||| generator's own native 32-bit precision (`output / 2^32`) -- same
||| formula as `Xoroshiro128PlusPlus.nextDouble`.
export
nextDouble : HasIO io => IOGen -> io Double
nextDouble g = do
  v <- next g
  pure (cast v / 4294967296.0)

||| Equivalent to 2^32 calls to `next` -- advances a generator to the
||| start of one of 2^32 non-overlapping subsequences, useful for
||| handing out independent streams to parallel computations.
export
jump : HasIO io => IOGen -> io ()
jump (MkIOGen buf) = primIO $ prim__jump buf

||| Equivalent to 2^48 calls to `next` -- like `jump`, but for 2^16
||| starting points each 2^32 apart (so `jump` can still be used within
||| each to hand out 2^16 further non-overlapping subsequences).
export
longJump : HasIO io => IOGen -> io ()
longJump (MkIOGen buf) = primIO $ prim__longJump buf

||| Equivalent to `c * 2^e` calls to `next` -- e.g. `jumpCE g 1 32` is
||| `jump g`, `jumpCE g 1 48` is `longJump g`. Expressing the distance
||| this way avoids handling a multiple-precision integer for ordinary
||| jump counts (`jumpCE g k 0`) or power-of-two multiples. For the jump
||| to be meaningful, `c * 2^e` should stay under the generator's period
||| (2^64 - 1).
export
jumpCE : HasIO io => IOGen -> (c : Bits64) -> (e : Bits32) -> io ()
jumpCE (MkIOGen buf) c e = primIO $ prim__jumpCE buf c e

||| Equivalent to `n` calls to `next`, for an arbitrary distance `n`
||| (should stay under the generator's period, 2^64 - 1, for the jump to
||| be meaningful) -- more general than `jumpCE`, taking `n` directly
||| since this generator's 64-bit state means any distance always fits
||| in one `Bits64` (unlike the reference algorithm's own general
||| POLY_WORDS-word `jump[]` array, sized for generators with larger
||| state).
export
jumpN : HasIO io => IOGen -> (n : Bits64) -> io ()
jumpN (MkIOGen buf) n = primIO $ prim__jumpN buf n

||| Convenience constructor: a fresh generator, seeded with 64 random bits
||| from the kernel (`getrandom`, which two processes started together
||| do not share). Only when that fails (a system call a sandbox forbids,
||| say) is the seed the monotonic clock mixed with the process id, which
||| processes started at about the same time can share. The generator is
||| not cryptographically secure -- use `newIOGen` directly for a
||| reproducible, caller-chosen seed. `Nothing` only on buffer allocation
||| failure (unlike `Xoroshiro128PlusPlus.newSeeded`, which wraps a plain
||| `IORef` and so can't fail this way).
export
newSeeded : HasIO io => io (Maybe IOGen)
newSeeded = do
  r <- liftIO (getrandomBits64 0)
  seed <- case r of
    Right s => pure s
    Left _ => do
      clk <- liftIO (clockTime Monotonic)
      pid <- getPID
      pure (cast (toNano clk) `xor` cast pid)
  newIOGen seed

-- ----------------------------------------------------------------------------
-- A separate, single global generator held entirely in C-side static
-- state (`support/c/xoroshiro64starstar.c`'s own `system_seed[2]`) --
-- not thread-safe (no locking around the shared mutable state, unlike
-- even the "caller must guard their own IORef/Buffer" contract the
-- per-instance API above leaves to callers), offered purely as a
-- quick, no-instance-to-carry-around convenience akin to C's own
-- rand()/srand(). Prefer `newIOGen`/`next` for anything concurrent or
-- reproducible.

||| Seed the single global generator (via one splitmix64 step, same
||| mixing `newIOGen` applies -- the underlying C function just stores
||| whatever 64-bit value it's given, so the mixing has to happen here).
export
setSystemSeed : HasIO io => Bits64 -> io ()
setSystemSeed s = let (mixed, _) = splitmix64Next s in primIO $ prim__setSystemSeed mixed

||| Draw the next 32-bit output from the single global generator.
export
nextIO : HasIO io => io Bits32
nextIO = primIO $ prim__nextSys

||| `jump` applied to the single global generator.
export
jumpIO : HasIO io => io ()
jumpIO = primIO prim__jumpSys

||| `longJump` applied to the single global generator.
export
longJumpIO : HasIO io => io ()
longJumpIO = primIO prim__longJumpSys

||| `jumpCE` applied to the single global generator.
export
jumpCEIO : HasIO io => (c : Bits64) -> (e : Bits32) -> io ()
jumpCEIO c e = primIO $ prim__jumpCESys c e

||| `jumpN` applied to the single global generator.
export
jumpNIO : HasIO io => (n : Bits64) -> io ()
jumpNIO n = primIO $ prim__jumpNSys n

-- ----------------------------------------------------------------------------
-- A pure generator: the two state words as a value, stepped by the same
-- C algorithm as `IOGen` (support/c/xoroshiro64starstar.c, the
-- `pure_*` functions). Each returns one word, so the `%foreign`
-- declarations carry no PrimIO and no Buffer.

||| The 64 bits of xoroshiro64** state, `(s[0], s[1])`. A value: every
||| step returns the next one.
export
data Gen = MkGen Bits32 Bits32

%foreign "C:idris2rc2_System_Random_pure_out,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureOut : Bits32 -> Bits32 -> Bits32

%foreign "C:idris2rc2_System_Random_pure_s0,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureS0 : Bits32 -> Bits32 -> Bits32

%foreign "C:idris2rc2_System_Random_pure_s1,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureS1 : Bits32 -> Bits32 -> Bits32

-- A jump runs once and gives the new state packed in a `Bits64`: s[0] in the
-- low half, s[1] in the high half (`fromPacked`).
%foreign "C:idris2rc2_System_Random_pure_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureJump : Bits32 -> Bits32 -> Bits64

%foreign "C:idris2rc2_System_Random_pure_long_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureLongJump : Bits32 -> Bits32 -> Bits64

%foreign "C:idris2rc2_System_Random_pure_jump_ce,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureJumpCE : Bits32 -> Bits32 -> Bits64 -> Bits32 -> Bits64

%foreign "C:idris2rc2_System_Random_pure_jump_n,libidris2rc2base,idris2rc2_rc2base_xoroshiro64starstar.h"
prim__pureJumpN : Bits32 -> Bits32 -> Bits64 -> Bits64

fromPacked : Bits64 -> Gen
fromPacked w = MkGen (cast w) (cast (w `shiftR` 32))

||| The generator `newIOGen` would create from the same seed (the same
||| splitmix64 step), so both produce the same sequence.
export
mkGen : Bits64 -> Gen
mkGen s = let (s0, s1) = mixSeed s in MkGen s0 s1

||| The next 32-bit output and the generator after that step.
export
genNext : Gen -> (Bits32, Gen)
genNext (MkGen s0 s1) = (prim__pureOut s0 s1, MkGen (prim__pureS0 s0 s1) (prim__pureS1 s0 s1))

||| A step's output as a uniform `Double` in `[0,1)` (`output / 2^32`),
||| as `nextDouble` does.
export
genNextDouble : Gen -> (Double, Gen)
genNextDouble g = let (v, g') = genNext g in (cast v / 4294967296.0, g')

||| `jump` on a value: 2^32 steps ahead.
export
genJump : Gen -> Gen
genJump (MkGen s0 s1) = fromPacked (prim__pureJump s0 s1)

||| `longJump` on a value: 2^48 steps ahead.
export
genLongJump : Gen -> Gen
genLongJump (MkGen s0 s1) = fromPacked (prim__pureLongJump s0 s1)

||| `jumpCE` on a value: `c * 2^e` steps ahead.
export
genJumpCE : Gen -> (c : Bits64) -> (e : Bits32) -> Gen
genJumpCE (MkGen s0 s1) c e = fromPacked (prim__pureJumpCE s0 s1 c e)

||| `jumpN` on a value: `n` steps ahead.
export
genJumpN : Gen -> (n : Bits64) -> Gen
genJumpN (MkGen s0 s1) n = fromPacked (prim__pureJumpN s0 s1 n)
