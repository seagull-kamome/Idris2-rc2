# `RC.idr`'s `lookupEnv`: a full totality proof through `IsVar` is impossible (2026-09-17)

Moved from `TODO.md`, which keeps the conclusion. (Japanese: `ja/lookupenv-totality.md`.)

Phase 1 of `Compiler.RC2.RC` (`normalizeDef`) walks `Lifted vars` from `Compiler.LambdaLift`. It tracked the de
Bruijn indices in `Env = List Int`, a flat list that "should" have the length of `vars`, and `lookupEnv` had a
safety net that calls `idris_crash` when an index is out of range. `LLocal` itself already carries
`(0 p : IsVar x idx vars)`, a proof that `idx` is a valid index into `vars` (`Core.TT.Var`). The first design
was to pass this proof through `normalizeDef`, which would make `lookupEnv` a total function with no crash (the
pattern "an invariant the types guaranteed is thrown away at a boundary").

**What turned out.** The `p` field of `LLocal` is declared `0` (erased) upstream. Idris2 consistently rejects
a function that branches on the constructor of an erased value and returns different run-time data per branch
(`Can't match on First (Erased argument)`). This is not a matter of the order or the way of writing. I was
misled by `nameAt` in `Core.TT.Var` (`nameAt {vars = n :: _} First = n`, exactly the shape I wanted), which
seems to compile; an independent minimal reproduction showed that `nameAt` is allowed only when the returned
value `n` can be taken from the **type-level index** `vars` itself. For a general function that returns a value
computed at run time (here an `Int`), the same error reproduced even in the smallest form, whose only argument
is `p` (the equivalent of `myCount : (0 p : MyIsVar n idx vars) -> Int`). So a design that uses an erased
validity proof to guarantee safe indexing into run-time data by type checking alone cannot be reached from
rc2's side, however it is written, as long as `IsVar` is erased upstream.

**The alternative that was done.** `Env` changed from `List Int` to `Env : List Name -> Type; Env vars = All
(const Int) vars` (through `Data.List.Quantifiers.All`), so the length of `env` matches `vars` at the type
level. Now, at every place that extends the scope (`normalizeDef`, `LLet`, `normalizeConAlt` and others), the
whole class "building an `env` that disagrees with the extension of `vars`" is a compile error rather than a
crash at run time. But `lookupEnv` itself still has to keep a recursion on a `Nat` (`idx`) and the final
"should be unreachable" catch-all that crashes. What shrank is the reachability of the crash, now only for the
case that `idx` itself is wrong; it is not a full totality proof.

**What to consider next.** If `Compiler.LambdaLift` (upstream) were changed to make the `p` of `LLocal` not
erased, true totality would be possible, but changing the upstream compiler is out of scope for this package.
Another way is, as a Phase 0 of rc2's own, to convert `Lifted` once into an IR of its own with non-erased
`Fin`-based indices (the cost is rebuilding the proofs). The cost-benefit is to be examined.
