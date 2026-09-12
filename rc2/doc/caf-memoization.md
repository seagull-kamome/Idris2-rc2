# CAF memoization: a new `RMemoize` IR node

**Status: implemented and verified.** `Test86CafMemoization.idr`
reproduces the exact `TODO.md` example below and confirms `0 1 2` (not
`0 0 0`); full `verify.sh` (`refc-suite` + smoke tests + valgrind) is
clean. Boxed CAFs only -- see "Emit-side C codegen" below for why the
native case was found unreachable rather than implemented.

## The bug this fixes

`TODO.md`'s own "Semantics: a plain `unsafePerformIO` CAF isn't
memoized either" entry: a top-level 0-argument definition

```idris2
counter : IORef Int
counter = unsafePerformIO (newIORef 0)
```

compiles to an ordinary C function re-run on every reference -- three
independent `IORef`s instead of one shared one, confirmed identically
on `--cg rc2` and upstream `--cg refc` (Chez shares it correctly). Same
root cause as the earlier "Semantics: `Lazy`/`Force`..." entry
(`idris2-src`'s `getCompileData doLazyAnnots = False`, plus rc2/RefC's
complete lack of CAF-sharing for top-level 0-argument definitions) --
see both TODO.md entries for the full history.

**Scope of this design**: fixes the plain-CAF case above (a bare
0-argument definition with a real, possibly-effectful body) --
`RMemoize` wraps a CAF's own body and guarantees it's evaluated at
most once. It does **not**, on its own, fully fix `Lazy`/`Force`: a
`Lazy a` CAF's own compiled form builds and returns a *closure*
(`Delay e` compiles to `CLam`, per the `Lazy`/`Force` TODO entry's own
point 3), so wrapping the CAF's own top-level slot in `RMemoize` only
guarantees every *reference* to the CAF gets the same closure object
-- a real improvement, but `Force t` unconditionally compiles to
`CApp fc tm [CErased fc]` (call whatever `tm` evaluates to), so a
*second* `force` on that now-shared closure still re-invokes its body.
Making that not happen needs the separate "memoizing closure
representation" the `Lazy`/`Force` entry's points 3/5 already describe
(a forced-flag + cached-value slot on the closure itself, touching
`datatypes.h`) -- out of scope here, revisit from that entry if it's
ever pursued.

## The IR node

```idris2
RMemoize : FC -> Name -> Rep -> RCExp -> RCExp
```

Wraps a CAF's own body. Only ever produced as the *entire* body of a
0-argument `MkRCFun` -- never nested inside a larger expression, never
produced for any other definition shape. `rep` is exactly that
`MkRCFun`'s own `retRep`, copied, not re-derived.

**Identity is the CAF's own `Name`, not a fresh counter.** `Name` is
already globally unique and already consistently mangled by `cName`
everywhere else in this codebase -- reusing it needs no new
ID-allocation scheme, and directly gives Emit the static variable's
own name for free. It also means that if some future pass ever did
duplicate an `RMemoize` node (see "Interaction with `Inline`" below for
why none currently do), every copy would still resolve to the *same*
backing static variable as long as the `Name` travels with it --
memoization survives duplication for free, rather than needing every
pass that might copy an expression to specifically know not to.

### Interaction with `Compiler.RC2.Inline`

`Inline`'s own Criterion A (`buildEligible`) requires a callee's body
to be `isCallFree` (no function invocation of any kind) before it's
ever spliced into a caller. A CAF that could possibly need
`RMemoize`'s guard -- one with a real effect, or an expensive
computation worth sharing -- necessarily contains at least one call
(to `unsafePerformIO`, to whatever primitive underlies it, or to
whatever makes it expensive to begin with), so it can never satisfy
`isCallFree` in the first place. **No change to `Inline` is needed**:
the set of CAFs `Inline` would ever duplicate and the set of CAFs
`RMemoize` needs to guard are disjoint by construction, today. Worth
re-checking this document's own reasoning if `Inline`'s eligibility
criteria ever change.

## Where it's inserted: right after `ConstFold`, right before Phase 2

`Compiler.RC2.RC2.toRCDefs`'s own pipeline (its current shape):

```
Inline (Lifted level)
  -> toRCDefPreFold (Lifted -> RCExp, "Phase 1", per definition)
  -> foldConstProgram (ConstFold, whole-program CafTable fixpoint)
  -> [insertMemoize goes here]
  -> toRCDefPostFold (Phase 2 ownership annotation) + Reuse + ConAltNative
  -> MutualLoop -> Loop -> Sink -> DualABI -> DeadCode -> DupMerge -> Emit
```

A new pass, `insertMemoize : List (Name, RCDef) -> List (Name, RCDef)`,
runs on `folded` (ConstFold's own output) and feeds its result into the
existing `reused <- ...` `traverse` in place of `folded`.

**Why here, not earlier or later:**

- **Not before `ConstFold`.** `Compiler.RC2.ConstFold`'s own whole-
  program `CafTable` fixpoint (`doc/const-caf-fold.md`) already
  resolves a genuinely-constant CAF to a literal, across definition
  boundaries. Wrapping every 0-arg definition in `RMemoize` *before*
  this runs would force `ConstFold` to see through the wrapper (or
  skip folding anything memoized), for no benefit -- a CAF ConstFold
  can already prove constant needs no runtime guard at all.
- **After `ConstFold`, so it only wraps what's left.** By this point,
  whatever 0-arg `MkRCFun` remains with a body that *isn't* already a
  bare literal (`RPrimVal`) or an already-immortal-static constant
  constructor (`RCConstCon`, `doc/const-con-fold.md`) is either a real
  effect or a genuinely non-constant computation -- exactly what needs
  guarding, with no separate "does this look like `unsafePerformIO`"
  heuristic needed (see "Why not detect `unsafePerformIO` specifically"
  below).
- **Before Phase 2 (`toRCDefPostFold`/`annotateDef`), not after.**
  `annotateDef`'s own `branchBody` call already treats a definition's
  whole body as one top-level ownership context. Inserted here,
  `RMemoize` just needs one pass-through case in `RC.idr`'s `annotate`:
  ```idris2
  annotate natives owned (RMemoize fc n rep body) =
      RMemoize fc n rep <$> annotate natives owned body
  ```
  Since `RMemoize` only ever wraps the *entire* CAF body, "how `body`'s
  own final value should be owned" is identical to "how a plain
  function's own return value is owned" -- already exactly what
  `branchBody`/`annotate` compute for the un-wrapped case. No new sink-
  specific ownership bookkeeping needed; the value `RMemoize` hands to
  its own runtime call is, by construction, the same uniquely-owned
  result the function would otherwise have returned directly.

### Insertion criterion

`Compiler.RC2.RC2.insertMemoize` wraps every `(name, MkRCFun [] retRep
isWorker body)` surviving `ConstFold` in `RMemoize fc name retRep body`
unless `cafValueOf (MkRCFun [] retRep isWorker body)` returns `Just _`
-- reusing `ConstFold`'s own predicate unchanged, rather than
re-deriving a separate "is this shape already trivial" check:
`cafValueOf`'s own definition (`MkRCFun [] _ _ (RV _ cval)` with `cval`
proven constant) is exactly "body is already a bare reference to a
compile-time constant", the same question this insertion criterion
needs answered.

### Why not detect `unsafePerformIO` specifically

At the `Lifted`/`RCExp` level there is no distinguishable marker for
"this came from `unsafePerformIO`" at all -- it desugars to an
ordinary call chain ending in a discarded `%World` token,
indistinguishable from any other computation. A pattern-based detector
risks exactly the false-negative that reproduces this same bug
somewhere a syntactic match doesn't fire. Memoizing *every* surviving
non-constant 0-arg definition unconditionally is both simpler and
strictly safer: for a genuinely pure-but-expensive CAF, this costs one
cheap atomic check per reference and changes no observable behavior
(referential transparency means sharing vs. redundant recomputation is
a performance question only); for a real effect, it's exactly the fix
needed. `Compiler.RC2.RC2.collectLazyCAFs`/`isLazyCAF` already exists
(currently only for `dumprcexpr`'s own benefit) and is exactly this
kind of free, already-tested detection, reusable if the `Lazy`-specific
sub-case (see "Scope" above) ever needs its own special-casing on top
of this.

## Threading through the rest of the pipeline

`RCExp.idr`'s own generic structural-recursion helpers each need one
pass-through case for `RMemoize` (this file's own stated design goal:
"a new `RCExp` constructor forces a single update rather than three"):

- `freeLocalsR (RMemoize _ _ _ body) = freeLocalsR body`
- `countUsesR l (RMemoize _ _ _ body) = countUsesR l body`
- `usedConstructorsR (RMemoize _ _ _ body) = usedConstructorsR body`
- `foldRCNamesR`'s own `go` -- pass through into `body` the same way.

`Reuse`/`ConAltNative`/`MutualLoop`/`Sink`/`DualABI`/`DeadCode`/
`DupMerge` needed no changes at all, confirmed empirically (Idris2's
own coverage checker flags every non-total pattern match as a build
error, so building after adding the constructor is a complete,
mechanical audit, not a manual one) -- none of them pattern-match
`RCExp` exhaustively in a way `RMemoize` reaches. Two files did need a
one-line pass-through: `Compiler.RC2.Loop`'s own `renameRCExp` (its
self-tail-call renaming walk *is* exhaustive over `RCExp`, even though
`RMemoize` can never actually reach it in practice -- a 0-arg CAF has
no loop-carried parameters for `applyLoop` to ever run on) and
`Pretty.idr`'s `prettyExp` (`dumprcexpr`'s own renderer).

## Emit-side C codegen

New runtime file pair, `rc2/support/rc2/caf_memoize.h`/`.c` (included
from the generated-code umbrella header `idris2rc2_runtime.h`), fixing
two runtime-level bugs an earlier hand-written sketch this design
started from had:

1. **The "already computed" flag and the "next node in the global
   cleanup list" link are two separate fields**, not one shared `next`
   pointer serving both purposes. Sharing them would make the first-
   ever-memoized CAF's own flag field equal to `NULL` once it's linked
   onto an empty `head` list -- indistinguishable from "never
   computed", silently defeating the guarantee for exactly that one
   CAF.
2. **The "wait for another thread's first computation" spin reuses the
   same `atomic_flag`/`_Atomic bool` primitives `rc2/support/rc2/util.h`'s
   own `idris2rc2_spin_lock` already established as this codebase's
   spin idiom**, rather than a hand-rolled CAS loop. The global
   cleanup-list head (`idris2rc2_memo_boxed_cleanupHead`,
   `caf_memoize.c`) is genuinely `_Atomic`, pushed onto with a real
   Treiber-stack CAS retry loop.

Actual API (`caf_memoize.h`):

```c
typedef struct idris2rc2_memo_boxed {
  atomic_flag claimed;
  _Atomic bool done;
  IDRIS2RC2_Value *value;
  struct idris2rc2_memo_boxed *cleanup_next; // written once, before publish -- see caf_memoize.c
} idris2rc2_memo_boxed;

bool idris2rc2_memo_boxed_claim(idris2rc2_memo_boxed *memo);      // true: you must compute + store
void idris2rc2_memo_boxed_store(idris2rc2_memo_boxed *memo, IDRIS2RC2_Value *value);
IDRIS2RC2_Value *idris2rc2_memo_boxed_wait(idris2rc2_memo_boxed *memo); // spins, then dups
void idris2rc2_memo_boxed_dropAll(void);                          // idris2rc2_rtFinish only
```

`Emit.idr`'s `emitMemoizeInto` lowers `RMemoize` into:

```c
static idris2rc2_memo_boxed idris2rc2_memo_<cName n> = IDRIS2RC2_MEMO_BOXED_INIT;
IDRIS2RC2_Value *result;
if (idris2rc2_memo_boxed_claim(&idris2rc2_memo_<cName n>)) {
    <body's own statements, forced into a fresh SinkVar bodyVar>
    idris2rc2_memo_boxed_store(&idris2rc2_memo_<cName n>, bodyVar);
    result = bodyVar;
} else {
    result = idris2rc2_memo_boxed_wait(&idris2rc2_memo_<cName n>);
}
<result finalized into whatever this RMemoize's own real sink/tailPosition wants>
```

`body` is always emitted into a forced `SinkVar` (never straight into
`RMemoize`'s own `sink`), since its value has to be read back here
(for the `idris2rc2_memo_boxed_store` call) before going anywhere at
all -- a `SinkReturn` sink would make that impossible.

**Native (unboxed) `RMemoize` is not implemented, confirmed
unreachable rather than half-built.** `rep` is always a direct copy of
the enclosing `MkRCFun`'s own `retRep`, and `Compiler.RC2.RC`'s
`normalizeDef` (Phase 1) hardcodes `retRep = RBoxed` for every ordinary
definition -- confirmed directly, not assumed. The only place a native
`retRep` is ever introduced is `Compiler.RC2.DualABI`'s worker
synthesis, which builds a *separate* definition alongside the original
wrapper, strictly after `insertMemoize` already ran
(`ConstFold -> insertMemoize -> Phase 2 -> ... -> DualABI`). A second,
independent reason not to attempt it anyway: `Sink`'s own `SinkVar`
(`Emit/Util.idr`) always declares `IDRIS2RC2_Value *` -- there's no
existing "force a native value into an intermediate variable" sink
shape at all, so a real native `RMemoize` would need that built first.
`emitMemoizeInto`'s `RNative`/`RInlineNative` cases throw an
`InternalError` rather than emit something unverifiable.

Static variable name: derived from `RMemoize`'s own `Name` field via
the existing `cName` mangling -- no separate counter/allocation scheme.

## Runtime lifecycle

`idris2rc2_rtFinish` (`runtime.c`, `doc/runtime-lifecycle.md`) calls
`idris2rc2_memo_boxed_dropAll` -- a new call there, not a new lifecycle
hook.

## Incremental compilation

`static` C variables have internal linkage, so no cross-module symbol
collision risk even with two modules independently naming a memo
variable identically (moot anyway once naming is `Name`-derived, since
two different top-level definitions never share a mangled name).
`ConstFold`'s own `foldConstProgram` already runs regardless of
`toRCDefs`'s `incremental` flag (only `preFolded`'s own construction
branches on it) -- `insertMemoize`, placed at the exact same pipeline
point, needs no incremental-specific handling either: it operates
correctly given only one module's own partial `toIR` scope, the same
constraint `ConstFold` itself already accepts.

## Known remaining edge case (low priority)

A CAF whose own computation reaches back into itself before finishing
(direct or mutual recursion through other CAFs) would deadlock (the
spin-wait never sees "done") under this design. Not a new failure mode
this introduces -- a genuinely circular, non-lazy top-level value
reference was already undefined/diverging before this design existed
-- not pursued further here.

## Verification

`rc2/tests/Test86CafMemoization/` reproduces `TODO.md`'s own former
example exactly (an `IORef` built through `unsafePerformIO (newIORef
0)`, read/incremented three times): `0 1 2`, matching `--cg chez`,
where it previously printed `0 0 0` (confirmed on both `--cg rc2` and
upstream `--cg refc`). Listed in `verify.sh`'s `NO_REFC_DIFF_TESTS`
(real RefC still has the original bug -- no shared baseline to diff
against) and `LEAK_SENSITIVE_TESTS` (the memo's own permanent
reference is exactly the kind of thing worth a `valgrind` pass: 0 bytes
definitely lost). Full `verify.sh` (`refc-suite` 21/21, every smoke
test, every `valgrind` pass) is clean with this change in place --
including `refc-suite/callingConvention`'s own golden-snapshot
`expected` file, regenerated once to absorb a benign `tmp_N`/`var_N`
renumbering shift (`insertMemoize` now runs before every other CAF in
a program gets its own temp-variable counter values, the same kind of
harmless shift any earlier whole-program pass insertion already
causes elsewhere in this suite's own history) -- confirmed by reading
the diff itself before regenerating: identical logic, renumbered names
only.
