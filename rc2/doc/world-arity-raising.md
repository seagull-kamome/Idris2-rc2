# Raising a closure-returning function's arity (world arity raising)

Status: implemented and on by default since 2026-09-26
(`Compiler.RC2.ArityRaise`, `--directive noarityraise` turns it off).
Grew out of `struct-return.md`'s "`apply` tails" open question.

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
order intact. The call may end a chain of `let`s in the value
(`let c = (let a = ...; call f [a]); apply c [w]`, what an inlined
argument leaves); the raised call takes its place at the end of that
chain. Everything else keeps the closure.

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

## Implementation

`Compiler.RC2.ArityRaise.applyArityRaise` runs twice on the pre-RC
`RCExp`: right before `ConstFold`, and again after the early inline.
The second run sees sites the passes in between exposed (an inlined
`bind`, say), and a function the first run raised is a bare wrapper of
its raised version by then, so its new sites call that directly.

Two existing bugs surfaced on the new shapes, both fixed with it:

- `Sink` moved a `let` whose value reads a local past a `drop` of that
  local (`branch-sinking.md`'s "Not sinking a read past its operand's
  drop"); `rcexpr-lint` caught it on idris2-lsp.
- `MutualLoop` shared parameter slots between members by position, so
  one slot could hold one member's closure and another member's `Int`,
  and native-shadow promotion then unboxed the closure
  (`loop-conversion.md`'s "Bugs found" 8); `BenchArityRaise` crashed
  on it. Members now share slots only within one class of parameter
  (by the native type Loop would promote it to), and a class-less slot
  is never promoted.

## Results (2026-09-26)

idris2-lsp, final `dumprcexpr`, `rcexpr-lint` clean both ways:

| | `noarityraise` | raised |
|---|---|---|
| definitions | 22,798 | 19,530 (1,325 raised) |
| `apply` | 9,161 | **3,771** (−59%) |
| `partial` | 11,115 | 8,556 |
| struct workers | 726 | 1,345 |
| `let ... : RetN` (cased struct sites) | 6,164 | **9,952** (+61%) |
| `reuseOffer` | 17,768 | 12,658 |
| `con` | 51,038 | 49,498 |

The definitions that go are mostly the closures' own lambdas
(`{f:0}`), now called only from the raised version and inlined into it,
and the originals whose every site was rewritten.

`tests/BenchArityRaise.idr` (`BenchStructReturn`'s `step` chain against
a `Core` clone whose `pure` and `>>=` are `%inline`, as upstream's are;
five million calls, best of five): **2.15 s → 1.02 s**. Without the
`%inline` the `bind` is only inlined after RC annotation, where this
pass no longer runs, and the gain is 3.21 s → 1.77 s. `Test92ArityRaise`
covers pattern matching, a constant closure, a tail delegation, closures
kept in a list and applied later, and a plain `IO` function.

idris2-missing-containers (two such sites; six alternating runs, the first
left out, averaged): 8.05 s → 7.83 s (−2.8%), identical output.

## After `LateInline` (investigated 2026-09-26)

The pass runs before RC annotation, so a site that only `LateInline`
exposes afterwards keeps its closure. idris2-lsp's final IR has 3,788
`apply` sites left; by where the closure comes from:

| closure | `apply` sites | without `LateInline` |
|---|---|---|
| a parameter (a continuation, a higher-order argument) | 1,161 | 2,467 |
| a call result | 1,092 | 860 |
| a constructor field (a dictionary method) | 857 | 848 |
| a `case` and the like | 318+ | 262+ |
| a `partial` in the same function | **110** (52 exact, 58 with more arguments) | 75 |

Of the call results, 186 apply the result of a raised function's
wrapper (`partial f# missing= 1`) at once (72 without `LateInline`).
Upstream's `>>=` is `%inline`, so its splice happens before RC
annotation and this pass sees it; only a non-`%inline` `bind`, like
`BenchArityRaise` without it, leaves the shape to `LateInline`. So the
post-`LateInline` part is about 300 sites: the "post-RC fold" below.

The remaining call results mostly come from callees whose tails mix a
`partial` with other closures: `partial`+`apply` (190), `partial`+a
variable (72), only `apply` (226), only a call (218). Raising those
too (a tail `apply h ys` becomes `apply h (ys ++ [w])`, a variable `x`
becomes `apply x [w]`, a call to an unraised function `h` becomes
`let c = call h ...; apply c [w]`) is sound, but saves a closure only in
the `partial` branches. Not pursued yet (`TODO.md`).

### Post-RC fold (implemented 2026-09-26, `--directive noapplyfold`)

Right after `LateInline`, before `Sink` and DualABI, a `let c` whose
value ends (through leading `let`s and `dup`s) in `partial g m xs`, or
in a call to a bare wrapper `f xs = partial g m xs`, and whose `c` is
applied exactly once afterwards, by an `apply c ys` outside any loop, and
otherwise only dropped:

- `|ys| == m`: the `apply` becomes `call g (xs ++ ys)`;
- `|ys| == m + 1` and `g` is itself a bare wrapper of `h` missing one:
  it becomes `call h (xs ++ ys)`.

The value's leading `let`s and `dup`s stay where they were; only the
closure's construction moves to the `apply`. No `dup`/`drop` changes:
`partial`, `call` and `apply` all consume their arguments, and moving
the construction later keeps every reference count the same until
then, since the closure's references to `xs` were the ones the code in
between never touched. Annotation has every path consume `c` somewhere,
so every path either applies it there or drops it (below).

A `drop c` on a path that never applies the closure becomes a `drop`
of what the closure held, its Boxed captured arguments: the closure is
fresh and nobody else holds it, so dropping it would have dropped
exactly those. A captured `RInlineNative` local (spliced where it is
read) keeps the closure in place, since its read must not move.

Results: `BenchArityRaise` with a non-`%inline` `bind` (Test93's shape)
runs 1.77 s → **1.18 s** (with `%inline`: 1.02 s, unchanged). On
idris2-lsp, `apply` goes 3,771 → 3,507, a `partial` applied in its own
function 110 → 25, cased struct sites 9,952 → 9,984; `rcexpr-lint`
clean. `Test93ApplyFold` checks `run` is left with no `apply`.

### Raising functions whose tails mix closures: estimate (2026-09-26)

Not implemented. On idris2-lsp's final IR (with the pass and the
post-RC fold), 915 `apply` sites still apply a call's result at once;
for 839 of them (84 callees; 374 switched on at once, 66 in a tail)
every tail of the callee is some closure. Weighting each callee's tails
equally, per site:

| raised tail | weight | closure allocation |
|---|---|---|
| `partial ... missing= 1` → a call | 250 | saved, as in the pass itself |
| `partial ... missing= m > 1` → `partial ... missing= m - 1` | 51 | one saved |
| `apply h ys` → `apply h (ys ++ [w])` | 270 | saved when `h` was under-applied (most) |
| a variable `x` → `apply x [w]` | 47 | none (the `apply` just moves) |
| a call to an unraised `h` → `let c = call h ...; apply c [w]` | 222 | none |

About 300 sites save a closure for certain, 570 counting the `apply`
tails: one to two tenths of what the pass itself reached (4,069). An
`apply` or variable tail leaves the raised function's result shape
unknown, so struct return gains next to nothing, unlike the pass
itself. The best candidates are mostly-`partial` functions with a few
`apply` tails (`goPTerm` 97 sites, `schExp` 80, `processDecl` 12);
restricted to callees whose tails are only `partial`s and `apply`s,
292 sites (188 cased) remain, and the rewrite needs only the `apply`
rule on top of the pass. How often these run is unknown while
idris2-lsp cannot reach C generation.
