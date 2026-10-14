module Data.Integer.GMP

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Direct `%foreign` bindings onto real GMP `mpz_*` functions, made
-- possible by `Compiler.RC2.Emit`'s own `Integer`-as-`%foreign`-
-- argument-and-return support: an Idris `Integer` is passed as a
-- read-only GMP `mpz_t` (a boxed one's own, or a view of an immediate --
-- rc2/doc/immediate-ints.md), so a `%foreign` declaration whose Idris signature is
-- `Integer -> ... -> Integer` compiles to a call with a freshly
-- allocated `mpz_t`. Each declaration is a `"CExpr:"` template
-- (rc2/doc/ffi-cexpr.md): `$r` stands for that fresh out-parameter,
-- placed where GMP wants its `rop` (`mpz_add($r, $1, $2)`), so these
-- bind straight onto GMP's real symbols with no wrapper of their own
-- (functions returning a plain value take no `$r`). `gmp.h`'s own `#define mpz_add __gmpz_add`-style renaming
-- macros (every public `mpz_*` name is actually one of these) expand
-- correctly at the generated call site because the header is always
-- `#include`d there -- true expression macros (`mpz_sgn`, `mpz_odd_p`)
-- work the same way, for the same reason: this module never needed to
-- distinguish "real function" from "macro" at all.
--
-- Everything below lives in `namespace GMP` (so e.g. `GMP.add`), not
-- exported unqualified: over a dozen of these names
-- (`abs`/`neg`/`mod`/`gcd`/`lcm`/`sqrt`/`and`/`xor`/...) would otherwise
-- collide with `Prelude`'s own -- same convention
-- `System.FFI.C.Ptr`'s own per-type namespaces already use for exactly
-- this reason.
--
-- ## Scope
--
-- Two groups, plus three in-place mutators (`setbit`/`clrbit`/`combit`,
-- below), all a mechanical translation of a real `mpz_*` name (`mpz_`
-- dropped, snake_case -> camelCase):
--
-- - **Arithmetic/bitwise** (this module's own `Integer`-return
--   convention): every `mpz_*` function whose real C signature is
--   `void mpz_foo(mpz_t rop, ...)` -- a single leading out-parameter,
--   nothing else.
-- - **Predicates/queries** (already-supported argument-only
--   marshalling, nothing new needed): every `mpz_*` function with a
--   plain native return (`int`/`mp_bitcnt_t`/`size_t`/`double`) and no
--   output parameter at all.
--
-- Deliberately excluded -- neither group's shape fits them, and
-- forcing them in would mean silently discarding real information, not
-- just following an established convention:
--
-- - `mpz_invert`/`mpz_root`: a leading `mpz_t` out-param *and* a
--   meaningful `int` return (invertibility/exactness) at once -- this
--   module's own convention only ever looks at one or the other.
-- - `mpz_tdiv_qr`/`mpz_fdiv_qr`/`mpz_cdiv_qr`/`mpz_gcdext`: more than
--   one output parameter.
-- - `mpz_urandomb`/`mpz_urandomm` and the rest of GMP's random-number
--   API: needs an opaque `gmp_randstate_t` with its own init/clear
--   lifecycle, a separate piece of design work.
-- - `mpz_get_str`/`mpz_set_str`: redundant with Idris's own `Integer`
--   `Show`/numeric-literal parsing, which already goes through this
--   same `mpz_t`.
--
-- (`mpz_setbit`/`mpz_clrbit`/`mpz_combit` mutate their single `mpz_t` in
-- place; they are bound as a comma expression that copies into `$r`
-- first, `(mpz_set($r, $1), mpz_setbit($r, $2))`, so the argument is
-- left alone.)
--
-- See `TODO.md`'s own entry for this module for the full list with
-- reasons, kept in sync if this scope ever grows.

namespace GMP
  %foreign "CExpr:(mpz_add($r, $1, $2)),libgmp,gmp.h"
  export
  add : Integer -> Integer -> Integer

  %foreign "CExpr:(mpz_sub($r, $1, $2)),libgmp,gmp.h"
  export
  sub : Integer -> Integer -> Integer

  %foreign "CExpr:(mpz_mul($r, $1, $2)),libgmp,gmp.h"
  export
  mul : Integer -> Integer -> Integer

  %foreign "CExpr:(mpz_neg($r, $1)),libgmp,gmp.h"
  export
  neg : Integer -> Integer

  %foreign "CExpr:(mpz_abs($r, $1)),libgmp,gmp.h"
  export
  abs : Integer -> Integer

  %foreign "CExpr:(mpz_add_ui($r, $1, $2)),libgmp,gmp.h"
  export
  addUi : Integer -> Bits64 -> Integer

  %foreign "CExpr:(mpz_sub_ui($r, $1, $2)),libgmp,gmp.h"
  export
  subUi : Integer -> Bits64 -> Integer

  %foreign "CExpr:(mpz_ui_sub($r, $1, $2)),libgmp,gmp.h"
  export
  uiSub : Bits64 -> Integer -> Integer

  %foreign "CExpr:(mpz_mul_si($r, $1, $2)),libgmp,gmp.h"
  export
  mulSi : Integer -> Int -> Integer

  %foreign "CExpr:(mpz_mul_ui($r, $1, $2)),libgmp,gmp.h"
  export
  mulUi : Integer -> Bits64 -> Integer

  %foreign "CExpr:(mpz_gcd($r, $1, $2)),libgmp,gmp.h"
  export
  gcd : Integer -> Integer -> Integer

  %foreign "CExpr:(mpz_lcm($r, $1, $2)),libgmp,gmp.h"
  export
  lcm : Integer -> Integer -> Integer

  ||| Truncating division (toward zero) -- quotient only. See `tdivR`
  ||| for the matching remainder.
  %foreign "CExpr:(mpz_tdiv_q($r, $1, $2)),libgmp,gmp.h"
  export
  tdivQ : Integer -> Integer -> Integer

  ||| Truncating division (toward zero) -- remainder only.
  %foreign "CExpr:(mpz_tdiv_r($r, $1, $2)),libgmp,gmp.h"
  export
  tdivR : Integer -> Integer -> Integer

  ||| Flooring division -- quotient only.
  %foreign "CExpr:(mpz_fdiv_q($r, $1, $2)),libgmp,gmp.h"
  export
  fdivQ : Integer -> Integer -> Integer

  ||| Flooring division -- remainder only (same sign as the divisor).
  %foreign "CExpr:(mpz_fdiv_r($r, $1, $2)),libgmp,gmp.h"
  export
  fdivR : Integer -> Integer -> Integer

  ||| Ceiling division -- quotient only.
  %foreign "CExpr:(mpz_cdiv_q($r, $1, $2)),libgmp,gmp.h"
  export
  cdivQ : Integer -> Integer -> Integer

  ||| Ceiling division -- remainder only.
  %foreign "CExpr:(mpz_cdiv_r($r, $1, $2)),libgmp,gmp.h"
  export
  cdivR : Integer -> Integer -> Integer

  ||| Euclidean modulo -- always non-negative, regardless of either
  ||| operand's own sign (unlike `tdivR`/`fdivR`/`cdivR`).
  %foreign "CExpr:(mpz_mod($r, $1, $2)),libgmp,gmp.h"
  export
  mod : Integer -> Integer -> Integer

  ||| Division known in advance to be exact (the divisor evenly divides
  ||| the dividend) -- faster than `tdivQ`, undefined if it doesn't
  ||| actually divide evenly.
  %foreign "CExpr:(mpz_divexact($r, $1, $2)),libgmp,gmp.h"
  export
  divexact : Integer -> Integer -> Integer

  %foreign "CExpr:(mpz_pow_ui($r, $1, $2)),libgmp,gmp.h"
  export
  powUi : Integer -> Bits64 -> Integer

  ||| Both base and exponent are native words here (unlike `powUi`,
  ||| whose base is a full `Integer`) -- for a plain small-integer power
  ||| with no `Integer` operand to marshal at all.
  %foreign "CExpr:(mpz_ui_pow_ui($r, $1, $2)),libgmp,gmp.h"
  export
  uiPowUi : Bits64 -> Bits64 -> Integer

  ||| Modular exponentiation (`base ^ exp mod m`) -- GMP computes this
  ||| directly, far faster than `powUi` followed by `mod` for anything
  ||| but the smallest inputs. The workhorse of RSA-style cryptography.
  %foreign "CExpr:(mpz_powm($r, $1, $2, $3)),libgmp,gmp.h"
  export
  powm : Integer -> Integer -> Integer -> Integer

  ||| As `powm`, but the exponent is a native word.
  %foreign "CExpr:(mpz_powm_ui($r, $1, $2, $3)),libgmp,gmp.h"
  export
  powmUi : Integer -> Bits64 -> Integer -> Integer

  ||| Integer (floor) square root.
  %foreign "CExpr:(mpz_sqrt($r, $1)),libgmp,gmp.h"
  export
  sqrt : Integer -> Integer

  ||| Left shift (multiply by `2^n`).
  %foreign "CExpr:(mpz_mul_2exp($r, $1, $2)),libgmp,gmp.h"
  export
  mul2exp : Integer -> Bits64 -> Integer

  ||| Right shift, truncating (divide by `2^n`, toward zero) -- quotient
  ||| only.
  %foreign "CExpr:(mpz_tdiv_q_2exp($r, $1, $2)),libgmp,gmp.h"
  export
  tdivQ2exp : Integer -> Bits64 -> Integer

  ||| The low `n` bits only (truncating right-shift's own remainder).
  %foreign "CExpr:(mpz_tdiv_r_2exp($r, $1, $2)),libgmp,gmp.h"
  export
  tdivR2exp : Integer -> Bits64 -> Integer

  ||| Right shift, flooring (arithmetic shift right) -- quotient only.
  %foreign "CExpr:(mpz_fdiv_q_2exp($r, $1, $2)),libgmp,gmp.h"
  export
  fdivQ2exp : Integer -> Bits64 -> Integer

  ||| Flooring right-shift's own remainder.
  %foreign "CExpr:(mpz_fdiv_r_2exp($r, $1, $2)),libgmp,gmp.h"
  export
  fdivR2exp : Integer -> Bits64 -> Integer

  ||| Bitwise AND, two's-complement semantics (as if both operands were
  ||| sign-extended infinitely to the left).
  %foreign "CExpr:(mpz_and($r, $1, $2)),libgmp,gmp.h"
  export
  and : Integer -> Integer -> Integer

  ||| Bitwise inclusive-OR, two's-complement semantics. Named `ior`
  ||| (not `or`), matching GMP's own name exactly -- `or` would collide
  ||| with `Prelude`'s own `Bool` operator regardless, same reasoning as
  ||| this whole module living under `namespace GMP`.
  %foreign "CExpr:(mpz_ior($r, $1, $2)),libgmp,gmp.h"
  export
  ior : Integer -> Integer -> Integer

  ||| Bitwise exclusive-OR, two's-complement semantics.
  %foreign "CExpr:(mpz_xor($r, $1, $2)),libgmp,gmp.h"
  export
  xor : Integer -> Integer -> Integer

  ||| Bitwise complement (`~op`, two's-complement semantics --
  ||| equivalent to `neg (add op 1)`, GMP computes it directly).
  %foreign "CExpr:(mpz_com($r, $1)),libgmp,gmp.h"
  export
  com : Integer -> Integer

  ||| The next probable prime strictly greater than the argument (a
  ||| probabilistic test, same guarantees as `probabPrimeP`).
  %foreign "CExpr:(mpz_nextprime($r, $1)),libgmp,gmp.h"
  export
  nextprime : Integer -> Integer

  ------------------------------------------------------------------
  -- Predicates/queries: plain native return, no output parameter --
  -- already-supported argument-only Integer marshalling is all these
  -- ever needed.

  ||| Negative/zero/positive as `-1`/`0`/`1` (GMP's own sign function
  ||| returns exactly that trichotomy, not an arbitrary sign-carrying
  ||| magnitude).
  %foreign "CExpr:(mpz_cmp($1, $2)),libgmp,gmp.h"
  export
  cmp : Integer -> Integer -> Int

  ||| As `cmp`, but comparing absolute values.
  %foreign "CExpr:(mpz_cmpabs($1, $2)),libgmp,gmp.h"
  export
  cmpabs : Integer -> Integer -> Int

  ||| `0` (definitely composite), `1` (probably prime), or `2`
  ||| (definitely prime) -- the second argument is the number of
  ||| Miller-Rabin rounds to run (GMP's own documentation suggests
  ||| 15-50 for cryptographic use; higher costs more time for a lower
  ||| false-positive chance).
  %foreign "CExpr:(mpz_probab_prime_p($1, $2)),libgmp,gmp.h"
  export
  probabPrimeP : Integer -> Int -> Int

  ||| Nonzero iff the argument is a perfect square.
  %foreign "CExpr:(mpz_perfect_square_p($1)),libgmp,gmp.h"
  export
  perfectSquareP : Integer -> Int

  ||| Nonzero iff the argument is a perfect power (`a^b` for some
  ||| integers `a` and `b > 1`) -- `1`, `0`, and `-1` all count.
  %foreign "CExpr:(mpz_perfect_power_p($1)),libgmp,gmp.h"
  export
  perfectPowerP : Integer -> Int

  ||| Number of `1` bits (two's-complement semantics: infinite for a
  ||| negative operand, per GMP's own documented convention -- only
  ||| meaningful for a non-negative argument in practice).
  %foreign "CExpr:(mpz_popcount($1)),libgmp,gmp.h"
  export
  popcount : Integer -> Bits64

  ||| Hamming distance (count of differing bits), two's-complement
  ||| semantics.
  %foreign "CExpr:(mpz_hamdist($1, $2)),libgmp,gmp.h"
  export
  hamdist : Integer -> Integer -> Bits64

  ||| `x` with bit index `n` (0-based, from the least-significant bit) set,
  ||| two's-complement semantics; `x` is unchanged.
  %foreign "CExpr:(mpz_set($r, $1), mpz_setbit($r, $2)),libgmp,gmp.h"
  export
  setbit : Integer -> Bits64 -> Integer

  ||| `x` with bit index `n` (0-based) cleared, two's-complement semantics;
  ||| `x` is unchanged.
  %foreign "CExpr:(mpz_set($r, $1), mpz_clrbit($r, $2)),libgmp,gmp.h"
  export
  clrbit : Integer -> Bits64 -> Integer

  ||| `x` with bit index `n` (0-based) flipped, two's-complement semantics;
  ||| `x` is unchanged.
  %foreign "CExpr:(mpz_set($r, $1), mpz_combit($r, $2)),libgmp,gmp.h"
  export
  combit : Integer -> Bits64 -> Integer

  ||| `1` if bit `n` is set, `0` otherwise.
  %foreign "CExpr:(mpz_tstbit($1, $2)),libgmp,gmp.h"
  export
  tstbit : Integer -> Bits64 -> Int

  ||| Number of digits the argument would need in the given base
  ||| (2-62) -- an upper bound, occasionally one more than the tightest
  ||| possible (GMP's own documented caveat), never fewer.
  %foreign "CExpr:(mpz_sizeinbase($1, $2)),libgmp,gmp.h"
  export
  sizeinbase : Integer -> Int -> Bits64

  ||| Nonzero iff the value fits in a native signed `Int` (`long`) with
  ||| no truncation.
  %foreign "CExpr:(mpz_fits_slong_p($1)),libgmp,gmp.h"
  export
  fitsSlongP : Integer -> Int

  ||| As `fitsSlongP`, for an unsigned `Bits64` (`unsigned long`).
  %foreign "CExpr:(mpz_fits_ulong_p($1)),libgmp,gmp.h"
  export
  fitsUlongP : Integer -> Int

  ||| Truncated (not rounded) conversion to `Double`, GMP's own
  ||| documented behaviour for a magnitude past `Double`'s own range.
  %foreign "CExpr:(mpz_get_d($1)),libgmp,gmp.h"
  export
  getD : Integer -> Double

  ||| Index (0-based, from the least-significant bit) of the first `0`
  ||| bit at or after position `n`, two's-complement semantics.
  %foreign "CExpr:(mpz_scan0($1, $2)),libgmp,gmp.h"
  export
  scan0 : Integer -> Bits64 -> Bits64

  ||| As `scan0`, for the first `1` bit.
  %foreign "CExpr:(mpz_scan1($1, $2)),libgmp,gmp.h"
  export
  scan1 : Integer -> Bits64 -> Bits64
