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

main : IO ()
main = do
    putStrLn (classify plain 1 2)
    putStrLn (classify plain 2 2)
    putStrLn (classify plain 3 2)
    putStrLn (classify flipped 1 2)
    putStrLn (classify flipped 2 2)
    putStrLn (classify flipped 3 2)
