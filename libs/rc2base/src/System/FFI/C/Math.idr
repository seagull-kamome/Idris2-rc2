module System.FFI.C.Math

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Direct `%foreign` bindings onto C's `<math.h>`, all on `Double` (the
-- `...f`/`...l` variants are deliberately not bound). Each is a
-- one-expression `CExpr:` template linking `libm`, so no C shim is
-- involved (rc2/doc/ffi-cexpr.md).
--
-- Everything lives in `namespace Math` and is meant to be used qualified
-- (`Math.sin`): several names (`sqrt`, `log`, `exp`, `sin`,
-- `cos`, `tan`, `floor`, ...) are already exported by Prelude, and the
-- rest would still read ambiguously beside them -- the same convention
-- as `Data.Integer.GMP`'s own `GMP.*`.
--
-- The classification functions are C macros yielding `int`
-- (`isnan`, `isfinite`, `isinf`, `isnormal`, `signbit`); they are
-- wrapped as `Bool` here (`Math.isNaN`, `Math.isFinite`, ...).
-- `nan`/`inf` are already `Data.Double`'s own (patched for rc2 by
-- `Data.Double.RC2`), and `pi` comes from Prelude. `frexp`/`modf`/
-- `remquo` are left out because of their output parameters, as are
-- `nan`, `nexttoward` and `scalbln`.

namespace Math
  -----------------------------------------------------------------------------
  -- Absolute value, remainder and sign

  %foreign "CExpr:(fabs($1)),libm,math.h"
  export
  fabs : Double -> Double

  %foreign "CExpr:(fmod($1, $2)),libm,math.h"
  export
  fmod : Double -> Double -> Double

  %foreign "CExpr:(remainder($1, $2)),libm,math.h"
  export
  remainder : Double -> Double -> Double

  %foreign "CExpr:(fdim($1, $2)),libm,math.h"
  export
  fdim : Double -> Double -> Double

  %foreign "CExpr:(fmax($1, $2)),libm,math.h"
  export
  fmax : Double -> Double -> Double

  %foreign "CExpr:(fmin($1, $2)),libm,math.h"
  export
  fmin : Double -> Double -> Double

  %foreign "CExpr:(copysign($1, $2)),libm,math.h"
  export
  copysign : Double -> Double -> Double

  %foreign "CExpr:(nextafter($1, $2)),libm,math.h"
  export
  nextafter : Double -> Double -> Double

  %foreign "CExpr:(fma($1, $2, $3)),libm,math.h"
  export
  fma : Double -> Double -> Double -> Double

  -----------------------------------------------------------------------------
  -- Powers and roots

  %foreign "CExpr:(pow($1, $2)),libm,math.h"
  export
  pow : Double -> Double -> Double

  %foreign "CExpr:(sqrt($1)),libm,math.h"
  export
  sqrt : Double -> Double

  %foreign "CExpr:(cbrt($1)),libm,math.h"
  export
  cbrt : Double -> Double

  %foreign "CExpr:(hypot($1, $2)),libm,math.h"
  export
  hypot : Double -> Double -> Double

  -----------------------------------------------------------------------------
  -- Exponential and logarithmic

  %foreign "CExpr:(exp($1)),libm,math.h"
  export
  exp : Double -> Double

  %foreign "CExpr:(exp2($1)),libm,math.h"
  export
  exp2 : Double -> Double

  %foreign "CExpr:(expm1($1)),libm,math.h"
  export
  expm1 : Double -> Double

  %foreign "CExpr:(log($1)),libm,math.h"
  export
  log : Double -> Double

  %foreign "CExpr:(log2($1)),libm,math.h"
  export
  log2 : Double -> Double

  %foreign "CExpr:(log10($1)),libm,math.h"
  export
  log10 : Double -> Double

  %foreign "CExpr:(log1p($1)),libm,math.h"
  export
  log1p : Double -> Double

  -----------------------------------------------------------------------------
  -- Special functions

  %foreign "CExpr:(erf($1)),libm,math.h"
  export
  erf : Double -> Double

  %foreign "CExpr:(erfc($1)),libm,math.h"
  export
  erfc : Double -> Double

  %foreign "CExpr:(tgamma($1)),libm,math.h"
  export
  tgamma : Double -> Double

  -- Calls the reentrant lgamma_r (glibc and BSD): plain lgamma writes the
  -- global signgam, a data race between threads. The sign is discarded.
  %foreign "CExpr:({ int s_; lgamma_r($1, &s_); }),libm,math.h"
  export
  lgamma : Double -> Double

  -----------------------------------------------------------------------------
  -- Trigonometric and hyperbolic

  %foreign "CExpr:(sin($1)),libm,math.h"
  export
  sin : Double -> Double

  %foreign "CExpr:(cos($1)),libm,math.h"
  export
  cos : Double -> Double

  %foreign "CExpr:(tan($1)),libm,math.h"
  export
  tan : Double -> Double

  %foreign "CExpr:(asin($1)),libm,math.h"
  export
  asin : Double -> Double

  %foreign "CExpr:(acos($1)),libm,math.h"
  export
  acos : Double -> Double

  %foreign "CExpr:(atan($1)),libm,math.h"
  export
  atan : Double -> Double

  %foreign "CExpr:(atan2($1, $2)),libm,math.h"
  export
  atan2 : Double -> Double -> Double

  %foreign "CExpr:(sinh($1)),libm,math.h"
  export
  sinh : Double -> Double

  %foreign "CExpr:(cosh($1)),libm,math.h"
  export
  cosh : Double -> Double

  %foreign "CExpr:(tanh($1)),libm,math.h"
  export
  tanh : Double -> Double

  %foreign "CExpr:(asinh($1)),libm,math.h"
  export
  asinh : Double -> Double

  %foreign "CExpr:(acosh($1)),libm,math.h"
  export
  acosh : Double -> Double

  %foreign "CExpr:(atanh($1)),libm,math.h"
  export
  atanh : Double -> Double

  -----------------------------------------------------------------------------
  -- Rounding

  %foreign "CExpr:(ceil($1)),libm,math.h"
  export
  ceil : Double -> Double

  %foreign "CExpr:(floor($1)),libm,math.h"
  export
  floor : Double -> Double

  %foreign "CExpr:(trunc($1)),libm,math.h"
  export
  trunc : Double -> Double

  %foreign "CExpr:(round($1)),libm,math.h"
  export
  round : Double -> Double

  %foreign "CExpr:(nearbyint($1)),libm,math.h"
  export
  nearbyint : Double -> Double

  %foreign "CExpr:(rint($1)),libm,math.h"
  export
  rint : Double -> Double

  %foreign "CExpr:(lround($1)),libm,math.h"
  export
  lround : Double -> Int64

  %foreign "CExpr:(llround($1)),libm,math.h"
  export
  llround : Double -> Int64

  -----------------------------------------------------------------------------
  -- Decomposition

  %foreign "CExpr:(ldexp($1, $2)),libm,math.h"
  export
  ldexp : Double -> Int32 -> Double

  %foreign "CExpr:(scalbn($1, $2)),libm,math.h"
  export
  scalbn : Double -> Int32 -> Double

  -- FP_ILOGB0 and FP_ILOGBNAN (for 0 and NaN) are implementation-defined.
  %foreign "CExpr:(ilogb($1)),libm,math.h"
  export
  ilogb : Double -> Int32

  %foreign "CExpr:(logb($1)),libm,math.h"
  export
  logb : Double -> Double

  -----------------------------------------------------------------------------
  -- Classification

  %foreign "CExpr:(isnan($1)),libm,math.h"
  prim__isnan : Double -> Int32

  export
  isNaN : Double -> Bool
  isNaN x = prim__isnan x /= 0

  %foreign "CExpr:(isfinite($1)),libm,math.h"
  prim__isfinite : Double -> Int32

  export
  isFinite : Double -> Bool
  isFinite x = prim__isfinite x /= 0

  %foreign "CExpr:(isinf($1)),libm,math.h"
  prim__isinf : Double -> Int32

  export
  isInfinite : Double -> Bool
  isInfinite x = prim__isinf x /= 0

  %foreign "CExpr:(isnormal($1)),libm,math.h"
  prim__isnormal : Double -> Int32

  export
  isNormal : Double -> Bool
  isNormal x = prim__isnormal x /= 0

  %foreign "CExpr:(signbit($1)),libm,math.h"
  prim__signbit : Double -> Int32

  export
  signBit : Double -> Bool
  signBit x = prim__signbit x /= 0
