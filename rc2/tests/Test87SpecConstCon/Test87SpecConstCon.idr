module Main

-- Constant-constructor argument specialization
-- (`Compiler.RC2.SpecClosure.applySpecConstCon`, see
-- `doc/constant-constructor-specialization.md`): a callee whose
-- parameter is a dictionary *record* it only ever destructures,
-- called with a dictionary `Compiler.RC2.ConstFold` has already folded
-- to a single `RCConstCon`, gets a clone with that constant
-- substituted. The substitution folds the `case` away and leaves each
-- method field as an `RCConstClosure`, which ConstFold's own `RApp`
-- case then turns into a direct call instead of a boxed
-- `idris2rc2_applyClosure` dispatch.
--
-- `%noinline` on the dispatch targets and on `classify` keeps
-- `Compiler.RC2.Inline`/`LateInline` from removing the very call shape
-- this exists to exercise -- without it the whole program folds to its
-- answers at compile time and tests nothing.
--
-- Two distinct constants reach the same `(callee, argPos)` here, so
-- this also covers the multi-clone path: `plain` and `flipped` each
-- get their own clone of `classify`, and the generic original is left
-- with no callers for `Compiler.RC2.DeadCode` to prune.
--
-- `countMatches` covers the other half of the gate: a dictionary that
-- is *also* threaded onward, to the same argument position of its own
-- self-recursive call. Nothing special happens to build that clone --
-- the seeded fold substitutes the constant into the recursive call
-- too, and the whole-program redirect sweep then points that call at
-- the clone itself, because the sweep runs over the clones as well as
-- the originals. Without the self-passthrough allowance in
-- `paramIsScrutineeOnly` this shape is rejected outright, which is the
-- common case for a real dictionary (a recursive `go` carries it
-- along every step).

record Cmp a where
  constructor MkCmp
  eq : a -> a -> Bool
  lt : a -> a -> Bool

%noinline
eqInt : Int -> Int -> Bool
eqInt a b = a == b

%noinline
ltInt : Int -> Int -> Bool
ltInt a b = a < b

%noinline
eqFlip : Int -> Int -> Bool
eqFlip a b = a /= b

%noinline
ltFlip : Int -> Int -> Bool
ltFlip a b = a > b

-- Every field is a plain top-level name, so each folds to an
-- `RCConstClosure` with zero captured values and the record itself to
-- one `RCConstCon`.
plain : Cmp Int
plain = MkCmp eqInt ltInt

flipped : Cmp Int
flipped = MkCmp eqFlip ltFlip

-- `c` appears only as a `case` scrutinee (once per projection) and is
-- never passed on to another call, which is exactly what
-- `paramIsScrutineeOnly` requires.
%noinline
classify : Cmp Int -> Int -> Int -> String
classify c x y =
    if c.eq x y then "eq"
    else if c.lt x y then "lt"
    else "gt"

-- `c` is scrutinised *and* passed straight back to this same argument
-- position on the recursive call -- nothing else. That is exactly what
-- the relaxed gate allows and the strict one refused.
%noinline
countMatches : Cmp Int -> Int -> List Int -> Nat
countMatches c x [] = 0
countMatches c x (y :: ys) = (if c.eq x y then 1 else 0) + countMatches c x ys

main : IO ()
main = do
    putStrLn (classify plain 1 2)
    putStrLn (classify plain 2 2)
    putStrLn (classify plain 3 2)
    putStrLn (classify flipped 1 2)
    putStrLn (classify flipped 2 2)
    putStrLn (classify flipped 3 2)
    printLn (countMatches plain 2 [1, 2, 2, 3, 4])
    printLn (countMatches flipped 2 [1, 2, 2, 3, 4])
