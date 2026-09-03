module Main

-- Exercises idris2rc2_applyClosure's new fast path (runtime.c's
-- idris2rc2_dispatchWithExtra): `addN n` is a partial application
-- (arity 2, filled 1) that `map` reuses across every element of `xs`,
-- so it is non-unique (refcount >= 2, since `map`'s own loop keeps its
-- own reference alive for later elements) at every application except
-- the last -- exactly the "shared closure receiving its final
-- argument" shape the fast path targets. Confirmed by instrumenting
-- idris2rc2_dispatchWithExtra during development: it fired exactly
-- 2000 times, once per list element (see session report).

addN : Int -> Int -> Int
addN n x = n + x

sumList : List Int -> Int
sumList [] = 0
sumList (x :: xs) = x + sumList xs

mkList : Int -> List Int
mkList 0 = []
mkList n = n :: mkList (n - 1)

sumWith : Int -> List Int -> Int
sumWith n xs = sumList (map (addN n) xs)

main : IO ()
main = printLn (sumWith 5 (mkList 2000))
