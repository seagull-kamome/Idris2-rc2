module Test118FFI.FFICExpr

import Data.Bits
import Data.Fin
import Data.List
import Data.String

-- `%foreign "CExpr:..."`: a C expression instead of a function name
-- (rc2/doc/ffi-cexpr.md). Every declaration also carries a `C:` twin
-- (Test128FFICExpr.c/.h) so real RefC, which ignores `CExpr:`, prints
-- the same lines; rc2 must pick the `CExpr:` one, which check.sh
-- verifies from the generated C.

-- Constants from real system headers, no arguments.
%foreign "CExpr:O_CREAT,libc,fcntl.h"
         "C:idris2rc2_test128_ocreat,libc,Test128FFICExpr.h"
prim__ocreat : Int32

%foreign "CExpr:EINVAL,libc,errno.h"
         "C:idris2rc2_test128_einval,libc,Test128FFICExpr.h"
prim__einval : PrimIO Int32

%foreign "CExpr:INT_MAX,libc,limits.h"
         "C:idris2rc2_test128_intmax,libc,Test128FFICExpr.h"
prim__intmax : Int32

-- A pure two-argument expression, an unused argument, a repeated
-- placeholder and a ternary (its ':' must survive the tag split).
%foreign "CExpr:$1 * $2"
         "C:idris2rc2_test128_mul,libc,Test128FFICExpr.h"
prim__mul : Int -> Int -> Int

%foreign "CExpr:$2"
         "C:idris2rc2_test128_second,libc,Test128FFICExpr.h"
prim__second : Int -> Int -> Int

%foreign "CExpr:(($1) > ($2) ? ($1) : ($2))"
         "C:idris2rc2_test128_max2,libc,Test128FFICExpr.h"
prim__max2 : Int -> Int -> Int

-- Nested parentheses and commas, through a macro of the companion header.
%foreign "CExpr:IDRIS2RC2_TEST128_MAX(IDRIS2RC2_TEST128_MAX($1, $2), $3),libc,Test128FFICExpr.h"
         "C:idris2rc2_test128_max3,libc,Test128FFICExpr.h"
prim__max3 : Int -> Int -> Int -> Int

-- libc functions: narrowing Int32 argument, String argument, IO without
-- arguments, IO () statement.
%foreign "CExpr:abs($1),libc,stdlib.h"
         "C:abs,libc,stdlib.h"
prim__abs : Int32 -> Int32

%foreign "CExpr:strlen($1),libc,string.h"
         "C:strlen,libc,string.h"
prim__strlen : String -> Int

%foreign "CExpr:getpid(),libc,unistd.h"
         "C:getpid,libc,unistd.h"
prim__getpid : PrimIO Int32

%foreign "CExpr:srand($1),libc,stdlib.h"
         "C:srand,libc,stdlib.h"
prim__srand : Bits32 -> PrimIO ()

%foreign "CExpr:rand(),libc,stdlib.h"
         "C:rand,libc,stdlib.h"
prim__rand : PrimIO Int32

-- A string literal holding a comma and parentheses, a character
-- literal, and `$$`.
%foreign "CExpr:strlen(\"x,(y)\") + ($1)"
         "C:idris2rc2_test128_litlen,libc,Test128FFICExpr.h"
prim__litlen : Int -> Int

%foreign "CExpr:(($1) == ',' || ($1) == ')')"
         "C:idris2rc2_test128_isseparator,libc,Test128FFICExpr.h"
prim__isSeparator : Char -> Int

%foreign "CExpr:sizeof(\"$$\")"
         "C:idris2rc2_test128_dollar,libc,Test128FFICExpr.h"
prim__dollar : Int

-- A narrow unsigned argument and a Double.
%foreign "CExpr:($1) + 1"
         "C:idris2rc2_test128_u8plus,libc,Test128FFICExpr.h"
prim__u8plus : Bits8 -> Int

%foreign "CExpr:($1) * 2.0"
         "C:idris2rc2_test128_twice,libc,Test128FFICExpr.h"
prim__twice : Double -> Double

-- Pointers: a pointer return, a pointer argument.
%foreign "CExpr:getenv($1),libc,stdlib.h"
         "C:getenv,libc,stdlib.h"
prim__getenv : String -> PrimIO AnyPtr

%foreign "CExpr:strlen($1),libc,string.h"
         "C:strlen,libc,string.h"
prim__ptrStrlen : AnyPtr -> Int

-- Multi-digit placeholder.
%foreign "CExpr:$1 + $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 + $10 * $10"
         "C:idris2rc2_test128_sum10,libc,Test128FFICExpr.h"
prim__sum10 : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int

-- A repeated placeholder reads its argument expression twice.
%foreign "CExpr:strlen($1) + strlen($1)"
         "C:idris2rc2_test128_twicelen,libc,Test128FFICExpr.h"
prim__twiceLen : String -> Int

-- Integer results (`$r`, the mpz_t out-parameter of the result) and
-- arguments, bound straight to GMP functions. The `C:` twins take the
-- out-parameter as a leading argument, as every `C:` Integer result does.
%foreign "CExpr:mpz_add($r, $1, $2),libgmp,gmp.h"
         "C:idris2rc2_test128_gmpadd,libc,Test128FFICExpr.h"
prim__gmpAdd : Integer -> Integer -> Integer

%foreign "CExpr:mpz_mul($r, $1, $2),libgmp,gmp.h"
         "C:idris2rc2_test128_gmpmul,libc,Test128FFICExpr.h"
prim__gmpMul : Integer -> Integer -> Integer

%foreign "CExpr:mpz_sub($r, $1, $2),libgmp,gmp.h"
         "C:idris2rc2_test128_gmpsub,libc,Test128FFICExpr.h"
prim__gmpSub : Integer -> Integer -> Integer

%foreign "CExpr:mpz_set_si($r, (long)($1)),libgmp,gmp.h"
         "C:idris2rc2_test128_gmpfromint,libc,Test128FFICExpr.h"
prim__gmpFromInt : Int -> Integer

%foreign "CExpr:mpz_pow_ui($r, $1, (unsigned long)($2)),libgmp,gmp.h"
         "C:idris2rc2_test128_gmppow,libc,Test128FFICExpr.h"
prim__gmpPow : Integer -> Int -> Integer

%foreign "CExpr:mpz_set_ui($r, 42),libgmp,gmp.h"
         "C:idris2rc2_test128_gmp42,libc,Test128FFICExpr.h"
prim__gmp42 : PrimIO Integer

%foreign "CExpr:mpz_add($r, $1, $2),libgmp,gmp.h"
         "C:idris2rc2_test128_gmpadd,libc,Test128FFICExpr.h"
prim__gmpAddIO : Integer -> Integer -> PrimIO Integer

-- A repeated $r, one of them not the first argument.
%foreign "CExpr:(mpz_set_si($r, 3), mpz_mul($r, $1, $r), mpz_add_ui($r, $r, 1)),libgmp,gmp.h"
         "C:idris2rc2_test128_gmp3x1,libc,Test128FFICExpr.h"
prim__gmp3x1 : Integer -> Integer

-- A value-returning GMP function: Int result, Integer argument.
%foreign "CExpr:mpz_sgn($1),libgmp,gmp.h"
         "C:idris2rc2_test128_gmpsgn,libc,Test128FFICExpr.h"
prim__gmpSgn : Integer -> Int

-- Passing declarations as values goes through the generic wrapper.
apply2 : (Int -> Int -> Int) -> Int
apply2 f = f 6 7

apply2g : (Integer -> Integer -> Integer) -> Integer -> Integer
apply2g f x = f x 7

bigValue : Integer
bigValue = 123456789012345678901234567890

export
run : IO ()
run = do
  printLn (cast {to = Int} prim__ocreat > 0)
  einval <- primIO prim__einval
  printLn (einval > 0)
  printLn (prim__intmax == 2147483647)

  printLn (prim__mul 6 7)
  printLn (prim__second 1 2)
  printLn (prim__max2 3 9, prim__max2 9 3)
  printLn (prim__max3 3 9 5)
  printLn (map (apply2) [prim__mul, prim__second, prim__max2])

  printLn (prim__abs (-5), prim__abs 7)
  printLn (prim__strlen "hello, world")
  pid <- primIO prim__getpid
  printLn (pid > 0)
  primIO (prim__srand 42)
  r1 <- primIO prim__rand
  primIO (prim__srand 42)
  r2 <- primIO prim__rand
  printLn (r1 == r2)

  printLn (prim__litlen 10)
  printLn (prim__isSeparator ',', prim__isSeparator 'a')
  printLn prim__dollar
  printLn (prim__u8plus 255)
  printLn (cast {to = Int} (prim__twice 1.25 * 100.0))

  unset <- primIO (prim__getenv "RC2_TEST128_SURELY_UNSET")
  printLn (prim__nullAnyPtr unset)
  set <- primIO (prim__getenv "PATH")
  printLn (prim__nullAnyPtr set)
  printLn (prim__ptrStrlen set > 0)

  -- Arguments computed at run time, one of them a call to another
  -- `CExpr:` declaration and the other a fresh String, each read twice.
  n <- map (cast {to = Int} . length) (pure (replicate 4 'x'))
  printLn (prim__max2 (prim__mul n 3) (prim__second n 5))
  printLn (prim__twiceLen ("ab" ++ show n))

  printLn (prim__sum10 1 2 3 4 5 6 7 8 9 10)

  -- Integer results through `$r`: immediates, heap Integers, negatives,
  -- and results that fall back into the immediate range.
  let big = bigValue
  let edge = 4611686018427387904 -- 2^62, the first heap Integer
  printLn (prim__gmpAdd 20 22, prim__gmpAdd (-5) 3)
  printLn (prim__gmpMul 6 7, prim__gmpSub 3 10)
  printLn (prim__gmpAdd big big == big * 2, prim__gmpAdd big big)
  printLn (prim__gmpMul big (negate big) == negate (big * big))
  printLn (prim__gmpSub big big == 0, prim__gmpSub big (big + 1))
  printLn (prim__gmpAdd edge edge, prim__gmpSub (prim__gmpAdd edge edge) edge == edge)
  printLn (prim__gmpAdd (negate edge) (negate edge) - 1)
  printLn (prim__gmpFromInt 5, prim__gmpFromInt (-9223372036854775807))
  printLn (prim__gmpPow 2 100, prim__gmpPow big 0, prim__gmpPow (-3) 3)
  printLn (prim__gmpPow big 3 == big * big * big)
  s <- primIO prim__gmp42
  printLn s
  t <- primIO (prim__gmpAddIO big s)
  printLn (t == big + 42)
  printLn (prim__gmp3x1 big == 3 * big + 1, prim__gmp3x1 (-4))
  printLn (prim__gmpSgn big, prim__gmpSgn (negate big), prim__gmpSgn 0, prim__gmpSgn (-7))

  -- Integer declarations used as values (generic wrapper), also run
  -- on heap Integers.
  printLn (apply2g prim__gmpAdd big == big + 7)
  printLn (map (\f => apply2g f 10) [prim__gmpAdd, prim__gmpMul, prim__gmpSub])
  printLn (map (\f => apply2g f big == apply2g f big) [prim__gmpMul])
  let go : Integer -> Nat -> Integer
      go acc Z = acc
      go acc (S k) = go (prim__gmpMul (prim__gmpAdd acc 1) 3) k
  printLn (go 0 40)
