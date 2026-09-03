module Main

-- Regression test for Compiler.RC2.DualABI's own dual-ABI worker
-- synthesis with MORE than Compiler.RC2.Emit.MaxExtractFunArgs (8)
-- top-level parameters. Mirrors a real bug report: an externally-
-- sourced package had a lambda-lifted internal helper with 9+
-- free-variable parameters, at least one genuinely native-eligible --
-- this used to be excluded from dual-ABI eligibility entirely (see
-- TODO.md/this test's own history). `wideAdd` below has 10 parameters:
-- nine `Int`s (all used only via `+`, so all native-eligible) and one
-- `String` (used only via `length`, so stays Boxed) -- the exact
-- "mostly-native, one non-eligible, width > 8" shape the old
-- exclusion used to rule out unconditionally.
--
-- Also covers MaxExtractFunArgs raised from 8 to 20 (formerly a
-- separate Test34WideClosureDispatch.idr, merged in below as
-- `add20`): unlike `wideAdd` above (a saturated, direct-call-shaped
-- test), this forces genuine under-application so the value is
-- actually stored as a runtime Closure and later completed through
-- idris2rc2_dispatchClosure -- exercising the runtime's own new
-- IDRIS2RC2_FUN9..FUN20 typedefs and switch cases, not just the
-- compiler's positional-parameter C declaration for a saturated call.
--
-- And Compiler.RC2.DualABI's Stage 3c (FFI worker synthesis,
-- `ffiWorkerTable`) with MORE than the old
-- `Compiler.RC2.EmitUtil.MaxExtractFunArgs` (20) parameters on a
-- `%foreign` declaration itself (formerly a separate
-- Test48WideFFIDualABIWorker.idr, merged in below as `prim__wide` --
-- see TODO.md's "Scope: FFI worker synthesis (Stage 3c) keeps its own
-- 20-argument limit" (now resolved) and `rc2/doc/dual-abi.md`'s
-- "Stage 3c" for the full history): `prim__wide` takes 15 parameters
-- (12 `Int`s, all native-eligible, + 3 `String`s, which stay `Boxed`),
-- past the old width limit that used to make `ffiEntry` return `[]`
-- unconditionally for any `%foreign` def this wide, regardless of how
-- many of its positions were genuinely native-eligible. Called
-- directly (fully saturated, non-tail position) from `main` so Stage
-- 4's call-site rewriting fires and the synthesized native worker is
-- actually reached, not just the always-Boxed wrapper.
wideAdd : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> String -> Int
wideAdd a b c d e f g h i tag =
  a + b + c + d + e + f + g + h + i + cast (length tag)

add20 : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
      -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
add20 a b c d e f g h i j k l m n o p q r s t =
  a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r+s+t

%foreign "C:idris2rc2_test48_wide,libc,Test33WideDualABIWorker.h"
prim__wide : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
             String -> String -> String -> Int

main : IO ()
main = do
  let r = wideAdd 1 2 3 4 5 6 7 8 9 "hello"
  putStrLn ("wideAdd result: " ++ show r)
  -- absorbed from former Test34WideClosureDispatch
  -- unique chain: each intermediate partial application is used once
  -- then dead; arity only reaches the full 20 on the final application,
  -- landing on idris2rc2_dispatchClosure's new case 20.
  let f = add20 1 2 3 4 5 6 7 8 9 10
      g = f 11 12 13 14 15
  printLn (g 16 17 18 19 20)

  -- shared closure (non-unique, forces copy+dup) applied to completion
  -- from two different call sites.
  let shared = add20 1 2 3 4 5 6 7 8 9 10 11 12
  printLn (shared 13 14 15 16 17 18 19 20)
  printLn (shared 100 14 15 16 17 18 19 20)
  -- absorbed from former Test48WideFFIDualABIWorker
  let r2 = prim__wide 1 2 3 4 5 6 7 8 9 10 11 12 "hello" "world" "!"
  putStrLn ("wide result: " ++ show r2)
