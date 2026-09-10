module Main

-- Merged regression suite for idris2rc2_applyClosure's fast path
-- (runtime.c's idris2rc2_dispatchWithExtra). Two formerly separate
-- tests, each hitting the "shared closure receiving its final
-- argument" shape from a different source; each section keeps its own
-- original doc comment. `main` runs both; the saved .expected is their
-- concatenation.
--
--   * hand-written function  (was Test66ClosureFastPathMap)
--   * interface-dictionary method (was Test67ClosureFastPathDictDispatch)
--
-- The tail-position / stack-safety constraint of the same fast path is
-- covered separately by Test68ClosureFastPathStackSafety (kept its own
-- test: a 10M-iteration run whose valgrind cost would be prohibitive
-- here).

-- ============================================================
-- Section 1: hand-written function (was Test66ClosureFastPathMap)
-- ============================================================
-- `addN n` is a partial application (arity 2, filled 1) that `map`
-- reuses across every element of `xs`, so it is non-unique (refcount
-- >= 2, since `map`'s own loop keeps its own reference alive for later
-- elements) at every application except the last -- exactly the
-- "shared closure receiving its final argument" shape the fast path
-- targets. Confirmed by instrumenting idris2rc2_dispatchWithExtra
-- during development: it fired exactly 2000 times, once per list
-- element (see session report).

addN : Int -> Int -> Int
addN n x = n + x

sumList : List Int -> Int
sumList [] = 0
sumList (x :: xs) = x + sumList xs

mkListI : Int -> List Int
mkListI 0 = []
mkListI n = n :: mkListI (n - 1)

sumWith : Int -> List Int -> Int
sumWith n xs = sumList (map (addN n) xs)

-- ============================================================
-- Section 2: interface dictionary method
--            (was Test67ClosureFastPathDictDispatch)
-- ============================================================
-- `(k +)` is `Num`'s own `(+)` method extracted from a runtime
-- dictionary and partially applied to the captured constant `k` (arity
-- 2, filled 1), then reused by `map` across every element of `xs` --
-- the "shared dictionary method reused across every element of a fold"
-- pattern from the original investigation, now sourced from a genuine
-- interface dictionary rather than a hand-written function. Confirmed
-- by instrumenting idris2rc2_dispatchWithExtra during development: it
-- fired exactly 2000 times, once per list element (see session
-- report). `sumGenericList` afterward is a second, independent
-- interface-dispatched (Num) traversal for good measure, though its
-- own `(+)` applications are always freshly built (arity 2, filled 0
-- each call) and so don't themselves reach the fast path.

sumGenericList : Num a => List a -> a
sumGenericList [] = 0
sumGenericList (x :: xs) = x + sumGenericList xs

mapAddConst : Num a => a -> List a -> List a
mapAddConst k xs = map (k +) xs

mkListD : Int -> List Double
mkListD 0 = []
mkListD n = cast n :: mkListD (n - 1)

main : IO ()
main = do
  printLn (sumWith 5 (mkListI 2000))
  printLn (sumGenericList (mapAddConst 1.5 (mkListD 2000)))
