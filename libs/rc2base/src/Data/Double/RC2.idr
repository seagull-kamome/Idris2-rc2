module Data.Double.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Patches upstream `Data.Double`'s `unitRoundoff`/`epsilon`/`nan`/`inf`,
-- each of which carries only a `"scheme:..."`/`"node:..."` %foreign tag
-- and is therefore unusable on refc/rc2 (or any C backend) at all -- see
-- TODO.md's "Upstream stdlib `%foreign` declarations with no C/RefC
-- backend at all" entry. Unlike `Data.Buffer.RC2` (rc2's own runtime
-- already had every needed primitive under a different name),
-- rc2/support/rc2/numeric.h needed four small new `static inline`
-- functions -- `idris2rc2_unitRoundoff`/`idris2rc2_epsilon`/
-- `idris2rc2_nan`/`idris2rc2_inf` -- since there was nothing to reuse.
-- Their values are matched against idris2-src's own Chez definitions
-- (`support/chez/support.ss`), not just assumed: `unitRoundoff` is
-- `DBL_EPSILON/2` (the value `blodwen-calcFlonumUnitRoundoff`'s halving
-- loop provably converges to for IEEE 754 binary64, the classic round-
-- to-nearest-even boundary where `1.0 + uro == 1.0` first holds), and
-- `epsilon` is exactly double that (`DBL_EPSILON` itself) -- both
-- confirmed by this module's own test rather than left as a bare
-- assertion.
--
-- Each of these is declared upstream as a plain `Double` (not
-- `PrimIO Double`) -- an arity-0, non-monadic `%foreign` value, not a
-- shape any other rc2/rc2base %foreign_impl patch so far has used.
-- Confirmed working (a fresh call re-evaluated at every reference site,
-- same as any other arity-0 top-level definition on this backend --
-- harmless here since all four are pure, side-effect-free constants;
-- the same non-memoization would be a real bug for a stateful
-- generator) via a standalone scratch program before writing this
-- module for real, not assumed from reading the compiler alone.
--
-- Tagged `"RC2:"`, not `"RefC:"`, for the same reason as
-- `Data.Buffer.RC2`: these symbol names are new, rc2-only additions to
-- rc2's own runtime, not something a real `idris2 --cg refc` build's own
-- runtime also happens to provide -- an `"RC2:"`-tagged ccs entry is
-- silently ignored by any backend other than rc2 (`EmitUtil.idr`'s own
-- `ffiTags`), so it can never be mistaken for genuine upstream RefC
-- support the way a `"RefC:"` tag would risk.

import Data.Double

%foreign_impl Data.Double.unitRoundoff
  "RC2:idris2rc2_unitRoundoff"
%foreign_impl Data.Double.epsilon
  "RC2:idris2rc2_epsilon"
%foreign_impl Data.Double.nan
  "RC2:idris2rc2_nan"
%foreign_impl Data.Double.inf
  "RC2:idris2rc2_inf"
