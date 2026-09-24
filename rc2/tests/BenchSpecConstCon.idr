module Main

-- Constant-constructor (interface-dictionary) argument specialization
-- -- the shape `Compiler.RC2.SpecClosure.applySpecConstCon` exists for
-- (`doc/constant-constructor-specialization.md`).
--
-- One layer deeper than `BenchConstClosureApply`, which applies a
-- constant closure directly. Here the constant is a *record* that the
-- callee destructures before applying one of its fields -- the
-- interface-dictionary shape, which `Compiler.RC2.SpecClosure`'s own
-- closure half cannot see:
--
--   step d x = (d.g (d.f x)) `mod` 1000003
--
-- Without the pass, each iteration destructures `ops` and dispatches
-- both fields through `idris2rc2_applyClosure` -- an arity check, an
-- argument copy and a function-pointer-table hop per call, for callees
-- known at compile time. With it, `step` is cloned with `ops`
-- substituted, which folds the destructuring `case` away and leaves
-- each field an `RCConstClosure` for ConstFold's own `RApp` case to
-- turn into a direct call.
--
-- `%noinline` keeps `Compiler.RC2.Inline`/`LateInline` from removing
-- the very call sites this exists to measure; `d` is deliberately only
-- ever a `case` scrutinee inside `step`, never passed on, since that
-- is what `paramIsScrutineeOnly` requires.
--
-- A/B it with `--directive nospecconstcon`.

record Ops where
  constructor MkOps
  f : Int -> Int
  g : Int -> Int

%noinline
addOne : Int -> Int
addOne x = x + 1

%noinline
mulTwo : Int -> Int
mulTwo x = x * 2

ops : Ops
ops = MkOps addOne mulTwo

%noinline
step : Ops -> Int -> Int
step d x = (d.g (d.f x)) `mod` 1000003

run : Int -> Int -> Int
run acc 0 = acc
run acc n = run (step ops acc) (n - 1)

main : IO ()
main = printLn (run 1 2000000)
