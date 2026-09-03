module Main

-- Interface-dispatched variant of Test66ClosureFastPathMap: `(k +)` is
-- `Num`'s own `(+)` method extracted from a runtime dictionary and
-- partially applied to the captured constant `k` (arity 2, filled 1),
-- then reused by `map` across every element of `xs` -- the "shared
-- dictionary method reused across every element of a fold" pattern
-- from the original investigation, now sourced from a genuine
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

mkList : Int -> List Double
mkList 0 = []
mkList n = cast n :: mkList (n - 1)

main : IO ()
main = printLn (sumGenericList (mapAddConst 1.5 (mkList 2000)))
