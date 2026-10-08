# Native type inference (`Compiler.RC2.Types`)

Implementation notes for rc2's native (unboxed) representation
machinery, written to let a future session regain full context without
re-deriving the design or re-discovering the bugs already found and
fixed here. Corresponds to the original Stage 2-3 implementation plus
several follow-on refactors and fixes (see `git log`, commits from
`2026-08-12` for "reduce unnecessary variable/statement generation",
"ROp's operand-drop", "elide dup/drop for always-tagged PrimTypes", and
`2026-08-13`'s comparison/branch fusion). See also
`doc/reuse-analysis.md` for the companion IR-level pass this document's
machinery interacts with (both consult the same `natives` set).

## The problem

Idris2's own compiled IR (`Lifted`) represents every value uniformly as
a boxed `IDRIS2RC2_Value*` -- an arithmetic chain like `x * x + 1`
would otherwise allocate a fresh heap cell and refcount-manage it for
every intermediate result, exactly like RefC does. rc2's native type
inference lets *function-local* numeric intermediates skip that
entirely: they live as raw C scalars (`int64_t`, `double`, ...) on the
stack, with no heap allocation and no refcount traffic, for as long as
they stay within one function body.

**Deliberate scope boundary** (see `TODO.md`'s "Scope" section): this
applies only to `RLet`-bound intermediates coming directly from a
numeric `PrimFn` or literal. Function *arguments* and *return values*
stay boxed unconditionally -- the calling convention itself is
unchanged (no dual native/boxed ABI; that's the single biggest
remaining lever, tracked separately in `TODO.md`'s "Performance"
section). `Integer` (GMP) and `String` are never native-eligible at
all, regardless of context.

## Where the decision is made and stored

Unlike the reuse pass (a separate tree-rewriting pass run after
Phase 1+2), native-vs-boxed is decided **inline**, during `RC.idr`
Phase 1 (`normalize`/`bindCompound`), by calling `Types.repOf` on the
value being bound and storing the result directly on the `RLet` node's
own `Rep` field (`RBoxed | RNative PrimType`, `RCExp.idr`). There is no
separate whole-tree analysis pass and no side table for this decision
itself -- `Emit.idr`'s `RepMap` is populated incrementally as each
`RLet` is *emitted*, purely so later *uses* (which only carry a bare
`RCLocal` id, not the deciding node) can look the already-made decision
back up; it is not where the decision is made.

### `Types.idr`'s decision functions

- `nativeEligible : PrimType -> Bool` -- the eligible set: `Int`,
  `Int8`/`16`/`32`/`64`, `Bits8`/`16`/`32`/`64`, `Double`, `Char`.
  Notably *not* `Integer`/`String`.
- `opResultRep : PrimFn arity -> Maybe PrimType` -- the Rep a `PrimFn`'s
  result would have if native-eligible. Every arithmetic/bitwise op and
  every `Double*` math function is covered; comparisons (`LT`/`GT`/
  `EQ`/`LTE`/`GTE`) are **deliberately absent** here (see
  "Comparisons are a separate mechanism" below).
  `Cast i o` is the one case needing both types: the result is native
  only if *both* `i` and `o` are native-eligible (`nativeEligible i &&
  ifNative o`) -- casting *from* a non-native-eligible source (GMP
  `Integer`, `String`) must stay on the boxed `idris2rc2_cast_*` path
  even when the *destination* type would itself be native-eligible,
  because there is no native representation of the source value to
  read in the first place.
- `opArgTyFor : PrimType -> PrimFn arity -> PrimType` -- the operand
  type for a specific op, given its own (already-decided) result type
  `ty`. Every op shares `ty` between its result and all its operands
  *except* `Cast`, whose single argument's type is the op's own source
  type `i`, not the result type `o`. Shared by `RC.idr` (deciding which
  Boxed operands are `alwaysUnboxed`) and `Emit.idr` (rendering/
  unboxing each operand) so this correspondence has one definition, not
  two kept in sync by hand.
- `litRep : Constant -> Maybe PrimType` -- which numeric-literal
  `Constant` kinds are native-eligible. Shared by `RC.idr`'s `bindOne`
  (deciding whether an operand needs an `RCConst` at all -- see below)
  and `Emit.idr`'s `repOfLocal`.
- `repOf : RCExp -> Maybe PrimType` -- the actual entry point `RC.idr`
  calls at every `RLet`/`bindCompound` site. Only `ROp`/`RPrimVal` ever
  propose `Native`; a bare variable passthrough (or anything else)
  stays `Boxed`. Peels through a chain of *synthetic* `RLet`s (Phase
  1's own ANF-normalisation introduces one whenever an operand isn't
  already a plain variable, e.g. the literal `2` in `d * 2`) to find
  the real `ROp`/`RPrimVal` underneath -- **this peeling was itself the
  fix for a real bug** (see "Bugs found" below): without it, an
  operation wrapped in a synthetic let for one of its own operands
  would fail to be recognised as native-eligible at all.
- `alwaysUnboxed : PrimType -> Bool` -- a *different* concept from
  `nativeEligible`, easy to confuse with it. The rc2 runtime
  represents `Int8`/`16`/`32`, `Bits8`/`16`/`32`, and `Char` as tagged
  pointers *unconditionally* (payload packed into the pointer word
  itself, see `support/rc2/datatypes.h`), never a real heap
  allocation -- unlike `Int`/`Int64`/`Bits64` (which allocate outside a
  small-int cache) or `Double` (which always allocates). This is a
  runtime-representation fact about *Boxed* values (still
  `IDRIS2RC2_Value*` at the C level, e.g. an ordinary function
  argument), not about whether a *local* got the Native treatment
  above -- `idris2rc2_dup`/`drop`/`free` on such a value are
  unconditional no-ops regardless, so generating the calls at all is
  pure waste. Consulted by `RC.idr`'s `alwaysUnboxedBoxedLocalsR` (see
  "The `natives` set" below).
- `cmpOpTy : CmpOp -> PrimType` (`RCExp.idr`) -- added alongside
  comparison/branch fusion (see below); the shared operand type of
  `LT`/`GT`/`EQ`/`LTE`/`GTE`, which have no `opResultRep` entry of their
  own. `CmpOp` pairs the op with an erased `IsCmp` proof, so `RCmpCase`
  can only ever hold one of those five.

### `RCLocal.RCConst` -- literals skip `RLet` entirely

A native-eligible literal operand (`litRep` covers it) never gets an
`RLet`+`RPrimVal` pair at all: `RC.idr`'s `bindOne` produces an
`RCConst c` directly on the spot (`RCExp.idr`'s `RCLocal` type), with
no id allocated and no synthetic binding. `Emit.idr` renders it as an
inline literal expression wherever it's read (`repOfLocal`/
`inlineExprFor`), with no C declaration and no `RepMap`/`InlineMap`
bookkeeping needed. Anywhere ownership is reasoned about (`Owned` sets,
the `natives` set, `RDup`/`RDrop`/`RFree` targets) must treat `RCConst`
like a native local: excluded, never touched (`RC.idr`'s
`splitBorrows`'s very first clause).

## The `natives` set -- how ownership analysis (Phase 2) stays consistent

Phase 2 (`annotate`) needs to know, for *every* use of *every* local,
whether it participates in reference counting at all. Two entirely
different reasons put a local in the `natives : SortedSet RCLocal` set
`annotateDef` builds once per definition (`definitionNatives`):

1. **`nativeLocalsR`** -- genuinely `RNative`-Rep `RLet`-bound locals
   (Phase 1's own decision, walked back out of the tree). No refcount
   at all; not even boxed.
2. **`alwaysUnboxedBoxedLocalsR`** -- Boxed locals (typically function
   arguments) whose *type* is `Types.alwaysUnboxed` at a native op's
   own operand position. These *do* have a refcount at the C level,
   it's just that every operation on them was always going to be a
   no-op, so it's excluded for a different reason than (1).

Every consumer of `natives` (`splitBorrows`, `boxedOperands`, the `RV`
case, `RLet`'s `owned'`/`dropDeadLet`, `annotateConAlt`) treats both
identically: never dup/drop/free, regardless of how or how many times
the local is used. This dual sourcing (and the requirement that every
consumer treat both the same way) is what let the always-unboxed
elision land without any new decision logic; item 6 of "Bugs found and
fixed" below covers two wrapper-generation paths that later missed it.

## What's stored on the IR vs. re-derived at emission

A deliberate, repeated architectural pattern in this codebase: **Phase
2 decides, Emit.idr only lowers.** Two fields exist specifically to
carry a Phase-2 decision through to emission without Emit.idr
re-deriving it:

- `RLet.Rep` -- Phase 1's own native-vs-boxed decision (not Phase 2,
  see above) but the same "decide once, store on the node" principle.
- `ROp.postDrop : List RCLocal` -- *every* Boxed operand an op needs
  dropped once it's done reading it, one entry per *occurrence* (so
  `x + x` lists `x` twice). Phase 1 always constructs this as `[]`;
  Phase 2's `annotate` fills it in via `boxedOperands natives (toList
  args)` -- a straight "not native, not RCConst" filter, independent of
  the `owned`/borrow bookkeeping (`splitBorrows`) that governs whether
  an operand needed a *dup* before this op read it: an op's read always
  needs exactly one drop per Boxed occurrence, whether that occurrence
  was moved-in (owned) or dup'd-for-borrow, since the dup (if any)
  exists precisely to give the read its own reference to consume.

This field used to *not* exist: `Emit.idr` independently re-derived
"which of my operands are Boxed" at emission time via a
`keepBoxedLocals` helper, called separately by `emitRC`'s and
`emitNativeValue`'s `ROp` cases -- the one place `RCExp.idr`'s own
"Emit is purely mechanical" claim was actually false, since two
independent call sites could in principle disagree. Moved to a single
Phase-2-computed field specifically to remove that risk (and to give
the later always-unboxed elision work, below, a single point of truth
to update instead of two).

## Emission (`Emit.idr`)

- `nativeCType : PrimType -> String` -- the raw C type (`int64_t`,
  `uint8_t`, `double`, ...).
- `nativeMk : PrimType -> String -> String` / `nativeUnbox : PrimType
  -> String -> String` -- box a native C expression into a fresh
  `IDRIS2RC2_Value*` / unbox a Boxed one down to a raw C expression
  (`idris2rc2_mkInt64(...)` / `idris2rc2_to_i64(...)`, etc.) -- the
  crossing points where a value moves between the two worlds (function
  boundaries, constructor fields, case scrutinees).
- `rcVarToNativeC`/`rcVarToBoxedC` -- read an `RCLocal` as a native or
  Boxed C expression respectively, Rep-aware (an already-Native local
  reads as-is; a Boxed one gets `nativeUnbox`'d on the spot; an
  `RCConst`/`InlineMap`'d local inlines its literal/expression text
  with no `var_N` ever declared for it). Never dup/drop on their own --
  any refcount adjustment a *use* needed was already made explicit as a
  wrapping `RDup`/`RDrop`/`RFree` node earlier in the tree (`ROp`'s
  `postDrop` is the one exception, carrying its own annotation).
- `cOp` (boxed-result ops, calls the boxed runtime function, e.g.
  `idris2rc2_add_Int64(x, y)` returning a fresh `IDRIS2RC2_Value*`) vs.
  `nativeOpExpr` (native-result ops, a raw C expression, e.g. `(x + y)`
  with no allocation at all) -- two renderers for the same `PrimFn`
  space, selected by whether `Types.opResultRep` said this op's result
  is native here.
- `emitNativeValue` -- the native-typed counterpart to `emitRC`,
  walking a chain of `RLet`/`RDup`/`RDrop`/`RFree` wrapping an
  `ROp`/`RPrimVal` to produce a raw C expression string (plus any
  pending Boxed-operand drops the *caller* must emit after actually
  using that expression -- see "the postDrop-ordering bug" below for
  why the caller, not this function, must be the one to emit them).
- `InlineMap` / `tryInlineNativeOp` -- a further optimisation on top of
  the basic Native/Boxed split: a native op with **zero** Boxed
  operands, used **exactly once**, gets its expression spliced directly
  into that one use site instead of ever being declared as a `var_N` at
  all. Zero-Boxed-operands is what makes deferring the read always
  safe (nothing an intervening dup/drop elsewhere could invalidate);
  exactly-one-use is what keeps it free of recomputation. A bare
  literal operand is the single most common member of this category
  and is handled as a degenerate case of the same table.

## Bool-producing comparison results are `alwaysUnboxed`-equivalent

A comparison that is *not* fused into an `RCmpCase` (operands of type
`Integer`/`String`, or an unfusable shape) still produces a `Boxed`
`Bool`: `idris2rc2_{lt,gt,eq,lte,gte}_<T>` in
`support/rc2/idris2rc2_numeric.h` all end in `idris2rc2_mkBool(..)`, an
`Int8`-tagged immediate (`mkBool = mkInt8`). `dup`/`drop`/`free` on it are
no-ops, yet every `case` over the result used to start with a `drop`.

`alwaysUnboxedBoxedLocalsR` therefore also puts into `natives` the local of
a `Boxed` `RLet` whose value is, directly, a `ROp` with `lazy = Nothing`
and one of `LT`/`LTE`/`EQ`/`GTE`/`GT` at any `PrimType`
(`Types.boolResultOp`). The evidence is **producer-side only**: the `let`
value. It is deliberately not inferred from a consumer (a `0 ->`/`1 ->`
`case`), and a Bool bound any other way (a call result, a `case` value, an
alias, a parameter) stays tracked. Every `natives` consumer treats the
local as in the section above: no `dup`, no `drop`, no `postDrop` entry.
Parameters (DualABI's `wrapperPostDrop`/`alwaysUnboxedDropVar`, loop
parameters) are untouched; this covers `let`-bound locals only. There is no
`--directive` switch for it.

`rcexpr-lint`'s leak check has the same rule (`Leak.idr`,
`boundToComparison`), since it does not share `natives`.

`Test13NativeArgChain`'s `check.sh` asserts that no comparison-bound local is
dup'd or dropped. On idris2-lsp's final IR (`--directive dumprcexpr`):

| | before | after |
|---|---|---|
| `drop` lines | 81,879 | 81,185 (-694) |
| `dup` lines | 81,217 | 81,217 |
| IR lines | 689,992 | 689,298 |
| `case` arms starting with a `drop` of a `0`/`1` scrutinee | 4,008 | 3,380 (-628) |

The remaining 3,380 are Bools that come from calls, aliases or branches;
covering them needs the type of the producer, not just its op.

### Stage 2: Bool-returning functions

Calls were the largest source of the remaining arm-start drops (call
results, 1,319 of the 4,008 originally). A function whose tails are `B8`
literals, native `Bits8` values or calls to such functions now has a
`ret= Native Bits8` worker (`boolReturnPlan`, `rc2/doc/dual-abi.md`'s "Bool
return"; `--directive noboolret` turns it off), so its callers bind the
result as a native `Bits8` and the `case` on it needs no `drop`. On
idris2-lsp the arm-start drops of `0`/`1` scrutinees went from 3,381 to
2,633 and the native `Bits8` workers from 362 to 594. Evidence is still
only from the producer: an `Int` `0` literal is not a `Bool`. A comparison
primitive never needs a rule of its own as a tail, since the front end
turns it into a `case` over the `B8` literals.

### Typed-constant case scrutinees

A `case` whose alts are all constants of an `alwaysUnboxed` type (`B8`,
`Char`, `Int8`, ...; `Types.litRep`) has a scrutinee that holds a tagged
immediate, by Idris2's typing (a local has one type): a `Bool`, an
all-nullary enum or a `Bits8`. `dup`/`drop`/`free` on it are no-ops, so
`Types.typedConstScrutinees` collects each such genuine `RCLoc` and
`RC.definitionNatives` unions it into `natives`, exactly as for an
operand of an `alwaysUnboxed` op (`alwaysUnboxedBoxedLocalsR`). Switch:
`--directive noboolcase`.

This is **not Bool-ness**. The evidence decides unboxing only, and it
is typed: the constant kind (`B8 0`), never a bare `0`/`1` (an `Int`
or `Nat` match has `I`/`BI` alts and does not qualify). A `Bits8` or an
enum scrutinee may hold 2..255, and a `1 -> A; _ -> B` case keeps its
exact semantics (nothing here, in `Emit` or in any pass, rewrites it into
a truthiness test or an "other of 0/1" branch); `boolBranches` (the only
0/1-shaped two-way rewrite) fires only on a fused comparison result. None
of `boolProducer`, `boolReturnPlan` or the `B8 0`/`B8 1` literal checks
reads this set.

Because a call that reads such a local natively used to add it to the
`postDrop` of its `RAppNameRep`, `applyCallSiteRewrite` removes these
locals from every `postDrop` of the def (`stripImmediatePostDrop`), or
`annotate` would have no dup to pair with that drop.

The dump prints an alt constant of an always-unboxed type as `u: <c> ->`
(`Pretty.immediateMark`), so `rcexpr-lint`, which cannot see constant
types, re-derives the same set (`Leak.typedImmediateAlts`; fixture
`tools/rcexpr-lint/tests/typedcase.rcexpr`). A `u:` local is therefore
exempt from the leak check even in a `--directive noboolcase` dump, so the
check is weaker there. `DualABI` recomputes the set on its own input, which can
differ from `annotate`'s if a later pass adds or removes such a `case`; that is
harmless at run time (immediates) and idris2-lsp's IR is lint-clean.

Measured on idris2-lsp (same compiler, `--directive noboolcase` against the
default):

| | `noboolcase` | default |
|---|---|---|
| `drop` lines | 80,467 | 78,871 (-1,596) |
| `dup` lines | 79,112 | 79,113 |
| IR lines | 680,384 | 678,789 |
| `case` arms starting with a `drop` of a always-unboxed-constant scrutinee | 1,463 | 526 |

By origin the 1,453 (the `B8`-only count from the kind-tagged dump used for the
measurement; the 1,463 above also counts `Char` and the other always-unboxed alt
kinds) were: constructor fields 508, `case`-value `let`s 253,
`dup` aliases 231, call results 204, other 181, parameters 6, loop
parameters 1 (a parameter scrutinised by `B8` alts is already a native
`Bits8` through `paramEligibility`, which is why a whole-program producer
fixpoint over parameters would add under 1%). The remaining ~504 were
constructor fields, handled by the next section.

### Always-unboxed constructor fields (`--directive noboolfield`)

A constructor field that a typed-constant `case` scrutinises is an immediate
too, but two passes after `annotate` still gave it refcount operations
without looking at `natives`:

* `Reuse.resolveReuse` `dup`s every destructured field that the alt does not
  `drop` before the scrutinee is dropped, and lists every field in the
  `reuseOffer`'s `dupOnShared`/`dropOnUnique`.
* `ConAltNative.shadowOneField` re-derives a promoted field's ownership from
  scratch (`reannotateFieldOwnership`, a trailing `drop`).

Both now take the set `typedConstScrutinees` finds in the definition (`RC2.immOf`)
and leave those fields out: no pre-drop `dup`, no `dupOnShared`/`dropOnUnique`
entry, no re-derived `drop`. `--directive noboolfield` turns this off (it is also
off under `noboolcase`, whose evidence it uses). Only the refcount bookkeeping
changes. Why that is safe:

* The evidence is the same typed constant as above, never a bare `0`/`1`; the
  `case` and its default branch are not touched (a `Bits8` field may hold 2..255).
* `Emit.emitConAltBody` copies each field out of the cell into a C local at alt
  entry, before any `drop` of the parent runs, so the immediate stays valid after
  the parent is freed. An immediate needs no reference of its own.
* On a unique parent whose cell is reused, the field slot is overwritten and the
  old immediate needs no `drop`; on a shared parent the cell's own drop releases
  nothing for it.
* A field stored on into another constructor or passed Boxed to a call is still
  passed as the same tagged word; `natives`-listed locals are never counted.

`rcexpr-lint` needed a matching change, which is also the explanation for the
anomalies a first, broader attempt (stripping every refcount operation on these
locals after `ConAltNative`) reported: its use-after-free check treats a case
field as *borrowing* its scrutinee, so a field read after `drop [parent]` without
a `dup` is flagged, which is correct for a heap field and wrong for an immediate.
`Lint.idr` now seeds every `u:`-case local with an effectively unlimited count
(`seedImmediates`) and does not rebind it as a borrowed field, so such a read is
fine and a leftover `dup`/`drop` (the `noboolfield` form) cannot underflow.
`typedcase.rcexpr` has the field-after-parent-drop shape; the same file with the
`u:` marks removed is still flagged. One run of the narrow version also reported a
`con`-argument over-consume that was not a lint issue: a single `reuseOffer`'s
`dupOnShared` printed a wrong local id (`v271316` for `v261316`) in two
consecutive idris2-lsp compiles and in none of the six identical runs since
(unexplained; see TODO.md).

idris2-lsp, same compiler, `--directive noboolfield` against the default:

| | `noboolfield` | default |
|---|---|---|
| `dup` lines | 79,113 | 78,483 (-630) |
| `drop` lines | 78,871 | 71,191 (-7,680) |
| IR lines | 678,789 | 670,479 |
| arm-start drops of an always-unboxed-constant scrutinee | 526 | 120 |

(Of the 120 left, 13 are fields and 14 parameters; the rest are `let`-bound
Boxed call results and similar.) `Test13NativeArgChain`
covers fields of 2 and 255 through `1 -> ..; _ -> ..`, a field read after its
parent is dropped, and `tcBump`, which rebuilds a constructor (reuse) with such
a field on a shared and on a unique value; `check.sh` asserts fewer arm-start
drops and fewer `dupOnShared` entries than under the switch.

## Comparisons are a separate, narrower mechanism (`RCmpCase`)

Comparisons (`LT`/`GT`/`EQ`/`LTE`/`GTE`) are conspicuously **absent**
from `opResultRep` -- they never get a native `RLet.Rep` the way
arithmetic does. Instead, when a comparison is the sole, immediate
scrutinee of a two-way match on Idris2's own Bool encoding
(`False=0`/`True=1`), `RC.idr`'s `normalize` fuses the whole shape
directly into a dedicated `RCmpCase` IR node (`tryFuseCompare`,
`boolBranches`, `constantBoolValue`) -- the comparison becomes a raw C
boolean expression embedded straight into an `if`, with no boxed
value ever materialising at all, native or otherwise. This is a
distinct optimisation layered on top of (and reusing `nativeEligible`
from) this module, not an extension of the `RLet.Rep` mechanism -- see
`doc/`'s commit history / `BENCHMARKS.md`'s "比較/分岐融合" section for
the full design and its own bug (a double-free in `annotate`'s
`RCmpCase` case, unrelated to anything in this document).

### Comparisons over Boxed operands (`Integer`, `String`)

`Integer` and `String` are not `nativeEligible`, but `tryFuseCompareOp`
also fuses them (`Types.boxedCmpEligible`): the same `RCmpCase`, whose
operands are plain Boxed locals. The differences from the native case:

- **Condition.** `Emit.emitCmpCaseInto` reads the operands with
  `boxOpArg` (as an `ROp` does) and `Emit.Util.boxedCmpExpr` renders
  `idris2rc2_<op>_<ty>_raw(a, b)`, a `static inline int` helper in
  `idris2rc2_numeric.h` (`idris2rc2_integerCmp` for `Integer`, so the
  immediate fast path stays inline and the GMP path stays a call;
  `idris2rc2_strcmp3`/length-and-`memcmp` for `String`, so a NUL byte
  does not end a comparison). The `mkBool` forms `idris2rc2_<op>_<ty>`
  are now wrappers over the `_raw` ones.
- **Ownership.** Unchanged from the native case: `annotate`'s
  `RCmpCase` case gives each Boxed operand one `postDrop` entry (after a
  `dup` if the operand is still used), and `emitCmpCaseInto` drops them
  right after evaluating the condition, before either branch. No Bool
  local, hence no `dup`/`drop` and no `to_i64` of the result.
- **No shadowing.** The operand type is not native, so `Loop`'s
  `nativeArgTypes`/`nativeArgTypesFor` ignore such an `RCmpCase`:
  a loop parameter read only by `Integer` comparisons stays Boxed.

The shape condition is still the one above (the comparison itself is the
scrutinee of the two-way match); a `case` on a variable that was
`let`-bound to the comparison earlier is not fused.

### Merging nested comparisons (`Compiler.RC2.CmpMerge`)

`compare x y /= GT` is `x <= y`, but once the callee-first inliner
(`doc/inlining.md`) has expanded `compare`, the result is two nested
comparisons with the same branch twice:

```
cmp <T  [x, y] then A  else  cmp ==T [x, y] then A' else B     -- A' equals A
==>
cmp <=T [x, y] then A  else  B
```

`Compiler.RC2.CmpMerge` rewrites this, on the `RCExp` before the dup/drop
annotation (after the early-inline refold, so it sees the splices as
well; the `postDrop` fields are still `[]`). `--directive nocmpmerge`
turns it off.

- **Pairs.** `{<, ==}` becomes `<=` and `{>, ==}` becomes `>=`, with the
  strict comparison outside or inside, and the operands in either order
  (`a > b` is read as `b < a`; `==` is symmetric). Both comparisons must
  have the same operand type, one that fuses at all (`nativeEligible` or
  `Types.boxedCmpEligible`: Int and the other fixed widths, Char, Double,
  Integer, String). The merged node keeps the strict comparison's
  operands.
- **Equal branches.** The two `then` branches must be equal up to source
  locations and up to the names of locals bound inside them (`RLet`
  variables and constructor-alt fields are matched in order). A
  constructor the equality does not handle compares unequal, which only
  costs a merge. `Db` constants are compared by their printed form, so
  `0.0` and `-0.0` stay apart although `==` calls them equal.
- **A comparison with equal branches** (`compare x y /= LT` leaves
  `cmp ==T [x, y] then T else T`) is dropped for its branch.
- **NaN.** Every merge keeps all results for a Double NaN: `<`, `==` and
  `<=` are all false for it, so both forms take the else branch.
  Negation or branch swapping is deliberately not done, because it would
  not hold: `cmp < then A else B` is not `cmp >= then B else A` for NaN.

Where it fires. On `idris2-lsp` almost nowhere (see TODO.md): the
`Ord Int`/`Integer` `compare` stays a call (its rewritten body is over
`delegatingThreshold`), and elsewhere `<=` is the primitive already. It
needs the `compare` expansion to be inlined, which happens for a
single-caller `compare` (early inline) of String, Char and Double, or
for a hand-written `if x < y then A else if x == y then A else B`.
Measured: 200 million iterations of a hand-written merged shape on Int
and on Double take 9.86s instead of 10.48s (about 6%); a String insertion
sort through `compare x y /= GT` takes 0.134s instead of 0.139s, one
`strcmp` fewer per comparison.

## Bugs found and fixed (chronological, see `git log`/`BENCHMARKS.md` for commit-level detail)

1. **`Cast Integer Int` memory corruption.** `opResultRep (Cast i o)`
   originally checked only `o` (the destination type), not `i` (the
   source). Casting *from* GMP `Integer` (always boxed, arbitrary
   precision) to a native-eligible destination was incorrectly treated
   as native-eligible, reinterpreting a heap pointer as a raw
   `int64_t`. Fixed by requiring `nativeEligible i` too.
2. **Synthetic-let opacity.** `d * 2` binds the literal `2` in a
   synthetic `RLet` (Phase 1's ANF normalisation binds *every*
   non-trivial-looking operand uniformly) wrapping the real `ROp`; an
   earlier version of `repOf`/`emitNativeValue` didn't see through that
   wrapper and missed the native-eligibility of the whole expression.
   Fixed by having `repOf` (and the corresponding emission logic) peel
   through synthetic `RLet` chains to find the real `ROp`/`RPrimVal`.
3. **Boxed-operand leak in native-result ops.** `annotate`'s ownership
   analysis applies the same owned/borrowed bookkeeping to a
   native-result `ROp`'s operands as to any other value's, treating a
   last-use as "consumed." But `Emit.idr`'s `emitNativeValue` (unlike
   `emitRC`'s boxed-`ROp` case) had no matching cleanup at all -- every
   Boxed operand read only through a native unboxing extraction leaked
   one reference per call. Found via `Test112Numeric/NativeInts.idr`; this is
   what `ROp.postDrop` (above) now exists specifically to make
   impossible to get wrong again (a single Phase-2-computed field both
   `emitRC` and `emitNativeValue` lower identically, rather than two
   independently-hand-written cleanup sites).
4. **The postDrop-ordering regression** (found *while fixing* bug 3,
   before landing the real fix). The naive first attempt added the
   missing drop call at the same relative position as `emitRC`'s own
   boxed-`ROp` case -- but `emitNativeValue` returns an *inline
   expression string*, not a complete statement; the caller is what
   actually emits the statement embedding that expression. Dropping
   immediately upon return meant the drop executed (as a C statement)
   *before* the statement that actually reads the value via that
   expression -- a genuine use-after-free. Only visible for 64-bit
   types (`Int64`/`Bits64`, real heap allocations); 8/16/32-bit types
   use `alwaysUnboxed` tagged-pointer representations where dup/drop
   are no-ops, masking the bug entirely for those widths. Fixed by
   making the caller (whoever actually emits the statement that reads
   the expression) responsible for dropping `postDrop`'s locals, and
   only *after* emitting that statement -- never inside the
   expression-producing function itself. This is why
   `emitNativeValue`'s own doc comment is explicit about "not here, the
   caller" -- it's recording the exact shape of a bug already made
   once.
5. **`keepBoxedLocals`'s inverted filter** (predates the `postDrop`
   field's introduction, discovered alongside the RDup/RFree work).
   The filter's condition was backwards: "already registered in
   `RepMap` (i.e. let-bound)" excluded locals, when the intent was to
   exclude only genuinely `RNative`-Rep ones -- a let-bound *Boxed*
   local was incorrectly excluded from drop lists too, leaking it.
   Fixed by filtering on the `Rep` value itself (`RNative _` only),
   not on `RepMap` membership.
6. **`alwaysUnboxed`'s own elision, wired into `RC.idr`'s `annotate`
   pass since this document's original writing, missed two later,
   structurally separate wrapper-generation code paths entirely.**
   Not a defect in anything above -- `Types.alwaysUnboxed` itself and
   its consultation from `annotate` (`alwaysUnboxedBoxedLocalsR`, see
   "The `natives` set" above) were correct from the start. But two
   dual-ABI-related code paths added a couple of days later, each
   synthesising its own always-Boxed wrapper function, never consulted
   it: (1) `Compiler.RC2.DualABI`'s `synthesizeWorker` (Stage 3a, the
   always-Boxed wrapper a dual-ABI-eligible ordinary function gets
   rewritten into) -- its `wrapperPostDrop` unconditionally dropped
   every natively-promoted parameter regardless of `PrimType`; (2)
   `Compiler.RC2.Emit`'s `emitGenericForeignWrapper` (the always-Boxed
   C wrapper stub for an ordinary `%foreign` declaration) -- its
   `removeVarsArgList` dropped every FFI argument by variable name
   alone, with the argument's own `CFType` discarded before the drop
   decision was ever made. Neither was a correctness bug --
   `idris2rc2_drop` on an `alwaysUnboxed` value is a guaranteed
   runtime no-op by construction (see the `alwaysUnboxed` bullet
   above), so both merely emitted wasted C code, never wrong C code --
   but both defeated the entire point of `alwaysUnboxed` existing, on
   these two paths specifically. Fixed by filtering both against
   `Types.alwaysUnboxed` directly: `DualABI.idr`'s `wrapperPostDrop`
   now filters its own `eligible : List (Int, PrimType)` through
   `alwaysUnboxed`, keeping only the non-always-unboxed positions in
   the drop list; `Emit.idr` gained a shared `alwaysUnboxedDropVar :
   (String, String, CFType) -> Maybe String` helper (in the same
   `where`-block as `createFFIArgList`/`discardLastArgument`, used by
   both `emitGenericForeignWrapper`'s and `emitFastPackFixedWrapper`'s
   own `removeVarsArgList` -- the latter only for consistency, since
   `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`'s own arguments are always
   `CFUser` and never actually hit the `alwaysUnboxed` case in
   practice) that returns `Nothing` (skip the drop) when
   `cfTypeNative vt` is `Just ty` and `alwaysUnboxed ty` holds. A third
   related spot, `Emit.idr`'s own `emitFFIWorker` (Stage 3c's
   native-ABI FFI worker, not an always-Boxed wrapper), was checked
   and needs no fix: its Boxed positions are, by construction, exactly
   the ones where `cfTypeNative` already returned `Nothing` (not
   native-eligible at all), and `cfTypeNative` always returns `Just`
   for an `alwaysUnboxed` type, so such a type structurally can never
   appear in that worker's own Boxed-position drop list in the first
   place.

## Files

- `rc2/src/Compiler/RC2/Types.idr` -- all the pure decision functions
  described above.
- `rc2/src/Compiler/RC2/RC.idr` -- Phase 1 (`bindOne`/`bindCompound`
  calling `repOf`), Phase 2 (`nativeLocalsR`, `alwaysUnboxedBoxedLocalsR`,
  `definitionNatives`, `splitBorrows`, `boxedOperands`, `tryFuseCompare`
  for the comparison-fusion side channel).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `Rep`, `RLet.rep`, `ROp.postDrop`,
  `RCLocal.RCConst`, `RCmpCase`.
- `rc2/src/Compiler/RC2/Emit.idr` -- `nativeCType`/`nativeMk`/
  `nativeUnbox`, `rcVarToNativeC`/`rcVarToBoxedC`, `cOp`/`nativeOpExpr`/
  `nativeCmpExpr`, `emitNativeValue`, `InlineMap`/`tryInlineNativeOp`,
  `RepMap`; also `alwaysUnboxedDropVar` (bug 6 above), consulted by
  `emitGenericForeignWrapper`/`emitFastPackFixedWrapper`'s own
  `removeVarsArgList`.
- `rc2/src/Compiler/RC2/DualABI.idr` -- not otherwise part of this
  document's own Phase 1/2 machinery, but `synthesizeWorker`'s
  `wrapperPostDrop` is a second, separate consumer of
  `Types.alwaysUnboxed` (bug 6 above), filtering its own dual-ABI
  wrapper's drop list the same way `annotate`'s
  `alwaysUnboxedBoxedLocalsR` does for ordinary functions.

## Verification methodology

1. Build + regression baseline: see `CLAUDE.md`'s "Build & test" section
   (`idris2 --build rc2.ipkg`, then `tests/refc-suite/run.sh`, expect 19/19).
2. `tests/Test112Numeric/NativeInts.idr` specifically exercises all 8 fixed-width
   integer types (signed/unsigned, all widths) through the same
   arithmetic chain, byte-diffed against real `idris2 --cg refc` output
   including boundary-value wraparound -- this is the test that found
   bug 3/4 above, re-run it first when touching anything in this area.
3. `tests/BenchChain.idr`'s `poly` function is the canonical
   demonstration that the whole mechanism works end-to-end: compare its
   generated C's heap-allocation/dup/drop counts against RefC's (see
   `BENCHMARKS.md`'s "算術チェイン" section for the exact expected
   numbers -- 3 allocations / 3 dup / 4 drop for rc2 vs. RefC's 8/6/16,
   a regression here should show up as those numbers drifting back
   toward RefC's).
4. Grep generated `.c` for the specific PrimType's native C type
   (e.g. `int8_t`) appearing as a bare stack-declared variable, not
   wrapped in `IDRIS2RC2_Value*`/`idris2rc2_mk*`, to confirm the
   unboxing actually fired for a given test case.
5. Bug 6 above (the two dual-ABI wrapper paths that missed
   `alwaysUnboxed`) has its own separate regression coverage, since
   neither path is reachable through `RC.idr`'s own `annotate` pass
   that `Test112Numeric/NativeInts.idr` above was written to exercise: hand-check
   `tests/build/Test112Numeric_rc2.c`'s `Main_chainInt8`/`chainInt16`/
   `chainInt32` (and the Bits8/16/32 equivalents) to confirm their
   dual-ABI wrappers no longer call `idris2rc2_drop` on their arguments
   at all, while `Main_chainInt64` (native-eligible but *not*
   `alwaysUnboxed` -- a real heap allocation outside the small-int
   cache) still correctly drops both of its arguments, unchanged;
   likewise `tests/build/Test27FFIDualABI_rc2.c`'s `Main_prim__bumpChar`
   (the `CFChar`/`Char` `%foreign` wrapper) no longer drops its
   argument, while `Main_prim__mixed` (`Int`+`String`, neither
   `alwaysUnboxed`) and `Main_prim__noop` still correctly drop theirs.
   Full `verify.sh --regen-expected` (85/85) and `refc-suite/run.sh`
   (19/19) both pass, consistent with this being a pure codegen-waste
   fix with no behavior change.
