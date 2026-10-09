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

-- Passing declarations as values goes through the generic wrapper.
apply2 : (Int -> Int -> Int) -> Int
apply2 f = f 6 7

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
