module System.Random.Xoroshiro128PlusPlus

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- xoroshiro128++ 1.0 (Blackman & Vigna, 2019, public domain), the
-- 64-bit-output, 128-bit-state member of the xoshiro/xoroshiro family --
-- a different algorithm from System.Random.Xoroshiro64StarStar (64-bit
-- state, 32-bit output), not a scaled-up variant of it. (An earlier
-- version of this module implemented xoshiro128++ instead -- a
-- different generator that happens to share the "128" and "++" naming,
-- 32-bit output over 4x Bits32 state -- under this same module name;
-- that implementation has been replaced outright by the real
-- xoroshiro128++ ported below, not merely renamed.)
--
-- Like Xoroshiro64StarStar (and unlike that earlier xoshiro128++ port,
-- which was from-scratch pure Idris), this module is a thin FFI wrapper
-- around a direct C port of the reference implementation
-- (support/c/xoroshiro128plusplus.c, itself a mechanical rename of
-- https://prng.di.unimi.it/xoroshiro128plusplus.c) -- kept in C mainly
-- so the reference's own jump()/long_jump()/jump_ce()/jump_n()
-- machinery (exposed below as jump/longJump/jumpCE/jumpN, plus their
-- *IO global-generator counterparts) stays available with no
-- from-scratch F2X-polynomial-arithmetic port to Idris needed.
--
-- The 16-byte state lives in a `Buffer`. Seeding it goes through the
-- standard `Data.Buffer.setBits64` (backed by "RefC:setBufferUInt64LE",
-- little-endian by construction), while `next` itself calls straight
-- into the reference C algorithm via the "C" tag: `Compiler.RC2.
-- EmitUtil`'s `extractValue CLangC CFBuffer` unwraps a `Buffer` argument
-- to a flat pointer straight at its data (no size header in the way), so
-- the C side can treat it exactly as the reference algorithm's own
-- `uint64_t s[2]`, reading both bytes 0..7 and 8..15 as native-endian
-- words. The two only agree on every realistic target (x86/x86_64/ARM in
-- their default little-endian mode) because "native" there already means
-- "little-endian" -- not a coincidence this project relies on elsewhere,
-- but not a real risk in practice either.
--
-- `IOGen` is abstract and only `newIOGen`/`copyIOGen` make one, each with a
-- 16-byte `Buffer` (a malloc'd block, aligned for a `uint64_t`), so the C side
-- never sees a buffer of another size. On a big-endian host the seeded words
-- would be byte-swapped against what the C code reads and the sequences
-- would differ from the pure `Gen`'s: rc2 targets little-endian hosts only.

import Data.Bits
import Data.Buffer
import System
import System.Clock
import System.Random.Entropy

%default covering

||| A single instance's 128 bits of xoroshiro128++ state, held as a
||| 16-byte `Buffer` (`s[0..1]` in the reference implementation) --
||| mutated in place by `next`.
export
data IOGen = MkIOGen Buffer

-- ----------------------------------------------------------------------------
-- FFI: support/c/xoroshiro128plusplus.c

%foreign "C:idris2rc2_System_Random128_set_system_seed,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__setSystemSeed : Bits64 -> Bits64 -> PrimIO ()

%foreign "C:idris2rc2_System_Random128_next_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__nextSys : PrimIO Bits64

%foreign "C:idris2rc2_System_Random128_next,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__next : Buffer -> PrimIO Bits64

%foreign "C:idris2rc2_System_Random128_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__jump : Buffer -> PrimIO ()

%foreign "C:idris2rc2_System_Random128_jump_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__jumpSys : PrimIO ()

%foreign "C:idris2rc2_System_Random128_long_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__longJump : Buffer -> PrimIO ()

%foreign "C:idris2rc2_System_Random128_long_jump_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__longJumpSys : PrimIO ()

%foreign "C:idris2rc2_System_Random128_jump_ce,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__jumpCE : Buffer -> Bits64 -> Bits32 -> PrimIO ()

%foreign "C:idris2rc2_System_Random128_jump_ce_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__jumpCESys : Bits64 -> Bits32 -> PrimIO ()

%foreign "C:idris2rc2_System_Random128_jump_n,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__jumpN : Buffer -> Bits64 -> Bits64 -> PrimIO ()

%foreign "C:idris2rc2_System_Random128_jump_n_sys,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__jumpNSys : Bits64 -> Bits64 -> PrimIO ()

-- ----------------------------------------------------------------------------
-- splitmix64 (Vigna, public domain) -- same construction as
-- Xoroshiro64StarStar.splitmix64Next, duplicated locally rather than
-- shared: both modules are otherwise self-contained, each citing its own
-- reference source directly. This is exactly the seeding method the
-- reference implementation's own header comment suggests ("If you have a
-- 64-bit seed, we suggest to seed a splitmix64 generator and use its
-- output to fill s").
splitmix64Next : Bits64 -> (Bits64, Bits64)
splitmix64Next state =
  let state' = state + 0x9e3779b97f4a7c15
      z0     = state'
      z1     = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
      z2     = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  in (z2 `xor` (z2 `shiftR` 31), state')

||| Two splitmix64 steps' full 64-bit outputs, `(s[0], s[1])` -- this
||| generator's state is 128 bits, so (unlike Xoroshiro64StarStar.
||| mixSeed, whose 64-bit state fits in a single splitmix64 step's
||| output) two steps are needed, one per word.
mixSeed : Bits64 -> (Bits64, Bits64)
mixSeed s = let (s0, s') = splitmix64Next s
                (s1, _)  = splitmix64Next s'
            in (s0, s1)

-- ----------------------------------------------------------------------------

||| A fresh per-instance generator, seeded (via two splitmix64 steps, to
||| avoid handing the algorithm a poorly-diffused or all-zero state) from
||| a caller-chosen `Bits64`. `Nothing` only on buffer allocation failure.
export
newIOGen : HasIO io => Bits64 -> io (Maybe IOGen)
newIOGen s = do
  Just buf <- newBuffer 16
    | Nothing => pure Nothing
  let (s0, s1) = mixSeed s
  setBits64 buf 0 s0
  setBits64 buf 8 s1
  pure $ Just $ MkIOGen buf

||| Clone a generator's current state into a fresh, independent
||| `IOGen` -- the copy produces the exact same output sequence as the
||| original from this point on, but mutating one (via `next`/`jump`*)
||| has no effect on the other, since each holds its own `Buffer`.
||| `Nothing` only on the new buffer's own allocation failure.
export
copyIOGen : HasIO io => IOGen -> io (Maybe IOGen)
copyIOGen (MkIOGen buf) = do
  Just buf' <- newBuffer 16
    | Nothing => pure Nothing
  copyData buf 0 16 buf' 0
  pure $ Just $ MkIOGen buf'

||| Draw the next 64-bit output from a generator, updating its state
||| (held in the underlying `Buffer`) in place.
export
next : HasIO io => IOGen -> io Bits64
next (MkIOGen buf) = primIO $ prim__next buf

||| The top 53 bits of an output as a `Double` in `[0,1)`. A `Double` has a
||| 53-bit significand, so the conversion is exact: `cast v / 2^64` rounds
||| an output within 2^10 of 2^64 up to 2^64, which would give exactly 1.0.
export
toUnit : Bits64 -> Double
toUnit v = cast (v `shiftR` 11) * 1.1102230246251565e-16   -- 2^-53

||| A step's output mapped to a uniform `Double` in `[0,1)`, using the top
||| 53 bits of the output (all a `Double` can hold).
export
nextDouble : HasIO io => IOGen -> io Double
nextDouble g = do
  v <- next g
  pure (toUnit v)

||| Equivalent to 2^64 calls to `next` -- advances a generator to the
||| start of one of 2^64 non-overlapping subsequences, useful for
||| handing out independent streams to parallel computations.
export
jump : HasIO io => IOGen -> io ()
jump (MkIOGen buf) = primIO $ prim__jump buf

||| Equivalent to 2^96 calls to `next` -- like `jump`, but for 2^32
||| starting points each 2^64 apart (so `jump` can still be used within
||| each to hand out 2^32 further non-overlapping subsequences).
export
longJump : HasIO io => IOGen -> io ()
longJump (MkIOGen buf) = primIO $ prim__longJump buf

||| Equivalent to `c * 2^e` calls to `next` -- e.g. `jumpCE g 1 64` is
||| `jump g`, `jumpCE g 1 96` is `longJump g`. Expressing the distance
||| this way avoids handling a multiple-precision integer for ordinary
||| jump counts (`jumpCE g k 0`) or power-of-two multiples. For the jump
||| to be meaningful, `c * 2^e` should stay under the generator's period
||| (2^128 - 1).
export
jumpCE : HasIO io => IOGen -> (c : Bits64) -> (e : Bits32) -> io ()
jumpCE (MkIOGen buf) c e = primIO $ prim__jumpCE buf c e

||| Equivalent to `n` calls to `next`, for an arbitrary distance
||| `n = n0 + n1 * 2^64` (should stay under the generator's period,
||| 2^128 - 1, for the jump to be meaningful) -- more general than
||| `jumpCE`, taking `n` as two `Bits64` words directly since this
||| generator's 128-bit state means any distance always fits in exactly
||| two of them (unlike the reference algorithm's own general
||| POLY_WORDS-word `jump[]` array, sized for generators with larger
||| state).
export
jumpN : HasIO io => IOGen -> (n0 : Bits64) -> (n1 : Bits64) -> io ()
jumpN (MkIOGen buf) n0 n1 = primIO $ prim__jumpN buf n0 n1

||| Convenience constructor: a fresh generator, seeded with 64 random bits
||| from the operating system (`/dev/urandom`, which two processes started
||| together do not share). Only when that cannot be read (no `/dev`, say) is the seed the monotonic clock mixed with the process id, which
||| processes started at about the same time can share. The generator is
||| not cryptographically secure, and 64 bits of seed give 2^64 of its
||| 2^128 states -- use `newIOGen` directly for a reproducible,
||| caller-chosen seed. `Nothing` only on buffer allocation failure.
export
newSeeded : HasIO io => io (Maybe IOGen)
newSeeded = do
  r <- entropy64
  seed <- case r of
    Just s => pure s
    Nothing => do
      clk <- liftIO (clockTime Monotonic)
      pid <- getPID
      pure (cast (toNano clk) `xor` cast pid)
  newIOGen seed

-- ----------------------------------------------------------------------------
-- A separate, single global generator held entirely in C-side static
-- state (`support/c/xoroshiro128plusplus.c`'s own `system_seed[2]`) --
-- not thread-safe (no locking around the shared mutable state, unlike
-- even the "caller must guard their own IORef/Buffer" contract the
-- per-instance API above leaves to callers), offered purely as a
-- quick, no-instance-to-carry-around convenience akin to C's own
-- rand()/srand(). Prefer `newIOGen`/`next` for anything concurrent or
-- reproducible.

||| Seed the single global generator (via two splitmix64 steps, same
||| mixing `newIOGen` applies -- the underlying C function just stores
||| whatever two 64-bit words it's given, so the mixing has to happen
||| here).
export
setSystemSeed : HasIO io => Bits64 -> io ()
setSystemSeed s = let (s0, s1) = mixSeed s in primIO $ prim__setSystemSeed s0 s1

||| Draw the next 64-bit output from the single global generator.
export
nextIO : HasIO io => io Bits64
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
jumpNIO : HasIO io => (n0 : Bits64) -> (n1 : Bits64) -> io ()
jumpNIO n0 n1 = primIO $ prim__jumpNSys n0 n1

-- ----------------------------------------------------------------------------
-- A pure generator: the two state words as a value, stepped by the same
-- C algorithm as `IOGen` (support/c/xoroshiro128plusplus.c, the
-- `pure_*` functions). Each returns one word, so the `%foreign`
-- declarations carry no PrimIO and no Buffer.

||| The 128 bits of xoroshiro128++ state, `(s[0], s[1])`, as a value:
||| every step returns the next one. Each word is held as two `Bits32`
||| halves (high, low): a `Bits64` above 2^62 does not fit rc2's
||| immediate representation and would be heap-allocated in the
||| constructor on every step, whereas the halves always do fit.
export
data Gen = MkGen Bits32 Bits32 Bits32 Bits32

%foreign "C:idris2rc2_System_Random128_pure_out,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureOut : Bits64 -> Bits64 -> Bits64

%foreign "C:idris2rc2_System_Random128_pure_s0,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureS0 : Bits64 -> Bits64 -> Bits64

%foreign "C:idris2rc2_System_Random128_pure_s1,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureS1 : Bits64 -> Bits64 -> Bits64

-- A jump gives two words and runs once: each of these returns the new s[0] and
-- leaves the new s[1] for `prim__pureJumpHi`, on the same thread. They are
-- PrimIO so that `jumpWith` can sequence the two in one IO action.
%foreign "C:idris2rc2_System_Random128_pure_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureJump : Bits64 -> Bits64 -> PrimIO Bits64

%foreign "C:idris2rc2_System_Random128_pure_long_jump,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureLongJump : Bits64 -> Bits64 -> PrimIO Bits64

%foreign "C:idris2rc2_System_Random128_pure_jump_ce,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureJumpCE : Bits64 -> Bits64 -> Bits64 -> Bits32 -> PrimIO Bits64

%foreign "C:idris2rc2_System_Random128_pure_jump_n,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureJumpN : Bits64 -> Bits64 -> Bits64 -> Bits64 -> PrimIO Bits64

%foreign "C:idris2rc2_System_Random128_pure_jump_hi,libidris2rc2base,idris2rc2_rc2base_xoroshiro128plusplus.h"
prim__pureJumpHi : PrimIO Bits64

fromWords : Bits64 -> Bits64 -> Gen
fromWords s0 s1 = MkGen (cast (s0 `shiftR` 32)) (cast s0) (cast (s1 `shiftR` 32)) (cast s1)

toWords : Gen -> (Bits64, Bits64)
toWords (MkGen a b c d) = (cast a `shiftL` 32 .|. cast b, cast c `shiftL` 32 .|. cast d)

||| The generator `newIOGen` would create from the same seed (the same
||| two splitmix64 steps), so both produce the same sequence.
export
mkGen : Bits64 -> Gen
mkGen s = let (s0, s1) = mixSeed s in fromWords s0 s1

||| The next 64-bit output and the generator after that step.
export
genNext : Gen -> (Bits64, Gen)
genNext g =
  let (s0, s1) = toWords g
  in (prim__pureOut s0 s1, fromWords (prim__pureS0 s0 s1) (prim__pureS1 s0 s1))

||| A step's output as a uniform `Double` in `[0,1)` (its top 53 bits),
||| as `nextDouble` does.
export
genNextDouble : Gen -> (Double, Gen)
genNextDouble g = let (v, g') = genNext g in (toUnit v, g')

-- The jump itself (128 steps, and the jump polynomial for `jumpCE`/`jumpN`)
-- runs once; the second word of the new state is read right after it, in the
-- same IO action, from the thread-local the C side left it in.
jumpWith : (Bits64 -> Bits64 -> PrimIO Bits64) -> Gen -> Gen
jumpWith f g = unsafePerformIO $ do
  let (s0, s1) = toWords g
  lo <- primIO (f s0 s1)
  hi <- primIO prim__pureJumpHi
  pure (fromWords lo hi)

||| `jump` on a value: 2^64 steps ahead.
export
genJump : Gen -> Gen
genJump = jumpWith prim__pureJump

||| `longJump` on a value: 2^96 steps ahead.
export
genLongJump : Gen -> Gen
genLongJump = jumpWith prim__pureLongJump

||| `jumpCE` on a value: `c * 2^e` steps ahead.
export
genJumpCE : Gen -> (c : Bits64) -> (e : Bits32) -> Gen
genJumpCE g c e = jumpWith (\s0, s1 => prim__pureJumpCE s0 s1 c e) g

||| `jumpN` on a value: `n0 + n1 * 2^64` steps ahead.
export
genJumpN : Gen -> (n0 : Bits64) -> (n1 : Bits64) -> Gen
genJumpN g n0 n1 = jumpWith (\s0, s1 => prim__pureJumpN s0 s1 n0 n1) g
