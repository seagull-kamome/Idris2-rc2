# Comparing a widened integer with a literal (`Compiler.RC2.ConstFold`)

`x : Int` read as an `Integer` and compared with a literal, `0 <= cast x`, was
a `mkInt64` box, a call of `idris2rc2_cast_Int64_to_Integer`, an `Integer`
comparison and a `drop` of the box. A `cast` to `Integer` of a narrower type keeps the
value, so the comparison can be made in the narrower type; and a literal outside that
type's range decides the comparison at once.

## The rewrite

`ConstFold` remembers each `let v = cast-T-Integer a` (`Env.widened`). An
`RCmpCase` on `Integer` with `v` on one side and a literal `c` on the other is, with `lo..hi` the range of `T`:

- `c` below `lo` or above `hi`: the answer is the same for every `x`, and the
  branch taken is the whole result (`holdsOutside`); `==` is false.
- otherwise: the comparison on `T` of `a` and `c` (`Narrowed`), kept in the same order of operands.

The `let v` stays if the branches still use it, and goes if nothing does.
`Sink` then moves a `cast` that only one branch reads into that branch.

`T` is `Int`, `Int8`..`Int64`, `Bits8`..`Bits64` and `Char`. A `Char` literal in the range of
surrogates is not rewritten. Two casts compared with each other (`cast x < cast y`) are
not handled; only a cast against a literal is.

## Measured

In the IR of `rc2-norepl`, 66 of 759 `Integer` comparisons were of this kind
(57 from `Int`, mostly `0 <= cast x` of `integerToNat`).

## Test

`Test162WidenCompare`: every type, both orders of operands, a literal in range and
out of range on each side. The IR has 2 `Integer` comparisons against 35 with
`--directive noconstfold`, and the output is the same.
