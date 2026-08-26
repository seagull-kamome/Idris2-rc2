module Main

-- Regression test for MaxExtractFunArgs raised from 8 to 20 (TODO.md):
-- unlike Test33WideDualABIWorker.idr (a saturated, direct-call-shaped
-- test), this one forces genuine under-application so the value is
-- actually stored as a runtime Closure and later completed through
-- idris2rc2_dispatchClosure -- exercising the runtime's own new
-- IDRIS2RC2_FUN9..FUN20 typedefs and switch cases, not just the
-- compiler's positional-parameter C declaration for a saturated call.
add20 : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
      -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
add20 a b c d e f g h i j k l m n o p q r s t =
  a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r+s+t

main : IO ()
main = do
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
