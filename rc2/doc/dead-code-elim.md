# `Compiler.RC2.DeadCode`: whole-program dead-code elimination

## Motivation

`Compiler.Common.getCompileData` computes rc2's starting `List (Name,
LiftedDef)` once, via upstream Idris2's own reachability analysis over
the *original* call graph (`mainExpr`'s own closure, plus any
`%export`ed names). `Compiler.RC2.RC2`'s `toRCDefs` then runs every one
of rc2's own passes (`Inline`, `RC.annotate`+`Reuse`+`ConAltNative`,
`MutualLoop`, `Loop`, `Sink`, `DualABI`) as a `traverse` over that same
list -- none of them ever add or remove an entry, only rewrite bodies
in place.

But some of those rewrites make a definition genuinely unreachable
*within rc2's own final program*, in ways upstream's analysis (fixed
before any of this ran) has no way to know about:

- **`Compiler.RC2.Inline`** splices an eligible callee's body into
  *every* one of its own call sites (`rc2/doc/inlining.md`'s own
  "every call site" eligibility rule). The original definition is left
  behind with zero remaining callers -- and since nothing downstream of
  Inline is aware this happened, `Compiler.RC2.DualABI`'s own Stage 3a
  will still cheerfully split that now-dead definition into its own
  (equally dead) wrapper+worker pair, same as any live function.
- **`Compiler.RC2.DualABI`'s Stage 3a wrapper.** A function eligible
  for native-representation dispatch gets an always-Boxed wrapper (kept
  for callers that can only supply/consume `IDRIS2RC2_Value*`) plus a
  native-calling-convention worker. Stage 4 rewrites that function's
  own call sites to call the worker directly -- necessarily only
  non-tail-position ones (`rc2/doc/dual-abi.md`'s own permanent scope
  boundary). If a function had no tail-position callers to begin with,
  every one of its callers gets redirected to the worker, and the
  wrapper itself ends up with zero remaining callers.

Both are confirmed real via `rc2/tests/Test51DeadCode*`/
`Test52DeadCode*` -- see their own header comments and "Verification"
below.

## Pipeline position

```
Compiler.RC2.Inline
  -> Compiler.RC2.RC.normalize/annotate + Reuse + ConAltNative
  -> Compiler.RC2.MutualLoop
  -> Compiler.RC2.Loop
  -> Compiler.RC2.Sink
  -> Compiler.RC2.DualABI          (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.DeadCode         (this module -- final stage)
  -> Compiler.RC2.Emit             (purely mechanical RCExp -> C)
```

Run as `toRCDefs`'s own last step, on the exact `List (Name, RCDef)`
`Emit.generateCSourceFile` is about to consume -- so `--directive
dumprcexpr`'s own claim ("precisely what generateCSourceFile is about
to consume") stays true with this pass in the pipeline, not just
despite it. `--directive nodeadcode` skips it, same A/B-isolation
convention as every other optional stage (`RC2.idr`'s own `toRCDefs`
doc comment).

## Design

### Roots

`compileExpr` supplies `MN "__mainExpression" 0` (the well-known name
`footer`'s `main()` calls directly as `__mainExpression_0()` --
`Compiler.Common`'s own doc comment on `mainExpr`) plus `map fst
(exported cdata)` (`%export`ed names -- `CompileData.exported`,
already included in upstream's own reachability roots too). rc2
doesn't otherwise implement `%export`, so this second half is
currently always `[]` in practice; included anyway since it costs
nothing and avoids a latent trap if that ever changes -- deleting a
function meant to be called from outside the compiled program because
nothing *inside* it calls that function either.

### The walker: `usedFunctionNamesR`

A `Name` reachability needs to follow is any name an `RCExp` might call
directly (`RAppName`, `RAppNameRep`) or reference as a first-class
value to build a closure over (`RUnderApp`). This is deliberately a
*new*, from-scratch, exhaustive walker over every `RCExp` constructor
-- not `Compiler.RC2.RCExp`'s existing `freeLocalsR`/`countUsesR`/
`usedConstructorsR`, all three of which have their own `_ = empty`
catch-all and were written for earlier-pipeline purposes (free-variable/
use-count analysis in `Compiler.RC2.RC`, a local heuristic in
`Compiler.RC2.Reuse`) that never needed to know about `RLoop`'s body or
`RAppNameRep`/`RAppFFIInline`, both of which only exist this late
(`Compiler.RC2.Loop`/`DualABI`). Reusing any of them here would have
silently missed every reference living inside a loop body or a
DualABI-rewritten call site -- exactly the two places this pass most
needs to look.

Two `Name`-carrying constructors are deliberately excluded:

- `RCon`'s own `Name` is a *constructor* name, a different namespace
  from `defs`'s own function-name keys.
- `RExtPrim`'s `Name` is one of a fixed whitelist of compiler-known
  primitive selectors (`prim__newIORef`, etc. -- see
  `Compiler.RC2.Emit`'s own `emitRC` `RExtPrim` case), matched by
  string against that whitelist, never looked up in `defs`.

`RAppFFIInline` carries no `Name` at all -- its target is a literal C
symbol spliced directly from its own `ccs` field, independent of
whether any `defs` entry still exists for it (see "Bugs found" below
for why that independence is exactly the trap this pass has to avoid).

### The sweep: `pruneDeadDefs`

A standard worklist mark phase (`markReachable`): `seen` starts as
`roots` and grows by following `usedFunctionNamesD` (the same walker,
lifted to a whole `RCDef`) transitively. A single pass over the
worklist finds the *whole* transitive closure -- no fixpoint loop
needed, unlike a "repeatedly remove defs with zero direct callers,
until nothing changes" formulation. Reachability-from-roots already
correctly excludes an entire dead chain in one traversal: if `A` is
unreachable and `B` is called only by `A`, `B` is simply never
enqueued, regardless of how many links long the chain is.

`pruneDeadDefs` then drops every `MkRCFun` entry not in the reachable
set. `MkRCForeign`/`MkRCCon`/`MkRCError` are always kept -- see "Scope"
below for `MkRCForeign`, and `DeadCode.idr`'s own header note for
`MkRCCon`/`MkRCError`.

## Scope: `MkRCForeign` deliberately excluded

The exact same "zero remaining callers" situation this pass fixes for
`MkRCFun` looks, at first glance, like it should also arise for a
`%foreign` declaration's own always-Boxed wrapper stub
(`MkRCForeign`): `Compiler.RC2.DualABI`'s `ffiWorkerTable` +
`inlineFFIWorkers` (Stage 3c/5) rewrite *every* eligible non-tail call
site straight to an `RAppFFIInline` splice, no synthesized worker
`Name` ever created at all -- surely a declaration with no tail-
position callers left ends up just as dead as an ordinary function's
wrapper would?

Pruning it is awkward to implement (see "Bugs found" #1 below), and --
via `Compiler.RC2.Inline`/`Compiler.RC2.DualABI` specifically -- a
truly-dead `MkRCForeign` entry can't actually arise at all:

- `Compiler.RC2.Inline`'s own eligibility requires a callee's body to
  be call-free (`isCallFree`, `rc2/doc/inlining.md`). A function that
  itself calls an FFI declaration is therefore *never* Inline-eligible
  -- there is no way for "the only function calling this FFI
  declaration got fully inlined away" to happen, because that
  situation requires the caller to have had zero calls in its own body
  to begin with.
- `Compiler.RC2.DualABI`'s Stage 3a wrapper/worker split moves a
  function's *entire* original body -- FFI calls and all -- into the
  synthesized worker; the wrapper's own body is just a thin `RAppNameRep`
  into that worker. So even when a wrapper itself goes dead (exactly
  `rc2/tests/Test52DeadCode*`'s own scenario), any FFI call the
  original function made is still sitting in the worker, which stays
  reachable for as long as anything genuinely calls the function --
  wrapper or worker, whichever the call site was rewritten to target.

Confirmed directly: a version of this pass that also tracked which
`ccs` (a declaration's own raw `%foreign` calling-convention strings)
still appeared among surviving `RAppFFIInline` splices, keeping any
`MkRCForeign` entry whose `ccs` was still needed even without a name
reference, never actually removed anything in practice -- every test
constructed to trigger it went through `Inline`/`DualABI` and kept the
entry alive through exactly the two mechanisms above. Removed rather
than shipped as untested, unreachable-in-practice complexity.

**This is not the whole story, though** -- `Compiler.RC2.ConstFold`'s
own `RConstCase` case-of-constant folding (`foldConst`'s
`findConstAlt`) is a *third* mechanism, entirely outside `Inline`/
`DualABI`, that discards whole subtrees: once a case's scrutinee
resolves to a known constant, the entire node is replaced by just the
matching alt's body, and every other alt -- along with any `%foreign`
call inside it -- is discarded outright. A codegen-identity branch
(`prim__codegen`/`prim__os` folded to a literal string,
`Compiler.RC2.ConstExtPrim`) or a folded comparison feeding a boolean
`RConstCase` compiles down to exactly this shape. A declaration whose
*only* call site sits inside a branch eliminated this way genuinely
does lose every caller, `MkRCForeign` included -- the removed `ccs`-
tracking mechanism described above would have correctly caught this
one case, just never through the two mechanisms the tests above
happened to exercise. Deliberately not pursued further -- rare enough
(a single-call-site `%foreign` declaration inside a statically-
eliminated branch) that reviving the removed tracking wasn't judged
worth it yet. See `TODO.md`'s own entry on this for what reviving it
would take.

## Bugs found and fixed

1. **Pruning a still-referenced `MkRCForeign` drops its own header/library
   registration.** First attempt let `pruneDeadDefs` remove `MkRCForeign`
   entries too, using the exact same reachability test as `MkRCFun`. A
   test exercising it (a `%foreign` declaration called once, from a
   non-tail position, its only call site inlined via Stage 5) compiled
   to C that failed with an implicit-declaration error for the
   now-unresolvable symbol: `Compiler.RC2.Emit.collectDeclarations`
   (Pass 1) is what registers a `%foreign` declaration's own `#include`/
   library needs, and it does so by iterating `MkRCForeign` entries
   specifically -- `RAppFFIInline`'s own call sites carry the raw
   `ccs`/`fargs`/`ret` needed to splice the call itself, but nothing
   about the header it needs. Removing the `MkRCForeign` entry silently
   dropped that registration while the call site calling its raw C
   symbol was still very much present. This is what motivated tracking
   `ccs` directly (see "Scope" above) -- which then surfaced the deeper,
   structural reason removal never actually helps here regardless.

2. **`%default total` rejected every function in this module.** This
   module's mark-and-sweep worklist (`markReachable`) isn't structurally
   decreasing on its own list argument (it can grow mid-traversal as new
   names are discovered), and the exhaustive `RCExp` walker
   (`usedFunctionNamesR`) recurses into pattern-alternative lists via
   `map`, which Idris2's termination checker doesn't see through as
   structural recursion either. Every other `Compiler.RC2.*` module that
   walks `RCExp`/builds a worklist graph (`RCExp.idr`, `MutualLoop.idr`,
   `Reuse.idr`) already declares `%default covering`, not `total`, for
   exactly this reason -- switched to match rather than reach for
   `assert_total`.

## Verification

`rc2/tests/Test51DeadCodeInline.idr` (an Inline-orphaned definition,
which itself further fans out into its own dead DualABI wrapper+worker
pair, and also absorbs the former, separate `Test52DeadCodeDualABIWrapper.idr`'s
coverage of a DualABI wrapper with no tail-position callers) confirms, by hand:

- functional output unchanged with `--directive nodeadcode` either way
  (this pass changes generated-C *size*, never program behaviour);
- `--directive dumprcexpr`'s own dump shows the target definition(s)
  completely absent with the pass enabled, present (and genuinely
  uncalled -- confirmed by reading the dump's own call sites) with
  `--directive nodeadcode`;
- the generated `.c` itself has no C function at all for the pruned
  name(s) with the pass enabled (`grep` against the mangled name),
  matching `rc2/doc/dual-abi.md`'s own "not merely dead code" standard
  of proof for its Stage 5 removal claim.

Both tests are part of the ordinary `rc2/tests/verify.sh` smoke suite
(auto-discovered, no special registration needed) and ran clean under
the full `--directive nodeadcode` A/B comparison across the whole
suite, confirming this pass never changes any other test's own
behaviour either.
