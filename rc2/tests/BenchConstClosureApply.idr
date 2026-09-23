module Main

-- Saturated application of a *constant* closure -- the shape
-- `Compiler.RC2.ConstFold` now rewrites straight into a direct call
-- (`doc/const-closure-fold.md`'s "Saturated application of a folded
-- closure is now a direct call").
--
-- `ops` is a record of plain top-level functions, so each field folds
-- to an `RCConstClosure` (a bare name reference, zero captured
-- values) and every `ops.f`/`ops.g` call site applies it with exactly
-- its whole arity. Before the rewrite each of those was an
-- `idris2rc2_applyClosure(((IDRIS2RC2_Value*)&constclosure_N), arg)`
-- -- an arity check, an argument copy and a dispatch through
-- `support/rc2/runtime.c`'s own function-pointer table, for a callee
-- known at compile time. `%noinline` keeps `Compiler.RC2.Inline` from
-- removing the call sites this exists to measure.
--
-- This is the interface-dictionary dispatch shape in miniature: a
-- whole idris2-lsp build has 4,842 `apply` nodes against a constant
-- closure, 3,881 of them saturated. Measured A/B on this benchmark
-- when the rewrite landed: ~0.475s -> ~0.375s, about 21% faster,
-- with `idris2rc2_applyClosure` call sites in its own generated C
-- going 3 -> 1.

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

run : Int -> Int -> Int
run acc 0 = acc
run acc n = run ((ops.g (ops.f acc)) `mod` 1000003) (n - 1)

main : IO ()
main = printLn (run 1 2000000)
