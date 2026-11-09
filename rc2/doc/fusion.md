# Fusion rewrites on the named case trees (design)

Status: **not implemented -- safety could not be confirmed.** Rules match
library functions by `Name` because the trees carry no types, and it is
unverified that a matched `Name` (e.g. `Prelude.Types.foldl`) always denotes
the `List` implementation: instance methods print with identical names in
`dumpnamed`/`--dumpcases` output (`Prelude.EqOrd.<` for `Ord Int` and `Ord
Integer`, many `Prelude.Show.show`), so a rule could fire on a non-`List`
function. The rules also assume purity (see "Correctness conditions"). The
document below is a design sketch only. `--directive dumpnamed`
(implemented) is the tool used to find the gaps listed here.

## Motivation

Upstream's `NamedCExp` (phase `Cases`) fuses nothing across list
combinators. Measured with `tmp/fuse/Fuse.idr` (`--directive dumpnamed
--directive noinline` shows the tree upstream hands to rc2; without
`noinline` it shows what `InlineCExp` makes of it):

| source                         | what stays in the tree                                  |
|--------------------------------|---------------------------------------------------------|
| `map f (map g xs)`             | `mapAppend [Lin, f, mapAppend [Lin, g, xs]]`            |
| `map f (filter p xs)` and v.v. | `mapAppend`/`filterAppend` nested                       |
| `filter p (filter q xs)`       | nested `filterAppend`                                   |
| `foldl/foldr f z (map g xs)`   | `Prelude.Types.foldl [f, z, mapAppend [...]]`           |
| `foldl/foldr f z (filter p xs)`| likewise with `filterAppend`                            |
| `sum/length/all/any (...)`     | `Foldable` record CAF (`MkFoldable`) projected at run time; `all`/`any` go through `foldMap` + `<+>` |
| `length (map f xs)`            | `lengthPlus [0, mapAppend [...]]`                       |
| `[a..b]` consumed by a fold    | `rangeFromTo` dissects `Ord`/`Neg` dictionaries per call, builds the list |
| `reverse (reverse xs)`         | two `reverseOnto` passes                                |
| `take n (map f xs)`, `zip (map f xs) ys`, `map f (xs ++ ys)` | intermediate list stays   |

Note the library names the rules must match: `map`/`filter` arrive as
`Prelude.Types.List.mapAppend [Lin, f, xs]` /
`Prelude.Types.List.filterAppend [Lin, p, xs]` (accumulate into a
`SnocList`, finish with `<>>`), not as the recursive definitions in the
source. The first argument being the literal `Lin` (`%con [nil]`) is part of
the pattern.

## Where it runs

```
applyLazyCaf
  -> InlineCExp          (existing: Criterion A/B inlining, case-of-case)
  -> FuseCExp            (NEW: this document)
  -> DeadArgs -> ArityRaise -> lowerProgram (lambda lifting, ...)
```

After `InlineCExp`, because it exposes the `let`-bound dictionaries and
wrappers (`sum`, `length`, `all`, `foldMap`) the fusion rules need to see
through. Before `lowerProgram`, because lifting turns the lambdas the rules
build and consume into separate top-level functions where they can no longer
be matched structurally. `FuseCExp` ends with one more `collapse`
(case-of-case) pass, since fusion produces new `case`-in-`case` nesting.

Disabling: `nofusion` (whole pass) and `nofusion-<rule>` per rule; both
are derived from the rule table (see below), so adding a rule adds its
directive. They go through `Stage` (`Stage.idr`) like every other stage.

## Shape of the implementation

New module `Compiler.RC2.FuseCExp` (the driver) and
`Compiler.RC2.FuseRules` (the rule table). The name `Compiler.RC2.Rewrite`
is taken (it is the `RCExp` tree rewriter).

### A rule is one function

```idris2
||| A local rewrite at one node. `Nothing` = does not apply.
record Rule where
    constructor MkRule
    name : String                       -- directive suffix: nofusion-<name>
    doc  : String                       -- one line, shown by a debug listing
    run  : FuseEnv -> NamedCExp -> Core (Maybe NamedCExp)

export
allRules : List Rule
allRules = [ knownConCase, betaReduce, inlineSingleUse
           , mapMap, filterFilter, ...
           ]
```

Adding a transformation later = write one `Rule` value in `FuseRules.idr`
and add it to `allRules`. Nothing else changes: the driver, the directive
names and the doc listing all derive from `allRules`.

### The driver

Bottom-up over every definition body (and `main`): rewrite the children,
then try the rules at the node, in `allRules` order, repeating at the same
node until no rule fires (cap 8, like `caseOfCaseHere`'s 5). The whole walk is
repeated until a walk changes nothing (cap 4). Both caps exist only to
guarantee termination if a rule pair ping-pongs; hitting one is a rule bug
and logs at `logLevel` 2.

`FuseEnv` carries what rules legitimately need and nothing else:

- `defs : SortedMap Name NamedDef` -- to see through a CAF such as
  `{csegen:18}` and to read the constructor tag of a dictionary record;
- the `Fresh` counter (reuse `InlineCExp`'s; export it from there or move it
  to `Compiler.RC2.Util`) for new binders;
- `newDefs : Ref NewDefs (List (Name, FC, NamedDef))` -- only used by tier B
  below; tier A rules never touch it.

### Pattern helpers (the part that makes rules short)

Rules should read like the equation they implement. A small set of matchers
and builders in `FuseRules.idr`, all pure:

```idris2
callOf  : Name -> NamedCExp -> Maybe (List NamedCExp)       -- NmApp (NmRef n) args
isLin   : NamedCExp -> Bool                                 -- the nil constructor
mapOf   : NamedCExp -> Maybe (NamedCExp, NamedCExp)         -- (f, xs) from mapAppend [Lin,f,xs]
filterOf: NamedCExp -> Maybe (NamedCExp, NamedCExp)
lam2    : (NamedCExp -> NamedCExp -> NamedCExp) -> Core NamedCExp   -- \a => \b => body, fresh binders
app1    : NamedCExp -> NamedCExp -> NamedCExp               -- curried application
```

and one table of the library names, so an upstream rename is a one-line fix
and a sanity check can complain when a name is absent from `defs`:

```idris2
namesMapAppend : Name   -- Prelude.Types.List.mapAppend
namesFilterAppend, namesFoldl, namesFoldr, namesLengthPlus, namesReverseOnto, ...
```

Applications of function arguments are *curried* in the trees
(`((f [acc]) [x])`), so every builder emits that form, never `f [acc, x]`.

## Rules

Priority is "all the same" per the request; they are grouped by what they
need, not by importance.

### Tier 0: enablers (make the real rules reachable)

| rule              | effect                                                                 |
|-------------------|------------------------------------------------------------------------|
| `knownConCase`    | `case x of MkFoldable a b ..` where `x` is `let`-bound to (or a CAF of) a `%con [record]` -> the alternative with the fields substituted. This is what turns `sum`/`length`/`foldr` through the `Foldable List` dictionary into the plain `Prelude.Types.foldl`/`foldr` calls. |
| `betaReduce`      | `(%lam x b) [a]` -> `let x = a in b`; applied to an atom, substitute.  |
| `inlineSingleUse` | `let x = e in ... x ...` with exactly one occurrence, not under a lambda, and no effect between the binding and the use -> substitute. Needed because `InlineCExp` binds arguments (`rc2inl:198`) which hides `mapAppend` under `foldl` behind a variable. |
| `foldMapToFoldl`  | `Prelude.Types.foldMap [mon, f, xs]` -> `foldl (\acc e => acc <+> f e) neutral xs`, exposing `all`/`any`/`concatMap` to the fold rules (it is already defined this way in the library). |

`knownConCase` is `ConstFold`'s known-constructor fold (`RCExp`) lifted to the
named trees; share the "field i of constructor C" logic with it if it
factors out, otherwise do not couple them.

### Tier A: new call, composed lambda, no new definitions

These only rebuild a call to an *existing* library function with a composed
function argument. After rewriting, `SpecClosure`
(`doc/speculative-closure-specialization.md`) clones `foldl`/`mapAppend` per
closure argument, and `Loop` turns the specialised recursion into a loop, so
the result is a tight loop without new machinery.

```
mapMap        mapAppend [Lin, f, mapAppend [Lin, g, xs]]
              => mapAppend [Lin, \x => f (g x), xs]
filterFilter  filterAppend [Lin, p, filterAppend [Lin, q, xs]]
              => filterAppend [Lin, \x => case q x of True => p x; _ => False, xs]
foldlMap      foldl [f, z, mapAppend [Lin, g, xs]]
              => foldl [\acc x => f acc (g x), z, xs]
foldlFilter   foldl [f, z, filterAppend [Lin, p, xs]]
              => foldl [\acc x => case p x of True => f acc x; _ => acc, z, xs]
foldrMap      foldr [f, z, mapAppend [Lin, g, xs]]   => foldr [\x r => f (g x) r, z, xs]
foldrFilter   foldr [f, z, filterAppend [Lin, p, xs]]
              => foldr [\x r => case p x of True => f x r; _ => r, z, xs]
lengthMap     lengthPlus [n, mapAppend [Lin, g, xs]] => lengthPlus [n, xs]
lengthFilter  lengthPlus [n, filterAppend [Lin, p, xs]]
              => foldl [\n x => case p x of True => n + 1; _ => n, n, xs]
revRev        reverseOnto [Lin, reverseOnto [Lin, xs]] => xs
```

(`reverse` is `reverseOnto [Lin, _]` in the trees. `sum`, `all`, `any`
need no rule of their own: after Tier 0 they are `foldl` calls and the
`foldl*` rules apply.)

The `foldl`/`foldr` rules all have the same shape -- "fold over a stage
chain" -- so they are written once as `foldOverStage` taking a *stage*
(next section) rather than once per producer. `foldlMap` and `foldlFilter`
above are just the two instances the table lists.

Correctness conditions, each one documented on the rule:

- **Purity.** The rules reorder calls of `f` and `g` (`g x1; f x1; g x2 ...`
  instead of `g x1; g x2; ...; f x1`). Sound when they are pure and total,
  the same assumption GHC's `RULES` make. `unsafePerformIO`/`trace` inside
  `f`/`g` are not preserved. `lengthMap` additionally drops `g` entirely.
- **Sharing.** The intermediate list must have no other consumer. A nested
  argument has exactly one by construction; a `let`-bound one is handled by
  `inlineSingleUse`, which refuses on more than one occurrence.
- **Strictness.** The trees are strict, so there is no laziness to lose; a
  fused fold evaluates each element at the same point or later than before,
  never earlier.
- **Stack behaviour.** `foldr` over `map` stays as non-tail-recursive as it
  was; `foldl` stays a loop. Nothing is made worse.

### Tier B: needs a generated loop (phase 2)

Cases where no existing library function takes the composed shape:
`map f (filter p xs)` as a list producer, `[a..b]` as a source, `take n
(map f xs)`, `zip (map f xs) ys`. They need a freshly generated
self-recursive definition, with the free variables of the composed lambdas
turned into extra parameters (a small hand lambda-lift) and the new def
added to `newDefs`.

Tier B is deliberately not part of phase 1. When it comes, it should not be
a rule per producer/consumer pair. Use a stage chain:

```idris2
data Source = Xs NamedCExp | Range Lo Hi
data Stage  = SMap NamedCExp | SFilter NamedCExp
data Sink   = FoldL f z | FoldR f z | Length | ToList     -- ToList keeps SnocList accumulation
```

`recognise : NamedCExp -> Maybe (Source, List Stage, Sink)` peels nested
library calls; `emit` generates one loop for the whole chain, with stages
applied in order per element. Adding a new stage or source means one
recogniser clause and one `emit` clause, not a new rule for each pairing
with every sink. Tier A is exactly the special case "no new def needed",
and the two should end up sharing `recognise`.

## Testing

- One test directory under `rc2/tests/`, e.g. `TestNNNFusion`, containing
  the `Fuse.idr` cases with their runtime output (the existing diff-based
  check) -- fusion must not change results, so every rule gets at least one
  case with a non-trivial `f`/`g`/`p`, and one where the fusion must *not*
  fire (shared intermediate list; effectful lambda via `unsafePerformIO`).
- Structural check: compile with `--directive dumpnamed` and assert that
  `mapAppend` / `filterAppend` are no longer nested, e.g. a `grep -c`
  based expectation file; verify.sh's expected-output convention is the
  place for it. Also compile with `nofusion` and diff the runtime output
  against the fused one.
- Run `verify.sh` and `bench.sh` before and after; the rules must not slow
  anything (BENCHMARKS.md).

## Open questions

1. Purity assumption above (and `lengthMap` dropping `g`) -- acceptable as
   the project default, or opt-in per rule?
2. Is phase 2 (generated loops) wanted, or is Tier A plus `SpecClosure`
   enough for now?
3. Library names are matched literally; the `Names` table plus a debug
   check (`dumpnamed` run against a sample) is the proposed guard against an
   upstream rename silently disabling a rule.
