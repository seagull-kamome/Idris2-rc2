# Raising a closure-returning function's arity (world arity raising): design

Status (2026-09-26): investigated and designed, not implemented. Grew out
of `struct-return.md`'s "`apply` tails" open question.

## The problem

A function returning `IO` (or upstream's `Core`, a record around
`IO (Either Error a)`) often reaches the IR with its world argument split
off into a lambda of its own. Its body builds a closure waiting for the
world, and every caller applies that closure at once:

```
def TTImp.WithClause.mergeMatches  (fun args= [v1, v2, v3, v4] ret= Boxed)
  partial TTImp.WithClause.{mergeMatches:0} missing= 1 [v1, v2, v3, v4]

-- a caller
let x : Boxed =
  let c : Boxed =
    call TTImp.WithClause.mergeMatches [a, b, c, d]
  apply c [w]
case x of
  Prelude.Types.Left ... -> ...
  Prelude.Types.Right ... -> ...
```

Each call allocates the closure, captures (and so `dup`s) every
argument, dispatches through `apply`, and frees the closure again. The
`Either` the lambda returns sits behind the `apply`, so struct return
(`struct-return.md`) never sees it: the callee's result shape is
unknown.

A tail may also be a constant closure, one that captures nothing
(`#Main.{sumPos:0}/1~closure`, `RCConstClosure`), and a function may
pattern-match on its explicit arguments before choosing which closure to
return. A small `Core` clone shows both:

```idris
sumPos : List Int -> Core Int
sumPos [] = pure' 0
sumPos (x :: xs) = if x < 0 then throw' "negative"
                   else sumPos xs `bind` \s => pure' (s + x)
```

```
def Main.sumPos  (fun args= ["v38:Boxed"] ret= Boxed)
  case v38 of
    _builtin.NIL ... -> #Main.{sumPos:0}/1~closure
    _builtin.CONS ... args= [v39, v40] -> partial Main.{sumPos:2} missing= 1 [v39, v40]
```

### Where the shape comes from

Upstream's own dumps (`--dumpcases`, `--dumplifted`, see
`idris2-src/docs/source/reference/debugging.rst`) show it already in the
case trees: the elaborator matches on the explicit arguments first and
puts the world's lambda inside each branch.

```
-- --dumpcases
Main.sumPos = [{arg:0}]: (%case !{arg:0}
  [(%concase _builtin.NIL ... (%lam {eta:0} (Main.pure' [0, !{eta:0}]))),
   (%concase _builtin.CONS ... [{e:2}, {e:3}] (%lam {clam:0} (%case ...)))] Nothing)
-- --dumplifted
Main.sumPos = [{arg:0}][]: %case !{arg:0} of
  { %conalt _builtin.NIL() => <Main.{sumPos:0} underapp 1>()
  | %conalt _builtin.CONS({e:2}, {e:3}) => <Main.{sumPos:2} underapp 1>(!{e:2}, !{e:3}) }
Main.{sumPos:2} = [{e:2}, {e:3}][{clam:0}]: ...
Main.main = ... Main.sumPos(...) @ (!{ext:0}) ...
```

Lambda lifting turns each branch's lambda into a function of its own
whose captured variables come first and the world last (`args` then
`scope`), so appending the world to a `partial`'s arguments is exactly
the saturated call. A caller's `f(...) @ (w)` becomes the
`let c = call f ...; apply c [w]` pair in the `RCExp`.

## Measurements (idris2-lsp, 2026-09-26)

A throwaway tool in the session scratchpad parsed the final `dumprcexpr`
with struct return off.

Of the 2,148 functions that struct return would add if every `apply`
tail were allowed (an upper bound: 4,245 cased call sites become 4,656),
the closure in those tails comes from:

| closure origin | `apply` tails |
|---|---|
| the result of a call | 1,181 |
| a field of a constructor (`MkMonad`/`MkApplicative`: 283) | 324 |
| a parameter (a continuation, `mapTTImp f`) | 253 |
| other | 112 |

A dictionary field or a parameter says nothing about what the closure
returns without specialisation, and the whole upper bound is small. The
call results are the pattern above:

- **622 functions** return a closure missing exactly one argument in
  every tail (a `partial ... missing= 1`, a constant closure missing 1,
  a crash, or a tail call to another such function). 136 of them are
  bare wrappers, `f args = partial g missing= 1 args`.
- **4,069 `apply` sites** saturate a call to one of them: 1,057 in a
  tail, **2,826** switched on at once.
- With the world passed as an extra parameter instead, 338 of the 622
  become eligible for struct return, and 1,247 of the 2,826 sites become
  cased calls to a struct-returning worker (struct return has 4,245
  cased sites today: +29%).

The pattern belongs to `Core`-style code: idris2-missing-containers has
two such sites.

## The transformation

For each function `f` in the set `R` above, make `f#` taking one more
parameter `w`:

- a tail `partial g missing= 1 xs` becomes `call g (xs ++ [w])`;
- a tail constant closure `g/1~closure` becomes `call g [w]`;
- a tail call `call h ys` to `h` in `R` becomes `call h# (ys ++ [w])`;
- a crash stays.

`f` itself becomes the bare wrapper `partial f# missing= 1 args`, so a
caller that keeps the closure (stores it, passes it on) still gets one,
and it still ends up running the same code. A bare wrapper `f` of `g`
needs no `f#`: its sites call `g` directly.

A call site `let c = call f xs` in `R` whose `c` is used exactly once,
by an `apply c [w]` evaluated right after it (the `let`'s body, or the
value of the next `let`, as in the examples), becomes
`call f# (xs ++ [w])`. Moving the call past nothing keeps evaluation
order intact. Everything else keeps the closure.

`R` is a greatest fixpoint, like struct return's plan: tails are read
through `let` bodies and the branches of every `case`, and a function
must reach at least one closure tail. A lazy call or a lazy `apply` is
left alone, and so is a function of no arguments (a CAF: its closure is
built once and shared, see `caf-memoization.md`).

## Placement

On the pre-RC `RCExp`, right after "RC normalize" and before `ConstFold`:

- no `dup`/`drop` exists yet, so the rewrite is purely structural and
  `annotate` decides ownership for the new calls as for any other;
- `ConstFold`, `PushCon`, the specialisations and the inliners see
  direct calls. A small `f#` may inline into its caller, a known
  constructor coming back from it may fold;
- DualABI then gives `f#` native parameters and a struct return like
  any other function.

Floating the lambda out of the `case` in the case trees
(`\x => case x of { A => \w => a; B => \w => b }` to
`\x, w => case x of { A => a; B => b }`) would fix the shape at its
source, but the case trees, like lambda lifting's `Lifted`, are scoped
by de Bruijn index, and adding a parameter means re-indexing the body;
the pre-RC `RCExp` names locals by id.

A tail call to `g` inside `f#` is an ordinary tail call: `Loop` turns a
self tail call into a `goto`, and any other goes through the trampoline
as before. Before the rewrite, `f` returned the closure to its caller's
`apply` instead, which is no deeper.

## Implementation plan

1. `Compiler.RC2.ArityRaise` (new module): `R`, `f#` synthesis
   (`MN "rc2_raised_<f>"`, the naming `SpecClosure` uses), the call-site
   rewrite, and a `noarityraise` directive in `disableableStageNames`,
   documented in `directives.md`.
2. A `dumpdualabi`-style count of `R` to check against the figures
   above.
3. Tests: a `Core` clone like the one above (pattern matching, a
   constant closure, a bare wrapper, a closure kept and applied later,
   self recursion); `verify.sh` checks that the cased sites call `f#`
   and that `f#` returns a struct. Leak-sensitive.
4. Measure: idris2-lsp's final IR (`apply`, `partial`, struct workers,
   cased struct sites) and a `Core`-chain benchmark, since idris2-lsp
   does not reach C generation.
